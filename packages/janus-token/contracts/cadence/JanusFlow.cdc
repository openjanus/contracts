// JanusFlow.cdc — Router for confidential native-FLOW wrapping (v0.3 EVM target)
//
// Architecture: Router/façade + swappable pure-logic implementation.
//
//   JanusFlow     = router that fronts EVM custody by funding the user's COA
//                   with FLOW pre-wrap and then forwarding ABI calldata to the
//                   EVM JanusFlow proxy via that COA.
//
//   JanusFlowImpl = pure-logic impl (stateless). Validates structural
//                   constraints on proof shapes + commitments before the
//                   EVM call. Swappable via 48h time-lock.
//
// Cross-VM design (per-user COA pattern):
//   - All real custody lives on EVM (JanusFlow.sol's `totalLocked` + per-account
//     Pedersen commitments). The Cadence layer is a translator that:
//       1) Withdraws FLOW from the signer's FlowToken vault.
//       2) Deposits it into the signer's COA.
//       3) Issues an EVM call from the COA to the JanusFlow proxy with the
//          appropriate ABI-encoded calldata (built off-chain by the client).
//   - Proof verification happens on EVM. EVM rejects invalid proofs → the
//     Cadence transaction panics → no state is updated anywhere.
//
// Storage compatibility:
//   The v0.2.1 router exposed `commitments` and `pubkeys` maps that mirrored
//   on-chain accounting from the OLD EVM JanusToken design (ElGamal accumulator).
//   The v0.3 EVM JanusFlow stores its own per-address Pedersen commitments
//   directly, so the Cadence side no longer needs to mirror commitments.
//   The fields are kept in storage (now empty + unused) to avoid a forced
//   migration on testnet — Cadence allows removing fields, but we keep them
//   so old read scripts don't fail (`hasCommitment`, `getCommitment` etc.).
//
// v0.5.2 additions (additive — no new contract-level fields):
//   MemoKey Resource type + MemoKeyPublic interface — generic BabyJub pubkey
//   store. Apps that use JanusFlow privacy (PrivateTip, SealedBidNFT, etc.)
//   import this type instead of each app defining its own. The resource lives
//   at /storage/openjanusMemoKey and pubkey at /public/openjanusMemoKey.
//   createMemoKey(pubkeyX, pubkeyY) factory — pubkey only, NO privkey.
//   MemoKeyPublished event + getMemoPubkey(owner) view.
//
// Admin model: capability-based AdminResource in deployer storage.
//
// Deployed at: 5dcbeb41055ec57e (openjanus-janusflow-router account)
// EVM target:  JanusFlow proxy at 0x09A3DCa868EcC39360fDe4E22046eCfcbA5b4078

import "EVM"
import "FlowToken"
import "FungibleToken"
import IJanusFlowImpl from 0x5dcbeb41055ec57e
import JanusFlowImpl from 0x5dcbeb41055ec57e

access(all) contract JanusFlow {

    // ─── Storage Paths ──────────────────────────────────────────────────────────

    access(all) let AdminStoragePath: StoragePath

    // ─── State — Custody mirror (router-side aggregate) ─────────────────────────

    /// Total FLOW that has been wrapped through this router (Cadence-side
    /// mirror — the authoritative `totalLocked` lives on the EVM contract).
    access(self) var totalLocked: UFix64

    /// LEGACY (v0.2.1) — per-user encrypted commitment slots from the old
    /// ElGamal-accumulator EVM design. NO LONGER WRITTEN in v0.3. Kept for
    /// storage upgrade compatibility (Cadence cannot add non-optional fields
    /// at upgrade time, and removing this empty dict is safe but unnecessary).
    access(self) var commitments: {Address: [UInt8]}

    /// LEGACY (v0.2.1) — per-user BabyJubJub public keys. Same status as
    /// `commitments`: kept empty, never written in v0.3.
    access(self) var pubkeys: {Address: [UInt8]}

    // ─── State — Router ──────────────────────────────────────────────────────────

    /// Legacy EVM target set at deploy time (v0.2.1 JanusToken). The active
    /// target is hardcoded via `_evmTargetHex()` below instead — Cadence's
    /// contract-update rules forbid adding new fields, so the new target lives
    /// in code that ships with every upgrade. This field stays for storage
    /// compatibility but is no longer read by the runtime path.
    access(self) let janusTokenEVM: EVM.EVMAddress

    /// Active implementation version string.
    access(self) var activeImpl: String

    /// Whether contract is paused (emergency stop).
    access(self) var paused: Bool

    /// Pending impl swap: new impl version string.
    access(self) var pendingImplVersion: String?

    /// Unix timestamp after which the pending impl swap can be finalized (48h).
    access(self) var pendingImplUnlockAt: UFix64

    // ─── Events ─────────────────────────────────────────────────────────────────

    /// Wrapped — emitted on a successful Cadence-side wrap.
    /// `toEVMHex` is the EVM JanusFlow proxy address the call routed to
    /// (formerly the recipient's EVM address; kept name for backwards
    /// compatibility with v0.2.1 indexers).
    access(all) event Wrapped(
        depositor: Address,
        amountFlow: UFix64,
        toEVMHex: String
    )

    /// New in v0.3 — shielded transfer routed through the EVM proxy.
    access(all) event ShieldedTransferred(
        from: Address,
        toEVMHex: String
    )

    /// Unwrapped — emitted on a successful Cadence-side unwrap.
    /// `recipient` is the Flow address that signed; FLOW is actually sent
    /// to `recipientEVMHex` by the EVM proxy.
    access(all) event Unwrapped(
        from: Address,
        recipient: Address,
        amountFlow: UFix64
    )

    /// LEGACY (v0.2.1) — kept because Cadence upgrades cannot remove event
    /// declarations. Never emitted in v0.3 (use ShieldedTransferred instead).
    access(all) event ConfidentialTransferred(
        from: Address,
        to: Address,
        transferAmountAttoFlow: UInt256
    )

    /// LEGACY (v0.2.1) — kept because Cadence upgrades cannot remove event
    /// declarations. Never emitted in v0.3 (pubkeys live on EVM now).
    access(all) event PubkeyRegistered(account: Address)

    access(all) event Paused()
    access(all) event Unpaused()
    access(all) event ImplSwapProposed(pendingVersion: String, unlockAt: UFix64)
    access(all) event ImplSwapped(oldVersion: String, newVersion: String)
    access(all) event ImplSwapCancelled()

    /// TESTNET-ONLY admin reset of a stuck commitment slot on the EVM proxy.
    /// PRIVACY-BREAKING — see comments above `adminResetSlot` below.
    access(all) event AdminSlotReset(
        target: Address,
        targetEVMHex: String
    )

    /// v0.5.2 — Emitted when a user publishes (or rotates) their memo pubkey.
    /// Indexers can use this to build an address → pubkey lookup without an
    /// on-chain mapping (the authoritative pubkey is in the EVM memoKeyPubX/Y
    /// mapping; this event is the Cadence-side mirror for Cadence-only indexers).
    access(all) event MemoKeyPublished(
        owner: Address,
        pubkeyX: UInt256,
        pubkeyY: UInt256
    )

    // ─── MemoKey Resource (v0.5.2) ───────────────────────────────────────────────
    //
    // Generic BabyJub pubkey store. ANY JanusFlow privacy app (PrivateTip,
    // SealedBidNFT, HiddenPackOpening, etc.) uses this type — NOT an app-specific
    // resource. Apps import JanusFlow to get MemoKey rather than each defining
    // their own keypair store.
    //
    // Storage layout (per user):
    //   /storage/openjanusMemoKey  — &MemoKey (private; owner borrows)
    //   /public/openjanusMemoKey   — &{MemoKeyPublic} (read-only pubkey for senders)
    //
    // Privacy principle: the privkey is NEVER passed to chain and NEVER stored.
    // Derivation is entirely client-side (sign-derive pattern: HKDF(wallet
    // signature) → BabyJub scalar). Only (pubkeyX, pubkeyY) go on-chain.

    /// Read-only interface for the public capability. Senders borrow this to
    /// encrypt ShieldedNotes or snapshot blobs to the recipient.
    access(all) resource interface MemoKeyPublic {
        access(all) view fun getPubkeyX(): UInt256
        access(all) view fun getPubkeyY(): UInt256
    }

    /// BabyJub pubkey store. Owns the pubkey; privkey stays off-chain forever.
    access(all) resource MemoKey: MemoKeyPublic {
        access(self) let pubkeyX: UInt256
        access(self) let pubkeyY: UInt256

        init(pubkeyX: UInt256, pubkeyY: UInt256) {
            self.pubkeyX = pubkeyX
            self.pubkeyY = pubkeyY
        }

        /// Public — anyone with the public capability can read the pubkey.
        access(all) view fun getPubkeyX(): UInt256 { return self.pubkeyX }
        access(all) view fun getPubkeyY(): UInt256 { return self.pubkeyY }
    }

    /// v0.5.2 MemoKey storage path (canonical — all JanusFlow apps use this).
    access(all) view fun memoKeyStoragePath(): StoragePath {
        return /storage/openjanusMemoKey
    }

    /// v0.5.2 MemoKey public capability path (canonical).
    access(all) view fun memoKeyPublicPath(): PublicPath {
        return /public/openjanusMemoKey
    }

    /// Factory: mint a fresh MemoKey resource (pubkey only — privkey never here).
    /// The caller is responsible for saving it to memoKeyStoragePath() and
    /// publishing the capability at memoKeyPublicPath().
    /// Use setup_memo_key.cdc transaction for the full atomic Cadence+EVM setup.
    access(all) fun createMemoKey(
        pubkeyX: UInt256,
        pubkeyY: UInt256
    ): @MemoKey {
        return <- create MemoKey(pubkeyX: pubkeyX, pubkeyY: pubkeyY)
    }

    /// View function: read another account's published memo pubkey.
    /// Returns nil if no MemoKey capability is published at the canonical path.
    access(all) fun getMemoPubkey(owner: Address): {String: UInt256}? {
        let acct = getAccount(owner)
        if let cap = acct.capabilities.borrow<&{MemoKeyPublic}>(self.memoKeyPublicPath()) {
            return {"x": cap.getPubkeyX(), "y": cap.getPubkeyY()}
        }
        return nil
    }

    // ─── Public User Functions ────────────────────────────────────────────────────

    /// Wrap `vault.balance` FLOW into a hidden commitment on the EVM JanusFlow
    /// proxy. The on-chain EVM call is gated by an amount-disclose Groth16
    /// proof that binds `txCommit` to the wrapped amount.
    ///
    /// @param signer        Signing Flow account (must have COA at /storage/evm)
    /// @param vault         FLOW vault to drain (amount > 0)
    /// @param txCommit      Pedersen commit (Cx, Cy) to the wrapped amount
    /// @param amountProof   Packed Groth16 amount-disclose proof (8 limbs)
    /// @param calldataHex   ABI-encoded calldata for JanusFlow.wrap(txCommit,
    ///                      amountProof) — built off-chain (e.g. ethers.js)
    ///                      to avoid Cadence's EVM.encodeABIWithSignature
    ///                      issues with fixed-length array params.
    access(all) fun wrap(
        signer: auth(BorrowValue) &Account,
        vault: @FlowToken.Vault,
        txCommit: [UInt256],
        amountProof: [UInt256],
        calldataHex: String
    ) {
        pre {
            !self.paused: "JanusFlow: contract is paused"
        }

        let amount = vault.balance
        assert(amount > 0.0, message: "JanusFlow.wrap: zero amount")

        // attoFLOW = amount * 1e18 — UFix64 is fixed-point with 8 decimal places,
        // so amount * 1e8 gives integer "flow units" and * 1e10 lifts to atto.
        let flowUnits: UInt64 = UInt64(amount * 100_000_000.0)
        let attoflowU256: UInt256 = UInt256(flowUnits) * 10_000_000_000
        let attoflowU: UInt = UInt(flowUnits) * 10_000_000_000

        // Structural validation (proof shapes, non-zero amount).
        let errMsg = JanusFlowImpl.validateWrap(
            amountAttoFlow: attoflowU256,
            txCommit: txCommit,
            amountProof: amountProof
        )
        assert(errMsg == "", message: "JanusFlow.wrap: ".concat(errMsg))

        // Move FLOW from signer's vault → signer's COA (so the EVM call's
        // msg.value can be sourced from the COA's balance).
        let coa = self._borrowCOA(signer: signer)
        coa.deposit(from: <-vault)

        // EVM call: JanusFlow.wrap verifies amount-disclose proof,
        // adds `amount` to totalLocked, and accepts the shielded credit.
        let target = self._getEVMTarget()
        let evmResult = coa.call(
            to: target,
            data: calldataHex.decodeHex(),
            gasLimit: 700_000,
            value: EVM.Balance(attoflow: attoflowU)
        )
        assert(
            evmResult.status == EVM.Status.successful,
            message: "JanusFlow.wrap EVM call failed: ".concat(evmResult.errorMessage)
        )

        // Mirror custody aggregate (authoritative value is on EVM).
        self.totalLocked = self.totalLocked + amount

        emit Wrapped(
            depositor: signer.address,
            amountFlow: amount,
            toEVMHex: target.toString()
        )
    }

    /// Shielded transfer: move a HIDDEN amount from the signer's commitment
    /// to `toEVMHex` on the EVM JanusFlow proxy. The amount is hidden on
    /// every channel (calldata, events, storage) — only the
    /// confidential-transfer Groth16 proof gates the operation.
    ///
    /// No FLOW moves out of EVM custody; only Pedersen commitments shift.
    ///
    /// @param signer        Sending Flow account (must have COA at /storage/evm)
    /// @param toEVMHex      Recipient EVM address (0x-prefixed hex)
    /// @param publicInputs  Confidential-transfer public inputs (6 limbs):
    ///                      [0..1]=C_old, [2..3]=C_tx, [4..5]=C_new
    /// @param proof         Packed Groth16 transfer proof (8 limbs)
    /// @param calldataHex   ABI-encoded calldata for
    ///                      JanusFlow.shieldedTransfer(to, publicInputs, proof)
    access(all) fun shieldedTransfer(
        signer: auth(BorrowValue) &Account,
        toEVMHex: String,
        publicInputs: [UInt256],
        proof: [UInt256],
        calldataHex: String
    ) {
        pre {
            !self.paused: "JanusFlow: contract is paused"
        }

        let errMsg = JanusFlowImpl.validateShieldedTransfer(
            publicInputs: publicInputs,
            proof: proof
        )
        assert(errMsg == "", message: "JanusFlow.shieldedTransfer: ".concat(errMsg))

        let coa = self._borrowCOA(signer: signer)
        let target = self._getEVMTarget()
        let evmResult = coa.call(
            to: target,
            data: calldataHex.decodeHex(),
            gasLimit: 700_000,
            value: EVM.Balance(attoflow: 0)
        )
        assert(
            evmResult.status == EVM.Status.successful,
            message: "JanusFlow.shieldedTransfer EVM call failed: ".concat(evmResult.errorMessage)
        )

        emit ShieldedTransferred(from: signer.address, toEVMHex: toEVMHex)
    }

    /// Unwrap: release `claimedAmount` FLOW from EVM custody to
    /// `recipientEVMHex` (typically the signer's COA address). Gated by
    /// BOTH an amount-disclose proof and a confidential-transfer proof.
    ///
    /// EVM JanusFlow.unwrap sends FLOW via `recipient.call{value: ...}`, so
    /// nothing needs to flow back through the Cadence FlowToken vault.
    ///
    /// @param signer               Caller (must own the source commitment)
    /// @param claimedAmount        FLOW amount being released (UFix64)
    /// @param recipientEVMHex      EVM address that receives FLOW (0x-hex)
    /// @param txCommit             Pedersen commit (Cx, Cy) binding claimedAmount
    /// @param amountProof          Packed amount-disclose proof (8 limbs)
    /// @param transferPublicInputs Transfer public inputs (6 limbs)
    /// @param transferProof        Packed transfer proof (8 limbs)
    /// @param calldataHex          ABI-encoded calldata for JanusFlow.unwrap(
    ///                              claimedAmount, recipient, txCommit,
    ///                              amountProof, transferPublicInputs,
    ///                              transferProof)
    access(all) fun unwrap(
        signer: auth(BorrowValue) &Account,
        claimedAmount: UFix64,
        recipientEVMHex: String,
        txCommit: [UInt256],
        amountProof: [UInt256],
        transferPublicInputs: [UInt256],
        transferProof: [UInt256],
        calldataHex: String
    ) {
        pre {
            !self.paused: "JanusFlow: contract is paused"
            claimedAmount > 0.0: "JanusFlow.unwrap: zero amount"
        }

        let flowUnits: UInt64 = UInt64(claimedAmount * 100_000_000.0)
        let attoflow: UInt256 = UInt256(flowUnits) * 10_000_000_000

        let errMsg = JanusFlowImpl.validateUnwrap(
            claimedAmountAttoFlow: attoflow,
            txCommit: txCommit,
            amountProof: amountProof,
            transferPublicInputs: transferPublicInputs,
            transferProof: transferProof
        )
        assert(errMsg == "", message: "JanusFlow.unwrap: ".concat(errMsg))

        let coa = self._borrowCOA(signer: signer)
        let target = self._getEVMTarget()
        let evmResult = coa.call(
            to: target,
            data: calldataHex.decodeHex(),
            gasLimit: 1_500_000,
            value: EVM.Balance(attoflow: 0)
        )
        assert(
            evmResult.status == EVM.Status.successful,
            message: "JanusFlow.unwrap EVM call failed: ".concat(evmResult.errorMessage)
        )

        // Mirror custody aggregate. The router can't drop below 0 — and
        // if EVM accepted the unwrap, the underlying totalLocked decreased
        // by the same amount, so this stays in sync.
        if claimedAmount <= self.totalLocked {
            self.totalLocked = self.totalLocked - claimedAmount
        } else {
            // Pre-v0.3 wraps were tracked against the OLD EVM target, so the
            // router-side mirror may be smaller than the new EVM totalLocked.
            // Clamp to zero rather than underflow — the EVM side remains
            // authoritative.
            self.totalLocked = 0.0
        }

        emit Unwrapped(
            from: signer.address,
            recipient: signer.address,
            amountFlow: claimedAmount
        )
    }

    // ─── Admin Functions ─────────────────────────────────────────────────────────

    access(all) resource AdminResource {

        access(all) fun pause() {
            JanusFlow.paused = true
            emit Paused()
        }

        access(all) fun unpause() {
            JanusFlow.paused = false
            emit Unpaused()
        }

        access(all) fun proposeImplSwap(newImplVersion: String) {
            JanusFlow.pendingImplVersion = newImplVersion
            JanusFlow.pendingImplUnlockAt = getCurrentBlock().timestamp + 172800.0
            emit ImplSwapProposed(
                pendingVersion: newImplVersion,
                unlockAt: JanusFlow.pendingImplUnlockAt
            )
        }

        access(all) fun finalizeImplSwap() {
            pre {
                JanusFlow.pendingImplVersion != nil: "JanusFlow: no pending impl swap"
                getCurrentBlock().timestamp >= JanusFlow.pendingImplUnlockAt:
                    "JanusFlow: impl time-lock has not expired yet"
            }
            let oldVersion = JanusFlow.activeImpl
            JanusFlow.activeImpl = JanusFlow.pendingImplVersion!
            JanusFlow.pendingImplVersion = nil
            JanusFlow.pendingImplUnlockAt = 0.0
            emit ImplSwapped(oldVersion: oldVersion, newVersion: JanusFlow.activeImpl)
        }

        access(all) fun cancelImplSwap() {
            JanusFlow.pendingImplVersion = nil
            JanusFlow.pendingImplUnlockAt = 0.0
            emit ImplSwapCancelled()
        }
    }

    // ─── adminResetSlot — TESTNET-ONLY commitment recovery ───────────────────────
    //
    // PRIVACY-BREAKING. Routes through the EVM JanusFlow proxy's
    // `adminResetSlot(address)` function (which is itself chainid-pinned to
    // Flow EVM testnet 545 and onlyOwner). The signer of the Cadence tx must:
    //   1. own the AdminResource at /storage/janusFlowAdmin (so they're the
    //      Cadence-side admin); AND
    //   2. their COA at /storage/evm must be the EVM owner of the proxy (so
    //      the EVM-side onlyOwner check passes).
    //
    // These two conditions are satisfied by exactly one account on testnet:
    // openjanus-flow (0xbef3c77681c15397) whose COA is
    // 0x...022f6b30af48a94787 — the proxy owner.
    //
    // Resolves `target` (a Cadence address) to the target's COA EVM address by
    // reading the public capability at /public/evm on the target account, then
    // emits AdminSlotReset for off-chain indexers.

    access(all) fun adminResetSlot(
        signer: auth(BorrowValue) &Account,
        target: Address
    ) {
        // The real admin gate is on the EVM side:
        //   * proxy.adminResetSlot has `onlyOwner` (proxy owner = signer's
        //     COA = 0x...022f6b30af48a94787);
        //   * the EVM impl ALSO checks `block.chainid == 545`, making this
        //     function inert on any chain except Flow EVM testnet.
        //
        // A non-owner signer's COA call will revert with
        // OwnableUnauthorizedAccount and roll back the whole Cadence
        // transaction atomically, so this function is safe to expose as
        // `access(all)`.
        //
        // We do NOT borrow the JanusFlow AdminResource here because that
        // resource lives at 0x5dcbeb41055ec57e (the Cadence contract
        // deployer) while the EVM proxy owner is openjanus-flow's COA at
        // 0xbef3c77681c15397 — two different Cadence accounts. Requiring
        // both would force a 2-signer transaction for every reset; relying
        // on EVM-side onlyOwner is simpler and equivalently secure given the
        // EVM proxy is the authoritative source of truth for the
        // commitments mapping.

        // Resolve target Cadence account → COA EVM address via public capability.
        let targetAcct = getAccount(target)
        let targetCOARef = targetAcct.capabilities
            .borrow<&EVM.CadenceOwnedAccount>(/public/evm)
            ?? panic("JanusFlow.adminResetSlot: target account has no published COA at /public/evm")
        let targetEVM = targetCOARef.address()
        let targetEVMHex = targetEVM.toString()

        // Build calldata for EVM `adminResetSlot(address)`:
        //   selector 0xa8e50826 || abi.encode(address)
        // EVM addresses are 20 bytes; ABI encoding pads them to 32 bytes
        // (left-pad with 12 zero bytes).
        var calldata: [UInt8] = [0xa8 as UInt8, 0xe5 as UInt8, 0x08 as UInt8, 0x26 as UInt8]
        // 12 zero bytes of left-padding
        var padIdx = 0
        while padIdx < 12 {
            calldata.append(0 as UInt8)
            padIdx = padIdx + 1
        }
        // 20 bytes of the EVM address
        for b in targetEVM.bytes {
            calldata.append(b)
        }

        let signerCOA = signer.storage
            .borrow<auth(EVM.Call) &EVM.CadenceOwnedAccount>(from: /storage/evm)
            ?? panic("JanusFlow.adminResetSlot: signer has no COA at /storage/evm")
        let target_evm = self._getEVMTarget()
        let result = signerCOA.call(
            to: target_evm,
            data: calldata,
            gasLimit: 200_000,
            value: EVM.Balance(attoflow: 0)
        )
        assert(
            result.status == EVM.Status.successful,
            message: "JanusFlow.adminResetSlot EVM call failed: ".concat(result.errorMessage)
        )

        emit AdminSlotReset(target: target, targetEVMHex: targetEVMHex)
    }

    // ─── View Functions ──────────────────────────────────────────────────────────

    access(all) view fun getTotalLocked(): UFix64 {
        return self.totalLocked
    }

    /// Active EVM target hex (hardcoded in `_getEVMTarget()`).
    access(all) fun getJanusTokenAddress(): String {
        return self._getEVMTarget().toString()
    }

    access(all) view fun isPaused(): Bool {
        return self.paused
    }

    access(all) view fun getActiveImplVersion(): String {
        return self.activeImpl
    }

    access(all) view fun getPendingImplVersion(): String? {
        return self.pendingImplVersion
    }

    access(all) view fun getPendingImplUnlockAt(): UFix64 {
        return self.pendingImplUnlockAt
    }

    /// LEGACY (v0.2.1): always nil in v0.3 (commitments live on EVM now).
    access(all) view fun getCommitment(user: Address): [UInt8]? {
        return self.commitments[user]
    }

    /// LEGACY (v0.2.1): always nil in v0.3.
    access(all) view fun getPubkey(user: Address): [UInt8]? {
        return self.pubkeys[user]
    }

    /// LEGACY (v0.2.1): always false in v0.3.
    access(all) view fun hasCommitment(user: Address): Bool {
        return self.commitments[user] != nil
    }

    // ─── Private Helpers ─────────────────────────────────────────────────────────

    /// The active EVM JanusFlow proxy. Hardcoded in source because Cadence
    /// upgrades cannot add new contract-level fields and we don't want the
    /// old `janusTokenEVM` (set once in v0.2.1 init) to silently keep routing
    /// to the leaky JanusToken design.
    ///
    /// To migrate to a new EVM proxy in the future, update this string and
    /// run `flow accounts update-contract JanusFlow ...`. Hardcoded migration
    /// is intentional — every change has to ship as a reviewed code update
    /// rather than a single admin transaction.
    access(self) fun _getEVMTarget(): EVM.EVMAddress {
        // v0.3 EVM JanusFlow proxy on Flow EVM testnet.
        return EVM.addressFromString("0x09A3DCa868EcC39360fDe4E22046eCfcbA5b4078")
    }

    access(self) fun _borrowCOA(
        signer: auth(BorrowValue) &Account
    ): auth(EVM.Call) &EVM.CadenceOwnedAccount {
        return signer.storage
            .borrow<auth(EVM.Call) &EVM.CadenceOwnedAccount>(from: /storage/evm)
            ?? panic("JanusFlow: no COA at /storage/evm — call EVM.createCadenceOwnedAccount() first")
    }

    // ─── Initializer ─────────────────────────────────────────────────────────────

    init(janusTokenHex: String) {
        self.AdminStoragePath = /storage/janusFlowAdmin

        // janusTokenEVM is kept for storage compatibility (Cadence upgrades
        // cannot remove this field on a contract that has already been
        // initialized in production). It is NOT used at runtime — see
        // `_getEVMTarget()` for the active target.
        self.janusTokenEVM = EVM.addressFromString(janusTokenHex)

        self.totalLocked = 0.0
        self.commitments = {}
        self.pubkeys = {}
        self.paused = false
        self.activeImpl = "0.3.0"
        self.pendingImplVersion = nil
        self.pendingImplUnlockAt = 0.0

        self.account.storage.save(
            <-create AdminResource(),
            to: self.AdminStoragePath
        )
    }
}

// JanusFlow.cdc — Router + custody for confidential FLOW wrapping
//
// Architecture: Router/façade + swappable pure-logic implementation
//
//   JanusFlow   = router + custody (FlowToken vault, commitments, pubkeys)
//                 State NEVER moves on impl swap.
//
//   JanusFlowImpl = pure-logic impl (stateless, no resources)
//                   Swappable via 48h time-lock.
//
// Cross-VM design (per-user COA pattern):
//   Proof verification happens on EVM (JanusToken.sol).
//   The Cadence router calls JanusToken via the USER's COA as msg.sender.
//   EVM rejects invalid proofs → Cadence tx rolls back → no state update.
//
// Admin model: capability-based AdminResource in contract deployer's storage.
//
// Pause: emergency stop on all user-facing operations.
//
// Impl swap: 48h time-lock so apps can react before upgrade takes effect.
//
// Deployed at: bef3c77681c15397 (openjanus-flow secondary account)
// EVM target: JanusToken at 0xb12E600fFcde967210cFD81CF9f32bBB6e68a499
//
// Replaces zombie legacy at 0x28fef3d1d6a12800 (which cannot be removed per protocol rules).

import "EVM"
import "FlowToken"
import "FungibleToken"
import IJanusFlowImpl from 0xbef3c77681c15397
import JanusFlowImpl from 0xbef3c77681c15397

access(all) contract JanusFlow {

    // ─── Storage Paths ──────────────────────────────────────────────────────────

    access(all) let AdminStoragePath: StoragePath

    // ─── State — Custody ─────────────────────────────────────────────────────────
    // Custody NEVER moves on impl swap.

    /// Total FLOW locked in this contract (across all users)
    access(self) var totalLocked: UFix64

    /// Per-user encrypted commitment slots.
    /// Value = 128-byte ElGamal ciphertext (4 × 32-byte field elements: C1x, C1y, C2x, C2y).
    /// nil = no commitment (user hasn't wrapped yet).
    access(self) var commitments: {Address: [UInt8]}

    /// Per-user BabyJubJub public keys (64 bytes: x || y).
    access(self) var pubkeys: {Address: [UInt8]}

    // ─── State — Router ──────────────────────────────────────────────────────────

    /// JanusToken EVM contract address (set at deploy time, immutable)
    access(self) let janusTokenEVM: EVM.EVMAddress

    /// Active implementation version string
    access(self) var activeImpl: String

    /// Whether contract is paused (emergency stop)
    access(self) var paused: Bool

    /// Pending impl swap: new impl version string
    access(self) var pendingImplVersion: String?

    /// Unix timestamp after which the pending impl swap can be finalized (48h delay)
    access(self) var pendingImplUnlockAt: UFix64

    // ─── Events ─────────────────────────────────────────────────────────────────

    access(all) event Wrapped(
        depositor: Address,
        amountFlow: UFix64,
        toEVMHex: String
    )
    access(all) event ConfidentialTransferred(
        from: Address,
        to: Address,
        transferAmountAttoFlow: UInt256
    )
    access(all) event Unwrapped(
        from: Address,
        recipient: Address,
        amountFlow: UFix64
    )
    access(all) event PubkeyRegistered(account: Address)
    access(all) event Paused()
    access(all) event Unpaused()
    access(all) event ImplSwapProposed(pendingVersion: String, unlockAt: UFix64)
    access(all) event ImplSwapped(oldVersion: String, newVersion: String)
    access(all) event ImplSwapCancelled()

    // ─── Public User Functions ────────────────────────────────────────────────────

    /// Register a BabyJubJub public key for the signer's account.
    ///
    /// @param signer       Flow account with COA at /storage/evm
    /// @param pubkey       64-byte BabyJubJub public key (x || y, big-endian 32B each)
    /// @param calldataHex  ABI-encoded calldata for JanusToken.registerPubkey(uint256,uint256)
    access(all) fun registerPubkey(
        signer: auth(BorrowValue) &Account,
        pubkey: [UInt8],
        calldataHex: String
    ) {
        pre {
            !self.paused: "JanusFlow: contract is paused"
            pubkey.length == 64: "JanusFlow: pubkey must be 64 bytes"
        }

        let user = signer.address
        let coa = self._borrowCOA(signer: signer)

        // Call JanusToken.registerPubkey on EVM (registers pubkey in EVM accounting)
        let result = coa.call(
            to: self.janusTokenEVM,
            data: calldataHex.decodeHex(),
            gasLimit: 200_000,
            value: EVM.Balance(attoflow: 0)
        )
        assert(
            result.status == EVM.Status.successful,
            message: "JanusFlow.registerPubkey EVM call failed: ".concat(result.errorMessage)
        )

        // Store pubkey in Cadence state
        self.pubkeys[user] = pubkey
        emit PubkeyRegistered(account: user)
    }

    /// Wrap FLOW into a confidential slot for a recipient.
    ///
    /// Flow:
    ///   1. Impl validates inputs (size checks, zero-amount guard).
    ///   2. FLOW vault receives custody.
    ///   3. EVM call verifies Groth16 proof (encrypt_consistency).
    ///   4. Commitment state updated.
    ///
    /// @param signer       The sending Flow account (must have COA at /storage/evm)
    /// @param vault        FLOW to lock (amount > 0)
    /// @param recipient    Recipient's Flow address
    /// @param toEVMHex     Recipient's EVM address (hex with 0x prefix)
    /// @param ciphertext   128-byte accumulated ElGamal ciphertext for recipient
    /// @param senderNonce  Sender's current nonce (must match JanusToken on-chain)
    /// @param calldataHex  ABI-encoded calldata for JanusToken.wrap(...)
    access(all) fun wrap(
        signer: auth(BorrowValue) &Account,
        vault: @FlowToken.Vault,
        recipient: Address,
        toEVMHex: String,
        ciphertext: [UInt8],
        senderNonce: UInt256,
        calldataHex: String
    ) {
        pre {
            !self.paused: "JanusFlow: contract is paused"
        }

        let amount = vault.balance
        assert(amount > 0.0, message: "JanusFlow.wrap: zero amount")

        // Convert UFix64 FLOW to attoFLOW for impl validation
        let flowUnits: UInt64 = UInt64(amount * 100_000_000.0)
        let attoflow: UInt256 = UInt256(flowUnits) * 10_000_000_000

        // Ask impl to validate inputs (structural checks)
        let errMsg = JanusFlowImpl.validateWrap(
            amountAttoFlow: attoflow,
            ciphertext: ciphertext,
            recipient: recipient,
            hasExistingCommitment: self.commitments[recipient] != nil
        )
        assert(errMsg == "", message: "JanusFlow.wrap: ".concat(errMsg))

        // Custody: FLOW enters the contract vault
        self._depositToVault(vault: <-vault)
        self.totalLocked = self.totalLocked + amount

        // EVM call: JanusToken.wrap verifies Groth16 proof + updates EVM accounting
        let coa = self._borrowCOA(signer: signer)
        let attoflowUInt: UInt = UInt(flowUnits) * 10_000_000_000
        let evmResult = coa.call(
            to: self.janusTokenEVM,
            data: calldataHex.decodeHex(),
            gasLimit: 400_000,
            value: EVM.Balance(attoflow: attoflowUInt)
        )
        assert(
            evmResult.status == EVM.Status.successful,
            message: "JanusFlow.wrap EVM call failed: ".concat(evmResult.errorMessage)
        )

        // Update commitment state (client sends the accumulated ciphertext)
        self.commitments[recipient] = ciphertext

        emit Wrapped(
            depositor: signer.address,
            amountFlow: amount,
            toEVMHex: toEVMHex
        )
    }

    /// Confidential transfer: move encrypted balance from sender to recipient.
    /// No FLOW moves out of the contract — only EVM accounting and commitments change.
    ///
    /// @param signer              Sending Flow account (must have registered pubkey + COA)
    /// @param recipient           Recipient's Flow address
    /// @param toEVMHex            Recipient's EVM address
    /// @param transferAttoFlow    Amount in attoFLOW to transfer
    /// @param senderNonce         Sender's current nonce
    /// @param newSenderCiphertext Sender's new commitment after transfer (128 bytes)
    /// @param recipientCiphertext Recipient's new accumulated commitment (128 bytes)
    /// @param calldataHex         ABI-encoded calldata for JanusToken.confidentialTransfer(...)
    access(all) fun confidentialTransfer(
        signer: auth(BorrowValue) &Account,
        recipient: Address,
        toEVMHex: String,
        transferAttoFlow: UInt256,
        senderNonce: UInt256,
        newSenderCiphertext: [UInt8],
        recipientCiphertext: [UInt8],
        calldataHex: String
    ) {
        pre {
            !self.paused: "JanusFlow: contract is paused"
        }

        let sender = signer.address
        assert(
            self.commitments[sender] != nil,
            message: "JanusFlow.confidentialTransfer: sender has no commitment"
        )

        // Ask impl to validate (structural checks)
        let errMsg = JanusFlowImpl.validateTransfer(
            hasSenderCommitment: true,
            transferAttoFlow: transferAttoFlow,
            recipientCiphertext: recipientCiphertext,
            newSenderCiphertext: newSenderCiphertext
        )
        assert(errMsg == "", message: "JanusFlow.confidentialTransfer: ".concat(errMsg))

        // EVM call: JanusToken.confidentialTransfer verifies Groth16 proof + updates EVM state
        let coa = self._borrowCOA(signer: signer)
        let evmResult = coa.call(
            to: self.janusTokenEVM,
            data: calldataHex.decodeHex(),
            gasLimit: 600_000,
            value: EVM.Balance(attoflow: 0)
        )
        assert(
            evmResult.status == EVM.Status.successful,
            message: "JanusFlow.confidentialTransfer EVM call failed: ".concat(evmResult.errorMessage)
        )

        // Update Cadence commitments (client provides both sides)
        self.commitments[sender] = newSenderCiphertext
        self.commitments[recipient] = recipientCiphertext

        emit ConfidentialTransferred(
            from: sender,
            to: recipient,
            transferAmountAttoFlow: transferAttoFlow
        )
    }

    /// Unwrap: prove decrypt_open ZK proof + release FLOW to recipient.
    ///
    /// @param signer          Caller (must be slot owner with COA)
    /// @param claimedAmount   Amount in UFix64 FLOW claimed in slot
    /// @param recipient       Flow address to receive FLOW
    /// @param calldataHex     ABI-encoded calldata for JanusToken.unwrap(...)
    access(all) fun unwrap(
        signer: auth(BorrowValue) &Account,
        claimedAmount: UFix64,
        recipient: Address,
        calldataHex: String
    ) {
        pre {
            !self.paused: "JanusFlow: contract is paused"
            claimedAmount > 0.0: "JanusFlow.unwrap: zero amount"
            claimedAmount <= self.totalLocked: "JanusFlow.unwrap: amount exceeds totalLocked"
        }

        let user = signer.address

        // Convert to attoFLOW for impl
        let flowUnits: UInt64 = UInt64(claimedAmount * 100_000_000.0)
        let attoflow: UInt256 = UInt256(flowUnits) * 10_000_000_000

        // Impl validates structural constraints
        let errMsg = JanusFlowImpl.validateUnwrap(
            hasCommitment: self.commitments[user] != nil,
            claimedAmountAttoFlow: attoflow
        )
        assert(errMsg == "", message: "JanusFlow.unwrap: ".concat(errMsg))

        // EVM call: JanusToken.unwrap verifies Groth16 proof + updates EVM accounting
        let coa = self._borrowCOA(signer: signer)
        let evmResult = coa.call(
            to: self.janusTokenEVM,
            data: calldataHex.decodeHex(),
            gasLimit: 600_000,
            value: EVM.Balance(attoflow: 0)
        )
        assert(
            evmResult.status == EVM.Status.successful,
            message: "JanusFlow.unwrap EVM call failed: ".concat(evmResult.errorMessage)
        )

        // Clear commitment slot (full drain — partial unwrap not supported in v0.1.0)
        self.commitments.remove(key: user)

        // Release FLOW from custody to recipient
        self._releaseFromVault(recipient: recipient, amount: claimedAmount)
        self.totalLocked = self.totalLocked - claimedAmount

        emit Unwrapped(from: user, recipient: recipient, amountFlow: claimedAmount)
    }

    // ─── Admin Functions ─────────────────────────────────────────────────────────

    access(all) resource AdminResource {

        /// Pause all user-facing operations (emergency stop)
        access(all) fun pause() {
            JanusFlow.paused = true
            emit Paused()
        }

        /// Resume all user-facing operations
        access(all) fun unpause() {
            JanusFlow.paused = false
            emit Unpaused()
        }

        /// Propose an implementation swap (starts 48h time-lock).
        /// @param newImplVersion  Version string of the new impl to activate
        access(all) fun proposeImplSwap(newImplVersion: String) {
            JanusFlow.pendingImplVersion = newImplVersion
            JanusFlow.pendingImplUnlockAt = getCurrentBlock().timestamp + 172800.0 // 48h in seconds
            emit ImplSwapProposed(
                pendingVersion: newImplVersion,
                unlockAt: JanusFlow.pendingImplUnlockAt
            )
        }

        /// Finalize an impl swap after the 48h time-lock expires.
        access(all) fun finalizeImplSwap() {
            pre {
                JanusFlow.pendingImplVersion != nil: "JanusFlow: no pending impl swap"
                getCurrentBlock().timestamp >= JanusFlow.pendingImplUnlockAt:
                    "JanusFlow: time-lock has not expired yet"
            }
            let oldVersion = JanusFlow.activeImpl
            JanusFlow.activeImpl = JanusFlow.pendingImplVersion!
            JanusFlow.pendingImplVersion = nil
            JanusFlow.pendingImplUnlockAt = 0.0
            emit ImplSwapped(oldVersion: oldVersion, newVersion: JanusFlow.activeImpl)
        }

        /// Cancel a pending impl swap (no time-lock for cancellation)
        access(all) fun cancelImplSwap() {
            JanusFlow.pendingImplVersion = nil
            JanusFlow.pendingImplUnlockAt = 0.0
            emit ImplSwapCancelled()
        }
    }

    // ─── View Functions ──────────────────────────────────────────────────────────

    access(all) view fun getTotalLocked(): UFix64 {
        return self.totalLocked
    }

    access(all) view fun getJanusTokenAddress(): String {
        return self.janusTokenEVM.toString()
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

    access(all) view fun getCommitment(user: Address): [UInt8]? {
        return self.commitments[user]
    }

    access(all) view fun getPubkey(user: Address): [UInt8]? {
        return self.pubkeys[user]
    }

    access(all) view fun hasCommitment(user: Address): Bool {
        return self.commitments[user] != nil
    }

    // ─── Private Helpers ─────────────────────────────────────────────────────────

    access(self) fun _borrowCOA(signer: auth(BorrowValue) &Account): auth(EVM.Call) &EVM.CadenceOwnedAccount {
        return signer.storage
            .borrow<auth(EVM.Call) &EVM.CadenceOwnedAccount>(from: /storage/evm)
            ?? panic("JanusFlow: no COA at /storage/evm — call EVM.createCadenceOwnedAccount() first")
    }

    access(self) fun _depositToVault(vault: @FlowToken.Vault) {
        let contractVault = self.account.storage
            .borrow<auth(FungibleToken.Withdraw) &FlowToken.Vault>(from: /storage/janusFlowVault)
            ?? panic("JanusFlow: vault not initialized")
        contractVault.deposit(from: <-vault)
    }

    access(self) fun _releaseFromVault(recipient: Address, amount: UFix64) {
        let contractVault = self.account.storage
            .borrow<auth(FungibleToken.Withdraw) &FlowToken.Vault>(from: /storage/janusFlowVault)
            ?? panic("JanusFlow: vault not initialized")

        let withdrawVault <- contractVault.withdraw(amount: amount) as! @FlowToken.Vault

        let recipientRef = getAccount(recipient)
            .capabilities
            .borrow<&{FungibleToken.Receiver}>(/public/flowTokenReceiver)
            ?? panic("JanusFlow: recipient has no FlowToken receiver")

        recipientRef.deposit(from: <-withdrawVault)
    }

    // ─── Initializer ─────────────────────────────────────────────────────────────

    init(janusTokenHex: String) {
        self.AdminStoragePath = /storage/janusFlowAdmin

        self.janusTokenEVM = EVM.addressFromString(janusTokenHex)
        self.totalLocked = 0.0
        self.commitments = {}
        self.pubkeys = {}
        self.paused = false
        self.activeImpl = "0.1.0"
        self.pendingImplVersion = nil
        self.pendingImplUnlockAt = 0.0

        // Initialize FLOW custody vault
        let vault <- FlowToken.createEmptyVault(vaultType: Type<@FlowToken.Vault>())
        self.account.storage.save(<-vault, to: /storage/janusFlowVault)

        // Save admin resource to deployer's storage
        self.account.storage.save(
            <-create AdminResource(),
            to: self.AdminStoragePath
        )
    }
}

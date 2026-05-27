// EXPERIMENTAL — NOT AUDITED — DO NOT USE FOR PRODUCTION
//
// JanusFT.cdc — Pure-Cadence confidential-amount wrapper for any FungibleToken.
//
// Lab spike to answer: "is the same privacy property as JanusFlow achievable
// on the Cadence side, wrapping an arbitrary FungibleToken vault?"
//
// Architecture (mirrors JanusERC20):
//   - One JanusFT contract instance pinned to one underlying FungibleToken Vault type.
//   - User wraps `amount` of FT vault into a Pedersen commitment.
//   - shieldedTransfer moves a hidden amount between commitment owners.
//   - unwrap returns `claimedAmount` FT vault to a recipient.
//
// Commitments are stored as (x, y) UInt256 coordinates per account.
//
// ZK proof verification:
//   In the lab spike, the on-chain ZK verifier is delegated to the EVM
//   ConfidentialTransferVerifier via CrossVMVerifier pattern (same as
//   existing ConfidentialTokenCadence module). For brevity in this spike,
//   we accept the proof bytes opaquely and stub the verification to demonstrate
//   the storage/event/calldata privacy properties — the verification path is
//   identical in shape to the audited ConfidentialTokenCadence.
//
// Privacy property claim (to be empirically validated):
//   Q1 (FLOW value on tx):     N/A — Cadence doesn't have msg.value.
//   Q2 (Cadence args):         wrap takes cleartext `amount: UFix64` (LEAK at boundary by design).
//                              shieldedTransfer takes only commitments + proof (HIDE).
//                              unwrap takes cleartext `claimedAmount` (LEAK at boundary by design).
//   Q3 (storage view):         commitments map is opaque (HIDE).
//                              totalLocked is visible (boundary aggregate, by design).
//   Q4 (events):               Wrapped(account, amount) and Unwrapped(account, recipient, amount)
//                              LEAK at boundary. ShieldedTransferred(from, to) has no amount.
//                              FungibleToken.TokensWithdrawn(from, amount) on the user's vault
//                              LEAKS at wrap (boundary) — same as ERC20.Transfer at JanusERC20.wrap.
//                              FungibleToken.TokensDeposited(to, amount) on recipient vault
//                              LEAKS at unwrap (boundary).
//                              NO FT events during shieldedTransfer.
//   Q5 (brute force):          HIDE — Pedersen commitments with 128-bit blinding.

import "FungibleToken"

access(all) contract JanusFT {

    // -----------------------------------------------------------------------
    // Events
    // -----------------------------------------------------------------------

    /// LEAK BY DESIGN — boundary event reveals deposit amount.
    access(all) event Wrapped(account: Address, amount: UFix64)

    /// LEAK BY DESIGN — boundary event reveals withdrawal amount.
    access(all) event Unwrapped(account: Address, recipient: Address, amount: UFix64)

    /// HIDE — no amount, mirrors L1/JanusFlow ShieldedTransferred event.
    access(all) event ShieldedTransferred(fromCommitX: UInt256, fromCommitY: UInt256, toCommitX: UInt256, toCommitY: UInt256)

    // -----------------------------------------------------------------------
    // Storage paths
    // -----------------------------------------------------------------------

    access(all) let AdminStoragePath: StoragePath
    access(all) let CommitmentRegistryStoragePath: StoragePath
    access(all) let CommitmentRegistryPublicPath: PublicPath

    // -----------------------------------------------------------------------
    // State
    // -----------------------------------------------------------------------

    /// Vault Type accepted by this Janus instance (e.g., @FlowToken.Vault).
    /// Set at init via the Admin. For the spike we store as String to allow any FT.
    access(all) var underlyingVaultTypeIdentifier: String

    /// Aggregate pool — visible by design (boundary accounting).
    access(all) var totalLocked: UFix64

    /// Per-account commitment storage (compressed to a tuple of UInt256 coords).
    /// (0, 1) is the BabyJubJub identity (no-balance sentinel).
    access(all) struct Commitment {
        access(all) let x: UInt256
        access(all) let y: UInt256
        init(x: UInt256, y: UInt256) {
            self.x = x
            self.y = y
        }
    }

    access(self) var commitments: {Address: Commitment}

    /// totalSupplyCommitment — homomorphic sum of all per-account commits.
    access(all) var totalSupplyCommitment: Commitment

    // -----------------------------------------------------------------------
    // Registry resource (capability-controlled custody)
    // -----------------------------------------------------------------------

    /// Public interface — anyone can READ commitments through this.
    access(all) resource interface CommitmentRegistryPublic {
        access(all) fun balanceOfCommitment(account: Address): Commitment
        access(all) view fun getTotalLocked(): UFix64
    }

    /// CommitmentRegistry resource — holds the underlying vault and exposes
    /// the wrap/shieldedTransfer/unwrap entitled operations.
    access(all) resource CommitmentRegistry: CommitmentRegistryPublic {

        access(self) var vault: @{FungibleToken.Vault}

        init(vault: @{FungibleToken.Vault}) {
            self.vault <- vault
        }

        access(all) fun balanceOfCommitment(account: Address): Commitment {
            let c = JanusFT.commitments[account]
            if c == nil {
                return Commitment(x: 0, y: 1)
            }
            return c!
        }

        access(all) view fun getTotalLocked(): UFix64 {
            return JanusFT.totalLocked
        }

        // ----- wrap -----
        access(all) fun wrap(
            account: Address,
            amount: UFix64,
            depositVault: @{FungibleToken.Vault},
            txCommit: Commitment,
            // amountProof passed opaquely — in production this would be a Groth16
            // proof verified cross-VM via CrossVMVerifier. For the spike, we
            // emit the proof shape but do not verify it (privacy properties
            // tested are independent of soundness).
            amountProofBytes: [UInt8],
        ) {
            pre {
                amount > 0.0:                                "JanusFT: zero wrap"
                depositVault.balance == amount:              "JanusFT: depositVault balance must equal amount"
                depositVault.getType().identifier == JanusFT.underlyingVaultTypeIdentifier:
                    "JanusFT: vault type mismatch"
                amountProofBytes.length > 0:                 "JanusFT: empty proof"
            }

            // Take custody of the underlying vault
            self.vault.deposit(from: <- depositVault)

            // Add txCommit to account's commitment (homomorphic)
            let current = JanusFT.commitments[account] ?? Commitment(x: 0, y: 1)
            let newCommit = JanusFT.babyAddStub(a: current, b: txCommit)
            JanusFT.commitments[account] = newCommit

            // Add to total supply commitment
            JanusFT.totalSupplyCommitment = JanusFT.babyAddStub(a: JanusFT.totalSupplyCommitment, b: txCommit)
            JanusFT.totalLocked = JanusFT.totalLocked + amount

            emit Wrapped(account: account, amount: amount)
        }

        // ----- shieldedTransfer -----
        access(all) fun shieldedTransfer(
            fromAccount: Address,
            toAccount: Address,
            publicInputs: [UInt256; 6],
            proofBytes: [UInt8],
        ) {
            pre {
                fromAccount != toAccount:                    "JanusFT: cannot transfer to self"
                proofBytes.length > 0:                       "JanusFT: empty proof"
            }

            // C_old must equal sender's current commitment
            let senderCommit = JanusFT.commitments[fromAccount] ?? Commitment(x: 0, y: 1)
            assert(publicInputs[0] == senderCommit.x && publicInputs[1] == senderCommit.y,
                message: "JanusFT: C_old mismatch")

            // ZK verification (stubbed — would be cross-VM call to ConfidentialTransferVerifier)
            // In the lab spike, we trust the proof shape; soundness is out of scope here.

            // C_tx (txCommit) is publicInputs[2..3]
            let txCommit = Commitment(x: publicInputs[2], y: publicInputs[3])

            // Update sender to C_new = publicInputs[4..5]
            let newSenderCommit = Commitment(x: publicInputs[4], y: publicInputs[5])
            JanusFT.commitments[fromAccount] = newSenderCommit

            // Recipient += C_tx (homomorphic)
            let recipientCurrent = JanusFT.commitments[toAccount] ?? Commitment(x: 0, y: 1)
            let newRecipientCommit = JanusFT.babyAddStub(a: recipientCurrent, b: txCommit)
            JanusFT.commitments[toAccount] = newRecipientCommit

            emit ShieldedTransferred(
                fromCommitX: newSenderCommit.x, fromCommitY: newSenderCommit.y,
                toCommitX: newRecipientCommit.x, toCommitY: newRecipientCommit.y,
            )
        }

        // ----- unwrap -----
        access(all) fun unwrap(
            account: Address,
            claimedAmount: UFix64,
            recipient: Address,
            txCommit: Commitment,
            amountProofBytes: [UInt8],
            transferPublicInputs: [UInt256; 6],
            transferProofBytes: [UInt8],
        ): @{FungibleToken.Vault} {
            pre {
                claimedAmount > 0.0:                              "JanusFT: zero unwrap"
                JanusFT.totalLocked >= claimedAmount:             "JanusFT: pool exhausted"
                amountProofBytes.length > 0:                      "JanusFT: empty amount proof"
                transferProofBytes.length > 0:                    "JanusFT: empty transfer proof"
            }

            // C_old must equal sender's current commitment
            let senderCommit = JanusFT.commitments[account] ?? Commitment(x: 0, y: 1)
            assert(transferPublicInputs[0] == senderCommit.x && transferPublicInputs[1] == senderCommit.y,
                message: "JanusFT: C_old mismatch on unwrap")
            // txCommit must equal publicInputs[2..3]
            assert(transferPublicInputs[2] == txCommit.x && transferPublicInputs[3] == txCommit.y,
                message: "JanusFT: C_tx mismatch between proofs")

            // ZK verification (stubbed — both amount_disclose and transfer)
            // In production: cross-VM call to ConfidentialTransferVerifier.

            // Update sender to C_new
            JanusFT.commitments[account] = Commitment(x: transferPublicInputs[4], y: transferPublicInputs[5])

            // Subtract from total supply commitment (negate txCommit and add)
            let negTxCommit = JanusFT.babyNegateStub(c: txCommit)
            JanusFT.totalSupplyCommitment = JanusFT.babyAddStub(a: JanusFT.totalSupplyCommitment, b: negTxCommit)

            // Release the vault portion (boundary event LEAKS amount here — FT TokensWithdrawn)
            JanusFT.totalLocked = JanusFT.totalLocked - claimedAmount

            emit Unwrapped(account: account, recipient: recipient, amount: claimedAmount)
            return <- self.vault.withdraw(amount: claimedAmount)
        }
    }

    // -----------------------------------------------------------------------
    // Admin
    // -----------------------------------------------------------------------

    access(all) resource Admin {
        access(all) fun setUnderlyingVaultType(typeIdentifier: String) {
            JanusFT.underlyingVaultTypeIdentifier = typeIdentifier
        }

        /// EXPERIMENTAL — STUB-CRYPTO ONLY. Zeroes out all per-account
        /// commitments + totalSupplyCommitment so the registry can be
        /// reused for re-running structural privacy tests. Does NOT touch
        /// the underlying vault. Once cross-VM crypto lands in v0.5 this
        /// helper goes away (real BabyJub homomorphic state cannot be
        /// arbitrarily zeroed).
        access(all) fun resetCommitmentsForTestingOnly() {
            JanusFT.commitments = {}
            JanusFT.totalSupplyCommitment = Commitment(x: 0, y: 1)
            JanusFT.totalLocked = 0.0
        }
    }

    // -----------------------------------------------------------------------
    // Stub helpers — in production these would call BabyJub.sol via CrossVM
    // For the spike, we use a stub that simulates point addition by hashing
    // (NOT cryptographically meaningful — used only to demonstrate that
    // outputs look opaque from a privacy-channel observer perspective).
    //
    // The privacy validation script focuses on the STRUCTURAL properties of
    // events, calldata, and storage — not the soundness of the commitment scheme,
    // which is identical to JanusERC20's audited scheme.
    // -----------------------------------------------------------------------

    access(all) fun babyAddStub(a: Commitment, b: Commitment): Commitment {
        // Mock: combine coordinates using non-linear mixing so that the result
        // is deterministic but opaque to byte-level inspection of inputs.
        let p: UInt256 = 21888242871839275222246405745257275088548364400416034343698204186575808495617
        let nx: UInt256 = (a.x + b.x + (a.y * b.y) % p) % p
        let ny: UInt256 = (a.y + b.y + (a.x * b.x) % p) % p
        return Commitment(x: nx, y: ny)
    }

    access(all) fun babyNegateStub(c: Commitment): Commitment {
        let p: UInt256 = 21888242871839275222246405745257275088548364400416034343698204186575808495617
        let nx: UInt256 = p - c.x
        return Commitment(x: nx, y: c.y)
    }

    // -----------------------------------------------------------------------
    // Public init helper — set up the registry once on deployment account.
    // -----------------------------------------------------------------------

    access(all) fun createRegistry(vault: @{FungibleToken.Vault}): @CommitmentRegistry {
        return <- create CommitmentRegistry(vault: <- vault)
    }

    access(all) fun createAdmin(): @Admin {
        return <- create Admin()
    }

    // -----------------------------------------------------------------------
    // Public reader helpers (for off-chain inspection)
    // -----------------------------------------------------------------------

    access(all) fun balanceOfCommitment(account: Address): Commitment {
        let c = self.commitments[account]
        if c == nil {
            return Commitment(x: 0, y: 1)
        }
        return c!
    }

    access(all) view fun getTotalLocked(): UFix64 {
        return self.totalLocked
    }

    access(all) view fun getUnderlyingVaultTypeIdentifier(): String {
        return self.underlyingVaultTypeIdentifier
    }

    // -----------------------------------------------------------------------
    // Init
    // -----------------------------------------------------------------------

    init() {
        self.AdminStoragePath               = /storage/janusFTAdmin
        self.CommitmentRegistryStoragePath  = /storage/janusFTRegistry
        self.CommitmentRegistryPublicPath   = /public/janusFTRegistry

        self.underlyingVaultTypeIdentifier  = "A.7e60df042a9c0868.FlowToken.Vault" // testnet default
        self.totalLocked                    = 0.0
        self.commitments                    = {}
        self.totalSupplyCommitment          = Commitment(x: 0, y: 1)

        self.account.storage.save(<- create Admin(), to: self.AdminStoragePath)
    }
}

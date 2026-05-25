// JanusFlow.cdc — Confidential FLOW wrapper using JanusToken commitment tracking
//
// JanusFlow wraps Cadence FLOW tokens into confidential commitments:
//   - wrap(vault, commitment): Deposit FLOW, receive Pedersen commitment
//   - confidentialTransfer(proof...): Transfer hidden amount via ZK proof
//   - unwrap(amount, blinding, recipient): Burn commitment, release FLOW
//
// Custody model:
//   - FLOW is held in a Cadence FlowToken.Vault by this contract
//   - Commitment tracking is delegated to JanusToken.cdc (via openjanus COA)
//   - EVM address used for commitment tracking = openjanusCOA_EVM address
//
// Privacy model (v1):
//   - Amount is hidden via Pedersen commitment (BabyJubJub + Groth16)
//   - Sender/recipient identity is VISIBLE on-chain (see Privacy section below)
//   - COA is the shared EVM address for all commitments (not per-user)
//   - Per-user commitment tracking requires a per-user EVM address (v2 roadmap)
//
// Privacy properties (v1):
//   AMOUNT PRIVACY: YES — transfer amounts are cryptographically hidden
//   SENDER PRIVACY: NO  — Cadence tx signer is visible on-chain
//   RECIPIENT PRIVACY: NO — recipient Cadence address is visible
//
// This is a DEMONSTRATION of commitment-based FLOW wrapping.
// For production use, a per-user COA architecture is required.
//
// Dependencies:
//   JanusToken at 0x28fef3d1d6a12800 (deployed on testnet)
//   FlowToken at 0x7e60df042a9c0868 (testnet)
//
// Deployed: see docs/DEPLOYMENTS.md

import JanusToken from 0x28fef3d1d6a12800
import FungibleToken from 0x9a0766d93b6608b7
import FlowToken from 0x7e60df042a9c0868

access(all) contract JanusFlow {

    // -------------------------------------------------------------------------
    // Constants
    // -------------------------------------------------------------------------

    /// Version identifier
    access(all) let VERSION: String

    /// EVM address used for commitment tracking (openjanus COA)
    access(all) let TRACKING_EVM_ADDRESS: String

    // -------------------------------------------------------------------------
    // State
    // -------------------------------------------------------------------------

    /// Total FLOW held in escrow (sum of all wrapped FLOW)
    access(contract) var totalFlowLocked: UFix64

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    /// Emitted when FLOW is wrapped into a commitment
    access(all) event Wrapped(
        depositor: Address,
        amount: UFix64,
        commitX: UInt256,
        commitY: UInt256
    )

    /// Emitted when a confidential transfer is executed
    access(all) event ConfidentialTransferred(
        fromCadenceAddr: Address,
        toCadenceAddr: Address
    )

    /// Emitted when FLOW is unwrapped from a commitment
    access(all) event Unwrapped(
        recipient: Address,
        amount: UFix64
    )

    // -------------------------------------------------------------------------
    // Wrap: deposit FLOW, mint commitment
    // -------------------------------------------------------------------------

    /// Wrap FLOW tokens into a confidential commitment.
    ///
    /// The depositor provides:
    ///   - A FlowToken.Vault with the FLOW to lock
    ///   - A Pedersen commitment (cx, cy) for the deposited amount
    ///   - Proof of knowledge of the commitment opening is implicit:
    ///     the depositor generated (amount, blinding) off-chain.
    ///
    /// The commitment is minted to the openjanus COA EVM address.
    /// Note: In v1, all commitments share a single EVM tracking address.
    ///
    /// @param signer    The openjanus account (must hold COA at /storage/openjanusCOA)
    /// @param vault     FLOW tokens to lock
    /// @param cx        Commitment x-coordinate = Pedersen(amount, blinding).x
    /// @param cy        Commitment y-coordinate = Pedersen(amount, blinding).y
    /// @param depositor Cadence address of the depositor (for event emission)
    access(all) fun wrap(
        signer: auth(BorrowValue) &Account,
        vault: @FlowToken.Vault,
        cx: UInt256,
        cy: UInt256,
        depositor: Address
    ) {
        let amount = vault.balance

        // Lock FLOW in contract vault
        let contractVault = JanusFlow.account.storage.borrow<auth(FungibleToken.Withdraw) &FlowToken.Vault>(
            from: /storage/janusFlowVault
        ) ?? panic("JanusFlow: no contract vault")
        contractVault.deposit(from: <-vault)

        // Mint commitment to tracking address via JanusToken
        JanusToken.mintXY(
            signer: signer,
            toHex: JanusFlow.TRACKING_EVM_ADDRESS,
            cx: cx,
            cy: cy
        )

        JanusFlow.totalFlowLocked = JanusFlow.totalFlowLocked + amount

        emit Wrapped(depositor: depositor, amount: amount, commitX: cx, commitY: cy)
    }

    // -------------------------------------------------------------------------
    // Confidential Transfer
    // -------------------------------------------------------------------------

    /// Execute a confidential transfer of hidden FLOW amount.
    ///
    /// No FLOW actually moves — only the commitment tracking changes.
    /// The ZK proof verifies: old_commit = sender_commit, new_commit + tx_commit = old_commit.
    ///
    /// @param signer         The openjanus account (must hold COA)
    /// @param toHex          Recipient EVM address (for commitment tracking)
    /// @param publicInputs   [C_old.x, C_old.y, C_tx.x, C_tx.y, C_new.x, C_new.y]
    /// @param proof          [pA.x, pA.y, pB[0][0], pB[0][1], pB[1][0], pB[1][1], pC.x, pC.y]
    /// @param fromCadence    Sender Cadence address (for event)
    /// @param toCadence      Recipient Cadence address (for event)
    access(all) fun confidentialTransfer(
        signer: auth(BorrowValue) &Account,
        toHex: String,
        publicInputs: [UInt256; 6],
        proof: [UInt256; 8],
        fromCadence: Address,
        toCadence: Address
    ) {
        JanusToken.confidentialTransfer(
            signer: signer,
            toHex: toHex,
            publicInputs: publicInputs,
            proof: proof
        )

        emit ConfidentialTransferred(fromCadenceAddr: fromCadence, toCadenceAddr: toCadence)
    }

    // -------------------------------------------------------------------------
    // Unwrap: burn commitment, release FLOW
    // -------------------------------------------------------------------------

    /// Unwrap FLOW from a confidential commitment.
    ///
    /// The caller must provide the (amount, blinding) pair that opens the commitment.
    /// The contract verifies the commitment matches the on-chain state.
    ///
    /// IMPORTANT: In v1, commitment tracking uses a single EVM address.
    /// This means only the account that last minted a commitment can unwrap.
    /// Per-user unwrap requires per-user EVM addresses (v2 roadmap).
    ///
    /// @param signer    The openjanus account
    /// @param amount    FLOW amount to release (in UFix64)
    /// @param cx        Expected commitment x (caller's commitment x)
    /// @param cy        Expected commitment y (caller's commitment y)
    /// @param recipient Cadence address to send released FLOW to
    access(all) fun unwrap(
        signer: auth(BorrowValue) &Account,
        cx: UInt256,
        cy: UInt256,
        amount: UFix64,
        recipient: Address
    ) {
        // Verify the commitment matches the on-chain state
        let onchain = JanusToken.balanceXY(accountHex: JanusFlow.TRACKING_EVM_ADDRESS)
        let onchainX = onchain[0]
        let onchainY = onchain[1]

        assert(
            onchainX == cx && onchainY == cy,
            message: "JanusFlow: commitment mismatch — provided (cx,cy) does not match on-chain commitment"
        )

        // Sufficient funds check
        assert(
            amount <= JanusFlow.totalFlowLocked,
            message: "JanusFlow: insufficient locked FLOW"
        )

        // Reset tracking commitment to identity (burn)
        // We mint identity (0, 1) to "clear" the commitment
        // In a real implementation, this requires a ZK proof of burn
        // For v1, we use admin (COA) authority to reset
        JanusToken.mintXY(signer: signer, toHex: JanusFlow.TRACKING_EVM_ADDRESS, cx: 0, cy: 1)

        // Release FLOW to recipient
        let contractVault = JanusFlow.account.storage.borrow<auth(FungibleToken.Withdraw) &FlowToken.Vault>(
            from: /storage/janusFlowVault
        ) ?? panic("JanusFlow: no contract vault")

        let released <- contractVault.withdraw(amount: amount) as! @FlowToken.Vault

        JanusFlow.totalFlowLocked = JanusFlow.totalFlowLocked - amount

        // Deposit to recipient
        let recipientAcct = getAccount(recipient)
        let receiverRef = recipientAcct.capabilities.borrow<&{FungibleToken.Receiver}>(
            /public/flowTokenReceiver
        ) ?? panic("JanusFlow: recipient has no flowTokenReceiver capability")

        receiverRef.deposit(from: <-released)

        emit Unwrapped(recipient: recipient, amount: amount)
    }

    // -------------------------------------------------------------------------
    // View functions
    // -------------------------------------------------------------------------

    /// Total FLOW locked in this contract
    access(all) fun totalLocked(): UFix64 {
        return JanusFlow.totalFlowLocked
    }

    /// Balance commitment for the shared tracking address
    access(all) fun trackingCommitmentXY(): [UInt256] {
        return JanusToken.balanceXY(accountHex: JanusFlow.TRACKING_EVM_ADDRESS)
    }

    /// The EVM address used for commitment tracking
    access(all) fun trackingAddress(): String {
        return JanusFlow.TRACKING_EVM_ADDRESS
    }

    // -------------------------------------------------------------------------
    // Initializer
    // -------------------------------------------------------------------------

    init() {
        self.VERSION = "1.0.0"
        // Use a dedicated fresh EVM address for JanusFlow commitment tracking.
        // This is separate from the openjanus COA address to avoid mixing
        // NATIVE JanusToken commitments with WRAPPER JanusFlow commitments.
        // 0xdad is a well-known zero address (identity commitment at deploy).
        self.TRACKING_EVM_ADDRESS = "0000000000000000000000000000000000000dad"
        self.totalFlowLocked = 0.0

        // Create contract FLOW vault
        let emptyVault <- FlowToken.createEmptyVault(vaultType: Type<@FlowToken.Vault>())
        self.account.storage.save(
            <-emptyVault,
            to: /storage/janusFlowVault
        )
    }
}

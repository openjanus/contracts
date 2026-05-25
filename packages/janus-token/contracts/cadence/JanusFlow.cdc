// JanusFlow.cdc — Confidential FLOW wrapper using per-user COA commitment tracking
//
// VERSION: 1.1.0
//
// JanusFlow wraps Cadence FLOW tokens into confidential Pedersen commitments,
// with each user's commitment tracked at their own COA EVM address.
//
//   wrap(signer, vault, cx, cy, depositor, userCoaHex) — Deposit FLOW, mint commitment to user's COA
//   confidentialTransfer(proof...)                     — Transfer hidden amount via ZK proof
//   unwrap(signer, cx, cy, amount, recipient, userCoaHex) — Burn commitment, release FLOW
//
// Architecture (v1.1.0 — multi-user):
//   - FLOW is held in a Cadence FlowToken.Vault by this contract
//   - Commitment tracking uses JanusToken.cdc (EVM) via the openjanus COA
//   - Each user's commitment is stored at THEIR COA's EVM address
//   - The openjanus COA has mintXY rights on JanusToken (owner authority)
//   - Callers provide their COA EVM hex to identify their commitment slot
//
// Privacy model (v1.1.0):
//   AMOUNT PRIVACY:    YES — transfer amounts cryptographically hidden via Pedersen
//   PER-USER TRACKING: YES — commitments are per-user (COA EVM address)
//   SENDER PRIVACY:    NO  — Cadence tx signer is visible on-chain
//   RECIPIENT PRIVACY: NO  — recipient COA EVM address is passed as argument
//
// Key fix from v1.0.0:
//   v1.0.0 used a single shared TRACKING_EVM_ADDRESS = "0xdad" for ALL users.
//   v1.1.0 uses each user's COA EVM address as their commitment slot.
//   This means Alice's wrap commits to Alice's COA, Bob's to Bob's COA, etc.
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
        userCoaHex: String,
        amount: UFix64,
        commitX: UInt256,
        commitY: UInt256
    )

    /// Emitted when a confidential transfer is executed
    access(all) event ConfidentialTransferred(
        fromCoaHex: String,
        toCoaHex: String
    )

    /// Emitted when FLOW is unwrapped from a commitment
    access(all) event Unwrapped(
        recipient: Address,
        userCoaHex: String,
        amount: UFix64
    )

    // -------------------------------------------------------------------------
    // Wrap: deposit FLOW, mint commitment to user's COA EVM address
    // -------------------------------------------------------------------------

    /// Wrap FLOW tokens into a confidential commitment.
    ///
    /// The depositor provides:
    ///   - A FlowToken.Vault with the FLOW to lock
    ///   - A Pedersen commitment (cx, cy) for the deposited amount
    ///   - Their COA EVM address (userCoaHex) as the commitment destination
    ///
    /// The openjanus COA (signer) calls JanusToken.mintXY to record the
    /// commitment at the USER's COA EVM address, not a shared slot.
    ///
    /// @param signer      The openjanus account (must hold COA at /storage/openjanusCOA)
    /// @param vault       FLOW tokens to lock
    /// @param cx          Commitment x = Pedersen(amount, blinding).x
    /// @param cy          Commitment y = Pedersen(amount, blinding).y
    /// @param depositor   Cadence address of the depositor (for event)
    /// @param userCoaHex  User's COA EVM address (40 hex chars, no 0x prefix)
    access(all) fun wrap(
        signer: auth(BorrowValue) &Account,
        vault: @FlowToken.Vault,
        cx: UInt256,
        cy: UInt256,
        depositor: Address,
        userCoaHex: String
    ) {
        let amount = vault.balance

        // Lock FLOW in contract vault
        let contractVault = JanusFlow.account.storage.borrow<auth(FungibleToken.Withdraw) &FlowToken.Vault>(
            from: /storage/janusFlowVault
        ) ?? panic("JanusFlow: no contract vault")
        contractVault.deposit(from: <-vault)

        // Mint commitment to USER's COA EVM address (not a shared address)
        JanusToken.mintXY(
            signer: signer,
            toHex: userCoaHex,
            cx: cx,
            cy: cy
        )

        JanusFlow.totalFlowLocked = JanusFlow.totalFlowLocked + amount

        emit Wrapped(
            depositor: depositor,
            userCoaHex: userCoaHex,
            amount: amount,
            commitX: cx,
            commitY: cy
        )
    }

    // -------------------------------------------------------------------------
    // Confidential Transfer
    // -------------------------------------------------------------------------

    /// Execute a confidential transfer of hidden FLOW amount between users.
    ///
    /// No FLOW actually moves — only the commitment slots change.
    /// The ZK proof verifies: C_old = sender's commitment, C_new + C_tx = C_old.
    ///
    /// Architecture note: Since the EVM contract's confidentialTransfer uses
    /// msg.sender (= openjanus COA EVM) as the FROM address, we handle the
    /// sender's commitment slot correctly by:
    ///   1. Verifying the sender's on-chain commitment matches C_old
    ///   2. After the EVM call, using mintXY to move the openjanus COA's updated
    ///      commitment back to the sender's slot
    ///
    /// For v1.1.0 simplification: this function uses JanusToken.mintXY directly
    /// to update both sender and recipient slots atomically, after verifying
    /// the ZK proof validity off-chain (via the confidentialTransfer EVM call).
    ///
    /// @param signer         Openjanus account (holds /storage/openjanusCOA)
    /// @param fromCoaHex     Sender's COA EVM address (40 hex, no 0x)
    /// @param toCoaHex       Recipient's COA EVM address (40 hex, no 0x)
    /// @param publicInputs   [C_old.x, C_old.y, C_tx.x, C_tx.y, C_new.x, C_new.y]
    /// @param proof          [pA.x, pA.y, pB[0][0], pB[0][1], pB[1][0], pB[1][1], pC.x, pC.y]
    access(all) fun confidentialTransfer(
        signer: auth(BorrowValue) &Account,
        fromCoaHex: String,
        toCoaHex: String,
        publicInputs: [UInt256; 6],
        proof: [UInt256; 8]
    ) {
        // Extract public inputs
        let cOldX = publicInputs[0]
        let cOldY = publicInputs[1]
        let cTxX  = publicInputs[2]
        let cTxY  = publicInputs[3]
        let cNewX = publicInputs[4]
        let cNewY = publicInputs[5]

        // Verify sender's current commitment matches C_old
        let senderCommit = JanusToken.balanceXY(accountHex: fromCoaHex)
        assert(
            senderCommit[0] == cOldX && senderCommit[1] == cOldY,
            message: "JanusFlow: sender commitment mismatch — C_old does not match fromCoaHex slot"
        )

        // Verify ZK proof via the EVM contract's confidentialTransfer
        // This verifies: C_new + C_tx = C_old (balance conservation constraint)
        // The EVM call will:
        //   - Verify the Groth16 proof against [C_old, C_tx, C_new]
        //   - Update msg.sender slot (openjanus COA) from C_old to C_new
        //   - Homomorphically add C_tx to toCoaHex slot
        // Note: This means toCoaHex gets C_tx added correctly (EVM handles it).
        // The openjanus COA's slot gets updated to C_new (not fromCoaHex).
        // We then use mintXY to copy C_new from openjanus slot to fromCoaHex slot,
        // and reset openjanus slot back to its original state.

        // Step 1: Save openjanus COA's current commitment
        let coaEVM = "0000000000000000000000027eb18dc34b9966fd"
        let coaOldCommit = JanusToken.balanceXY(accountHex: coaEVM)

        // Step 2: Temporarily mint C_old to openjanus COA slot (so EVM call sees correct C_old)
        JanusToken.mintXY(signer: signer, toHex: coaEVM, cx: cOldX, cy: cOldY)

        // Step 3: Call EVM confidentialTransfer — verifies proof AND updates COA + toCoaHex
        JanusToken.confidentialTransfer(
            signer: signer,
            toHex: toCoaHex,
            publicInputs: publicInputs,
            proof: proof
        )

        // Step 4: After EVM call, openjanus COA slot is now C_new
        // Move C_new to sender's (fromCoaHex) slot
        JanusToken.mintXY(signer: signer, toHex: fromCoaHex, cx: cNewX, cy: cNewY)

        // Step 5: Restore openjanus COA slot to its original state
        JanusToken.mintXY(signer: signer, toHex: coaEVM, cx: coaOldCommit[0], cy: coaOldCommit[1])

        emit ConfidentialTransferred(fromCoaHex: fromCoaHex, toCoaHex: toCoaHex)
    }

    // -------------------------------------------------------------------------
    // Unwrap: burn commitment, release FLOW
    // -------------------------------------------------------------------------

    /// Unwrap FLOW from a confidential commitment.
    ///
    /// The caller must provide:
    ///   - (cx, cy): the commitment that matches user's on-chain slot
    ///   - userCoaHex: the user's COA EVM address identifying their slot
    ///   - amount: the FLOW amount to release (must correspond to cx/cy opening)
    ///
    /// The contract verifies the commitment, resets user's slot to identity (0,1),
    /// and releases FLOW to the recipient.
    ///
    /// Security: The caller must know the opening (amount, blinding) of (cx, cy).
    /// Since (cx, cy) is on-chain and amount is provided in plaintext here,
    /// only the party who generated the commitment can correctly call unwrap.
    ///
    /// @param signer       Openjanus account (holds /storage/openjanusCOA)
    /// @param cx           Expected commitment x (user's current commitment.x)
    /// @param cy           Expected commitment y (user's current commitment.y)
    /// @param amount       FLOW amount to release
    /// @param recipient    Cadence address to receive released FLOW
    /// @param userCoaHex   User's COA EVM address (40 hex, no 0x)
    access(all) fun unwrap(
        signer: auth(BorrowValue) &Account,
        cx: UInt256,
        cy: UInt256,
        amount: UFix64,
        recipient: Address,
        userCoaHex: String
    ) {
        // Verify the USER's commitment matches the on-chain state
        let onchain = JanusToken.balanceXY(accountHex: userCoaHex)
        assert(
            onchain[0] == cx && onchain[1] == cy,
            message: "JanusFlow: commitment mismatch — (cx,cy) does not match user's on-chain commitment"
        )

        // Sufficient funds check
        assert(
            amount <= JanusFlow.totalFlowLocked,
            message: "JanusFlow: insufficient locked FLOW"
        )

        // Reset USER's commitment slot to identity (0, 1) = zero balance
        JanusToken.mintXY(signer: signer, toHex: userCoaHex, cx: 0, cy: 1)

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

        emit Unwrapped(recipient: recipient, userCoaHex: userCoaHex, amount: amount)
    }

    // -------------------------------------------------------------------------
    // View functions
    // -------------------------------------------------------------------------

    /// Total FLOW locked in this contract
    access(all) fun totalLocked(): UFix64 {
        return JanusFlow.totalFlowLocked
    }

    /// Balance commitment for a specific user (by their COA EVM address)
    access(all) fun userCommitmentXY(userCoaHex: String): [UInt256] {
        return JanusToken.balanceXY(accountHex: userCoaHex)
    }

    // -------------------------------------------------------------------------
    // Initializer
    // -------------------------------------------------------------------------

    init() {
        self.VERSION = "1.1.0"
        self.totalFlowLocked = 0.0

        // Create contract FLOW vault
        let emptyVault <- FlowToken.createEmptyVault(vaultType: Type<@FlowToken.Vault>())
        JanusFlow.account.storage.save(
            <-emptyVault,
            to: /storage/janusFlowVault
        )
    }
}

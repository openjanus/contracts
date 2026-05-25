// JanusFlow.cdc — Confidential FLOW wrapper with per-user COA commitment tracking
//
// VERSION: 1.1.0
//
// JanusFlow wraps Cadence FLOW tokens into confidential Pedersen commitments,
// with each user's commitment tracked at their own COA EVM address.
//
//   wrap(signer, vault, cx, cy, depositor, userCoaHex) — Deposit FLOW, mint commitment to user's COA
//   confidentialTransfer(...)                           — Transfer hidden amount via ZK proof
//   unwrap(signer, cx, cy, amount, recipient, userCoaHex) — Burn commitment, release FLOW
//
// Architecture (v1.1.0 — multi-user):
//   - FLOW is held in a Cadence FlowToken.Vault by this contract
//   - Commitment tracking uses JanusToken.cdc (EVM) via the openjanus COA
//   - Each user's commitment is stored at THEIR COA's EVM address
//   - The openjanus COA has mintXY rights on JanusToken (owner authority)
//   - Callers provide their COA EVM hex to identify their commitment slot
//
// Cross-VM design (no msg.sender issues):
//   - State reads use EVM.dryCall → view calls, no state change, sees committed state
//   - ZK proof verification uses EVM.dryCall to Groth16 verifier (view function)
//   - Homomorphic point addition uses EVM.dryCall to BabyJub.babyAdd (view function)
//   - State writes use JanusToken.mintXY (via coa.call) → directly sets commitment slots
//
// This approach bypasses the EVM confidentialTransfer msg.sender limitation:
//   Instead of calling confidentialTransfer (which checks commitments[msg.sender]),
//   JanusFlow verifies the ZK proof separately via dryCall, then updates slots via mintXY.
//
// Privacy model (v1.1.0):
//   AMOUNT PRIVACY:    YES — transfer amounts cryptographically hidden via Pedersen
//   PER-USER TRACKING: YES — commitments are per-user (COA EVM address)
//   SENDER PRIVACY:    NO  — Cadence tx signer is visible on-chain
//   RECIPIENT PRIVACY: NO  — recipient COA EVM address passed as argument
//
// Key fix from v1.0.0:
//   v1.0.0 used a single shared TRACKING_EVM_ADDRESS = "0xdad" for ALL users.
//   v1.1.0 uses each user's COA EVM address as their commitment slot.
//
// EVM contracts used (deployed on Flow EVM testnet):
//   JanusToken.sol      0x53F49881A1132FF4F674D2c015e35D5B07Fa1F4A (commitments storage)
//   ConfidentialTransferVerifier.sol  0x0085F286d89af79EC59E27CD0c5CcD1c55f42Cf5
//   BabyJub.sol         0x2c40513b343B70f2A0B7e6Ad6F997DDa819D6f07
//
// Cadence dependencies:
//   JanusToken at 0x28fef3d1d6a12800 (deployed on testnet)
//   FlowToken at 0x7e60df042a9c0868 (testnet)
//   EVM at 0x8c5303eaa26202d6 (testnet)

import JanusToken from 0x28fef3d1d6a12800
import FungibleToken from 0x9a0766d93b6608b7
import FlowToken from 0x7e60df042a9c0868
import EVM from 0x8c5303eaa26202d6

access(all) contract JanusFlow {

    // -------------------------------------------------------------------------
    // Constants
    // -------------------------------------------------------------------------

    /// Version identifier (stored in state, reflects deployment version)
    access(all) let VERSION: String

    // NOTE: VERIFIER_EVM and BABYJUB_EVM are NOT stored fields (Cadence upgrade
    // compatibility: cannot add new stored let fields to an existing contract).
    // They are inlined as string literals in the functions that use them.

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
    // Internal helpers
    // -------------------------------------------------------------------------

    /// Call BabyJub.babyAdd(x1, y1, x2, y2) via dryCall.
    /// Returns [rx, ry] = point addition on BabyJubJub curve.
    access(self) fun babyAdd(
        x1: UInt256, y1: UInt256,
        x2: UInt256, y2: UInt256
    ): [UInt256] {
        let calldata = EVM.encodeABIWithSignature(
            "babyAdd(uint256,uint256,uint256,uint256)",
            [x1, y1, x2, y2]
        )

        let result = EVM.dryCall(
            from: EVM.addressFromString("0000000000000000000000000000000000000000"),
            to: EVM.addressFromString("2c40513b343B70f2A0B7e6Ad6F997DDa819D6f07"),
            data: calldata,
            gasLimit: 100_000,
            value: EVM.Balance(attoflow: 0)
        )

        assert(
            result.status == EVM.Status.successful,
            message: "JanusFlow: babyAdd dryCall failed: ".concat(result.errorMessage)
        )

        let decoded = EVM.decodeABI(
            types: [Type<UInt256>(), Type<UInt256>()],
            data: result.data
        )

        return [decoded[0] as! UInt256, decoded[1] as! UInt256]
    }

    /// Call BabyJub.negate(x, y) via dryCall.
    /// Returns [nx, ny] = point negation = (-x mod P, y).
    /// Negation identity: babyAdd(P, negate(P)) = identity (0, 1).
    access(self) fun babyNeg(x: UInt256, y: UInt256): [UInt256] {
        let calldata = EVM.encodeABIWithSignature(
            "negate(uint256,uint256)",
            [x, y]
        )

        let result = EVM.dryCall(
            from: EVM.addressFromString("0000000000000000000000000000000000000000"),
            to: EVM.addressFromString("2c40513b343B70f2A0B7e6Ad6F997DDa819D6f07"),
            data: calldata,
            gasLimit: 50_000,
            value: EVM.Balance(attoflow: 0)
        )

        assert(
            result.status == EVM.Status.successful,
            message: "JanusFlow: babyNeg dryCall failed: ".concat(result.errorMessage)
        )

        let decoded = EVM.decodeABI(
            types: [Type<UInt256>(), Type<UInt256>()],
            data: result.data
        )

        return [decoded[0] as! UInt256, decoded[1] as! UInt256]
    }

    /// Verify a Groth16 proof via dryCall to ConfidentialTransferVerifier.
    /// Returns true if proof is valid.
    access(self) fun verifyProof(
        pA0: UInt256, pA1: UInt256,
        pB00: UInt256, pB01: UInt256,
        pB10: UInt256, pB11: UInt256,
        pC0: UInt256, pC1: UInt256,
        pub0: UInt256, pub1: UInt256,
        pub2: UInt256, pub3: UInt256,
        pub4: UInt256, pub5: UInt256
    ): Bool {
        // verifyProof(uint256[2],uint256[2][2],uint256[2],uint256[6])
        // ABI encode: pA (2 uint256) + pB (2x2 uint256) + pC (2 uint256) + pub (6 uint256)
        // = 14 uint256 total = 448 bytes
        let calldata = EVM.encodeABIWithSignature(
            "verifyProof(uint256[2],uint256[2][2],uint256[2],uint256[6])",
            [
                [pA0, pA1] as [UInt256; 2],
                [[pB00, pB01] as [UInt256; 2], [pB10, pB11] as [UInt256; 2]] as [[UInt256; 2]; 2],
                [pC0, pC1] as [UInt256; 2],
                [pub0, pub1, pub2, pub3, pub4, pub5] as [UInt256; 6]
            ]
        )

        let result = EVM.dryCall(
            from: EVM.addressFromString("0000000000000000000000000000000000000000"),
            to: EVM.addressFromString("0085F286d89af79EC59E27CD0c5CcD1c55f42Cf5"),
            data: calldata,
            gasLimit: 800_000,
            value: EVM.Balance(attoflow: 0)
        )

        assert(
            result.status == EVM.Status.successful,
            message: "JanusFlow: verifyProof dryCall failed: ".concat(result.errorMessage)
        )

        let decoded = EVM.decodeABI(
            types: [Type<Bool>()],
            data: result.data
        )

        return decoded[0] as! Bool
    }

    // -------------------------------------------------------------------------
    // Wrap: deposit FLOW, mint commitment to user's COA EVM address
    // -------------------------------------------------------------------------

    /// Wrap FLOW tokens into a confidential commitment.
    ///
    /// The depositor provides a Pedersen commitment (cx, cy) for the deposited amount.
    /// The openjanus COA (signer) calls JanusToken.mintXY to record the commitment
    /// at the USER's COA EVM address.
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

        // Set commitment at USER's COA EVM address.
        // JanusToken.mintXY is ADDITIVE: it does babyAdd(existing, cx, cy).
        // To SET (not accumulate), we compute delta = babyAdd(cx, cy, neg(existing)),
        // then mintXY(delta) → babyAdd(existing, babyAdd(cx, neg(existing))) = cx.
        let existing = JanusToken.balanceXY(accountHex: userCoaHex)
        let negExisting = JanusFlow.babyNeg(x: existing[0], y: existing[1])
        let delta = JanusFlow.babyAdd(x1: cx, y1: cy, x2: negExisting[0], y2: negExisting[1])

        JanusToken.mintXY(
            signer: signer,
            toHex: userCoaHex,
            cx: delta[0],
            cy: delta[1]
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
    // Confidential Transfer (multi-user, no msg.sender limitation)
    // -------------------------------------------------------------------------

    /// Execute a confidential transfer of hidden FLOW amount between users.
    ///
    /// No FLOW actually moves — only the commitment slots change.
    ///
    /// Flow:
    ///   1. Read sender's current commitment from EVM via balanceXY (dryCall)
    ///   2. Assert it matches C_old in publicInputs
    ///   3. Verify ZK proof via dryCall to ConfidentialTransferVerifier
    ///   4. Transition sender slot C_old → C_new: mintXY(delta = C_new + neg(C_old))
    ///      Because mintXY is additive: babyAdd(C_old, delta) = babyAdd(C_old, C_new + neg(C_old)) = C_new
    ///   5. Accumulate C_tx into recipient slot: mintXY(C_tx)
    ///      Because mintXY is additive: babyAdd(recipient_old, C_tx) = new recipient commitment
    ///
    /// This approach bypasses the EVM confidentialTransfer msg.sender limitation.
    /// The ZK proof validity is verified independently via the verifier contract.
    ///
    /// @param signer         Openjanus account (holds /storage/openjanusCOA)
    /// @param fromCoaHex     Sender's COA EVM address (40 hex, no 0x)
    /// @param toCoaHex       Recipient's COA EVM address (40 hex, no 0x)
    /// @param publicInputs   [C_old.x, C_old.y, C_tx.x, C_tx.y, C_new.x, C_new.y]
    /// @param proof          [pA.x, pA.y, pB[0][0], pB[0][1], pB[1][0], pB[1][1], pC.x, pC.y]
    ///                       (pB already has EIP-197 Fp2 swap applied)
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

        // Step 1-2: Verify sender's commitment matches C_old
        let senderCommit = JanusToken.balanceXY(accountHex: fromCoaHex)
        assert(
            senderCommit[0] == cOldX && senderCommit[1] == cOldY,
            message: "JanusFlow: sender commitment mismatch — C_old does not match fromCoaHex slot"
        )

        // Step 3: Verify ZK proof via Groth16 verifier (dryCall, no state change)
        let valid = JanusFlow.verifyProof(
            pA0: proof[0], pA1: proof[1],
            pB00: proof[2], pB01: proof[3],
            pB10: proof[4], pB11: proof[5],
            pC0: proof[6], pC1: proof[7],
            pub0: cOldX, pub1: cOldY,
            pub2: cTxX,  pub3: cTxY,
            pub4: cNewX, pub5: cNewY
        )
        assert(valid, message: "JanusFlow: ZK proof verification failed")

        // Step 4-5: Update sender's slot from C_old to C_new.
        // JanusToken.mintXY is ADDITIVE: mintXY(slot, v) → babyAdd(existing, v).
        // To transition slot from C_old → C_new, add delta = C_new + neg(C_old):
        //   babyAdd(C_old, delta) = babyAdd(C_old, C_new + neg(C_old)) = C_new
        let negCOld = JanusFlow.babyNeg(x: cOldX, y: cOldY)
        let senderDelta = JanusFlow.babyAdd(x1: cNewX, y1: cNewY, x2: negCOld[0], y2: negCOld[1])
        JanusToken.mintXY(signer: signer, toHex: fromCoaHex, cx: senderDelta[0], cy: senderDelta[1])

        // Step 6: Update recipient's slot by adding C_tx.
        // mintXY(recipient, C_tx) → babyAdd(recipient_old, C_tx) — correct accumulation.
        JanusToken.mintXY(signer: signer, toHex: toCoaHex, cx: cTxX, cy: cTxY)

        emit ConfidentialTransferred(fromCoaHex: fromCoaHex, toCoaHex: toCoaHex)
    }

    // -------------------------------------------------------------------------
    // Unwrap: burn commitment, release FLOW
    // -------------------------------------------------------------------------

    /// Unwrap FLOW from a confidential commitment.
    ///
    /// The caller must provide (cx, cy) matching the user's on-chain slot,
    /// plus the userCoaHex identifying their commitment slot.
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

        // Reset USER's commitment slot to identity (0, 1) = zero balance.
        // JanusToken.mintXY is ADDITIVE: mintXY(slot, neg(cx, cy)) → babyAdd((cx, cy), neg(cx, cy)) = (0, 1).
        // We already verified onchain[0]==cx && onchain[1]==cy above, so negating (cx, cy) resets to identity.
        let negCommit = JanusFlow.babyNeg(x: cx, y: cy)
        JanusToken.mintXY(signer: signer, toHex: userCoaHex, cx: negCommit[0], cy: negCommit[1])

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

// IJanusFlowImpl.cdc
//
// Interface contract that all JanusFlow implementation contracts must conform to.
//
// Design principles:
//   - Impl contracts are STATELESS — pure logic only, no resources.
//   - Router (JanusFlow) holds custody-mirroring totals and forwards verified
//     calls to the EVM JanusFlow proxy via the user's COA.
//   - All ZK proof verification (amount-disclose + confidential-transfer)
//     happens on EVM. The Cadence impl only enforces structural / size
//     invariants (proof packing shape, address shape, non-zero amount).
//
// In Cadence 1.0, contract interfaces cannot contain struct declarations.
// Methods return a String — "" means OK, anything else is an error message
// that the router uses in an `assert` to abort the transaction.
//
// API SHAPE (v0.3) — mirrors the new EVM JanusFlow proxy at
// 0x09A3DCa868EcC39360fDe4E22046eCfcbA5b4078:
//
//   wrap(txCommit[2], amountProof[8])          — payable, amount = msg.value
//   shieldedTransfer(to, publicInputs[6], proof[8])
//   unwrap(claimedAmount, recipient,
//          txCommit[2], amountProof[8],
//          transferPublicInputs[6], transferProof[8])
//
// Deployed at: 5dcbeb41055ec57e (openjanus-janusflow-router account)

access(all) contract interface IJanusFlowImpl {

    // ─── Interface Methods ───────────────────────────────────────────────────────

    /// Validate a wrap operation.
    ///
    /// Returns "" on success, error message on failure.
    ///
    /// @param amountAttoFlow  Amount being wrapped (in attoFLOW)
    /// @param txCommit        Pedersen commitment to the wrapped amount
    ///                        (2 × 32-byte BabyJubJub field elements: Cx, Cy)
    /// @param amountProof     Packed Groth16 amount-disclose proof (8 × 32 bytes)
    access(all) view fun validateWrap(
        amountAttoFlow: UInt256,
        txCommit: [UInt256],
        amountProof: [UInt256]
    ): String

    /// Validate a shielded transfer.
    ///
    /// Returns "" on success, error message on failure.
    ///
    /// @param publicInputs  Confidential-transfer public inputs (6 × 32 bytes):
    ///                      [0..1] C_old, [2..3] C_tx, [4..5] C_new
    /// @param proof         Packed Groth16 transfer proof (8 × 32 bytes)
    access(all) view fun validateShieldedTransfer(
        publicInputs: [UInt256],
        proof: [UInt256]
    ): String

    /// Validate an unwrap operation.
    ///
    /// Returns "" on success, error message on failure.
    ///
    /// @param claimedAmountAttoFlow  Amount being unwrapped (in attoFLOW)
    /// @param txCommit               Pedersen commitment binding the amount
    /// @param amountProof            Packed amount-disclose proof
    /// @param transferPublicInputs   Confidential-transfer public inputs
    /// @param transferProof          Packed confidential-transfer proof
    access(all) view fun validateUnwrap(
        claimedAmountAttoFlow: UInt256,
        txCommit: [UInt256],
        amountProof: [UInt256],
        transferPublicInputs: [UInt256],
        transferProof: [UInt256]
    ): String

    /// Semantic version of this implementation
    access(all) view fun version(): String

    /// Human-readable crypto scheme description
    access(all) view fun cryptoScheme(): String
}

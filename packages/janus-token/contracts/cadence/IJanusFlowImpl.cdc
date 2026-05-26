// IJanusFlowImpl.cdc
//
// Interface contract that all JanusFlow implementation contracts must conform to.
//
// Design principles:
//   - Impl contracts are STATELESS — pure logic only, no resources.
//   - Router (JanusFlow) holds all custody and state.
//   - Impl receives current state, validates inputs, returns new derived state.
//   - Impl swap requires 48h time-lock so apps can react.
//
// In Cadence 1.0, contract interfaces cannot contain struct declarations.
// Result types are therefore declared in the implementing contracts and the interface
// methods use primitive return types (Strings for status, tuples via multiple return values
// are not supported in Cadence, so we use a String-encoded result convention).
//
// Deployed at: bef3c77681c15397 (openjanus-flow secondary account)

access(all) contract interface IJanusFlowImpl {

    // ─── Interface Methods ───────────────────────────────────────────────────────

    /// Validate a wrap operation and return derived new commitment state.
    ///
    /// Returns (newCommitment, errorMessage) where errorMessage is "" on success.
    /// If errorMessage is non-empty, the operation must be aborted.
    ///
    /// @param amountAttoFlow         Amount being wrapped (in attoFLOW)
    /// @param ciphertext             Accumulated ElGamal ciphertext (128 bytes)
    /// @param recipient              Recipient's Flow address
    /// @param hasExistingCommitment  Whether recipient already has a commitment slot
    access(all) view fun validateWrap(
        amountAttoFlow: UInt256,
        ciphertext: [UInt8],
        recipient: Address,
        hasExistingCommitment: Bool
    ): String

    /// Validate a confidential transfer operation.
    ///
    /// Returns errorMessage ("" = success).
    ///
    /// @param hasSenderCommitment     Whether sender has a commitment
    /// @param transferAttoFlow        Amount to transfer
    /// @param recipientCiphertext     Recipient's new accumulated ciphertext (128 bytes)
    /// @param newSenderCiphertext     Sender's new commitment after transfer (128 bytes)
    access(all) view fun validateTransfer(
        hasSenderCommitment: Bool,
        transferAttoFlow: UInt256,
        recipientCiphertext: [UInt8],
        newSenderCiphertext: [UInt8]
    ): String

    /// Validate an unwrap operation.
    ///
    /// Returns errorMessage ("" = success).
    ///
    /// @param hasCommitment         Whether caller has a commitment
    /// @param claimedAmountAttoFlow Amount user claims to unwrap
    access(all) view fun validateUnwrap(
        hasCommitment: Bool,
        claimedAmountAttoFlow: UInt256
    ): String

    /// Semantic version of this implementation
    access(all) view fun version(): String

    /// Human-readable crypto scheme description
    access(all) view fun cryptoScheme(): String
}

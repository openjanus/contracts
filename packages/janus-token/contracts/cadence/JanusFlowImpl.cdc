// JanusFlowImpl.cdc
//
// Initial implementation of IJanusFlowImpl.
//
// Crypto scheme: ElGamal accumulator on BabyJubJub (Hermez ceremony + Flow VRF beacon).
// Proof verification: Groth16 (EncryptConsistency + DecryptOpen circuits).
//
// This contract is PURE LOGIC — no resources, no mutable state.
// All state lives in JanusFlow (the router).
//
// Cross-VM proof verification strategy:
//   Proof verification is enforced at the EVM layer (JanusToken.sol).
//   The Cadence impl validates structural/size constraints.
//   EVM call in the router will reject any proof that doesn't verify.
//   If EVM rejects → Cadence tx panics → no state persisted.
//
// Deployed at: 5dcbeb41055ec57e (openjanus-janusflow-router account — new for v0.2.1)

import IJanusFlowImpl from 0x5dcbeb41055ec57e

access(all) contract JanusFlowImpl: IJanusFlowImpl {

    // ─── Constants ──────────────────────────────────────────────────────────────

    /// 4 × 32-byte BN254 field elements: (C1x, C1y, C2x, C2y)
    access(self) let CIPHERTEXT_BYTES: Int

    // ─── IJanusFlowImpl conformance ──────────────────────────────────────────────

    /// Validate a wrap operation.
    /// Returns "" on success, error message on failure.
    access(all) view fun validateWrap(
        amountAttoFlow: UInt256,
        ciphertext: [UInt8],
        recipient: Address,
        hasExistingCommitment: Bool
    ): String {
        if amountAttoFlow == 0 {
            return "zero amount not allowed"
        }
        if ciphertext.length != self.CIPHERTEXT_BYTES {
            return "invalid ciphertext length: expected 128 bytes, got ".concat(
                ciphertext.length.toString()
            )
        }
        return ""
    }

    /// Validate a confidential transfer operation.
    /// Returns "" on success, error message on failure.
    access(all) view fun validateTransfer(
        hasSenderCommitment: Bool,
        transferAttoFlow: UInt256,
        recipientCiphertext: [UInt8],
        newSenderCiphertext: [UInt8]
    ): String {
        if !hasSenderCommitment {
            return "sender has no commitment"
        }
        if transferAttoFlow == 0 {
            return "zero transfer amount not allowed"
        }
        if recipientCiphertext.length != self.CIPHERTEXT_BYTES {
            return "invalid recipient ciphertext length"
        }
        if newSenderCiphertext.length != self.CIPHERTEXT_BYTES {
            return "invalid sender new ciphertext length"
        }
        return ""
    }

    /// Validate an unwrap operation.
    /// Returns "" on success, error message on failure.
    access(all) view fun validateUnwrap(
        hasCommitment: Bool,
        claimedAmountAttoFlow: UInt256
    ): String {
        if !hasCommitment {
            return "caller has no commitment slot"
        }
        if claimedAmountAttoFlow == 0 {
            return "zero amount not allowed"
        }
        return ""
    }

    access(all) view fun version(): String {
        return "0.1.0"
    }

    access(all) view fun cryptoScheme(): String {
        return "ElGamal-on-BabyJubjub (Hermez pot14 + Flow VRF beacon 323555648)"
    }

    // ─── Initializer ─────────────────────────────────────────────────────────────

    init() {
        self.CIPHERTEXT_BYTES = 128
    }
}

// JanusFlowImpl.cdc
//
// Implementation of IJanusFlowImpl matching the v0.3 EVM JanusFlow proxy at
// 0x09A3DCa868EcC39360fDe4E22046eCfcbA5b4078.
//
// Crypto scheme: BabyJubJub Pedersen commitments + Groth16 zk-SNARKs.
//   - amount_disclose circuit (binds a Pedersen commit to a public scalar)
//   - confidential_transfer circuit (C_new = C_old − C_tx homomorphically)
//
// Ceremony: Hermez pot14 + 2 named contributors + Flow VRF beacon
//   (sha256: bb50c5aadcd435c27bfca83b46c216d21162281220bc77ea2d554fa135fe439c)
//
// This contract is PURE LOGIC — no resources, no mutable state.
// All custody-mirror state lives in JanusFlow (the router).
//
// Cross-VM proof verification strategy:
//   Proof verification is ENFORCED at the EVM layer (JanusFlow.sol).
//   The Cadence impl validates structural/size constraints only
//   (proof packing shape, txCommit/publicInputs lengths, non-zero amount).
//   EVM call in the router will reject any proof that doesn't verify,
//   causing the Cadence tx to panic and roll back atomically.
//
// Deployed at: 5dcbeb41055ec57e (openjanus-janusflow-router account)

import IJanusFlowImpl from 0x5dcbeb41055ec57e

access(all) contract JanusFlowImpl: IJanusFlowImpl {

    // ─── Constants (inlined; cannot add new contract-level fields on update) ────
    //
    // Pedersen commitment limbs       = 2  (BabyJubJub point packed as x, y)
    // Transfer public-input limbs     = 6  ([C_old(x,y), C_tx(x,y), C_new(x,y)])
    // Packed Groth16 proof limbs      = 8  ([pi_a(x,y), pi_b(x0,x1,y0,y1), pi_c(x,y)])

    // ─── IJanusFlowImpl conformance ──────────────────────────────────────────────

    access(all) view fun validateWrap(
        amountAttoFlow: UInt256,
        txCommit: [UInt256],
        amountProof: [UInt256]
    ): String {
        if amountAttoFlow == 0 {
            return "zero amount not allowed"
        }
        if txCommit.length != 2 {
            return "invalid txCommit length: expected 2, got "
                .concat(txCommit.length.toString())
        }
        if amountProof.length != 8 {
            return "invalid amountProof length: expected 8, got "
                .concat(amountProof.length.toString())
        }
        return ""
    }

    access(all) view fun validateShieldedTransfer(
        publicInputs: [UInt256],
        proof: [UInt256]
    ): String {
        if publicInputs.length != 6 {
            return "invalid publicInputs length: expected 6, got "
                .concat(publicInputs.length.toString())
        }
        if proof.length != 8 {
            return "invalid proof length: expected 8, got "
                .concat(proof.length.toString())
        }
        return ""
    }

    access(all) view fun validateUnwrap(
        claimedAmountAttoFlow: UInt256,
        txCommit: [UInt256],
        amountProof: [UInt256],
        transferPublicInputs: [UInt256],
        transferProof: [UInt256]
    ): String {
        if claimedAmountAttoFlow == 0 {
            return "zero amount not allowed"
        }
        if txCommit.length != 2 {
            return "invalid txCommit length: expected 2, got "
                .concat(txCommit.length.toString())
        }
        if amountProof.length != 8 {
            return "invalid amountProof length: expected 8, got "
                .concat(amountProof.length.toString())
        }
        if transferPublicInputs.length != 6 {
            return "invalid transferPublicInputs length: expected 6, got "
                .concat(transferPublicInputs.length.toString())
        }
        if transferProof.length != 8 {
            return "invalid transferProof length: expected 8, got "
                .concat(transferProof.length.toString())
        }
        // Cross-proof consistency: amount-disclose txCommit must equal
        // the C_tx in the transfer public inputs (transferPublicInputs[2..3]).
        // This mirrors the EVM JanusFlow._unwrap C_tx-mismatch check and
        // lets the Cadence layer fail fast before the EVM call.
        if txCommit[0] != transferPublicInputs[2] || txCommit[1] != transferPublicInputs[3] {
            return "C_tx mismatch between amount-disclose and transfer proofs"
        }
        return ""
    }

    access(all) view fun version(): String {
        return "0.3.0"
    }

    access(all) view fun cryptoScheme(): String {
        return "BabyJubJub-Pedersen + Groth16 (Hermez pot14 + 2 contributors + Flow VRF beacon 323555648)"
    }

    // ─── Initializer ─────────────────────────────────────────────────────────────

    init() {
        // No contract-level fields in v0.3 — all constants are inlined to keep
        // the contract storage shape forward-compatible with future updates
        // (Cadence cannot add new non-optional fields on `update-contract`).
    }
}

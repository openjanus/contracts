// janus_transfer.cdc — Execute a confidential transfer via JanusToken Cadence contract
//
// Calls JanusToken.confidentialTransfer(signer, toHex, publicInputs, proof).
// The JanusToken Cadence contract borrows the COA from /storage/openjanusCOA
// and calls the EVM contract. msg.sender in EVM = COA EVM address.
//
// Parameters:
//   toHex          — recipient EVM address (40 hex chars, no 0x prefix)
//   pub0..pub5     — public inputs [C_old.x, C_old.y, C_tx.x, C_tx.y, C_new.x, C_new.y]
//   pr0..pr7       — proof [pA.x, pA.y, pB[0][0], pB[0][1], pB[1][0], pB[1][1], pC.x, pC.y]
//
// The proof must have EIP-197 pi_b Fp2 swap applied.
// Part of zk-prop e2e test suite (Phase 2 — NATIVE mode write test).

import JanusToken from 0x28fef3d1d6a12800

transaction(
    toHex: String,
    pub0: UInt256, pub1: UInt256, pub2: UInt256, pub3: UInt256, pub4: UInt256, pub5: UInt256,
    pr0: UInt256, pr1: UInt256, pr2: UInt256, pr3: UInt256, pr4: UInt256, pr5: UInt256, pr6: UInt256, pr7: UInt256
) {
    prepare(signer: auth(BorrowValue) &Account) {
        let publicInputs: [UInt256; 6] = [pub0, pub1, pub2, pub3, pub4, pub5]
        let proof: [UInt256; 8]        = [pr0, pr1, pr2, pr3, pr4, pr5, pr6, pr7]

        JanusToken.confidentialTransfer(
            signer: signer,
            toHex: toHex,
            publicInputs: publicInputs,
            proof: proof
        )
        log("janus_transfer: OK to=".concat(toHex))
    }
}

// janus_flow_transfer.cdc — Execute a confidential transfer via JanusFlow (v1.1.0)
//
// Performs a ZK-proof-verified confidential transfer from sender's COA slot
// to recipient's COA slot. No FLOW moves — only commitment slots change.
//
// Parameters:
//   fromCoaHex    — Sender's COA EVM address (40 hex chars, no 0x prefix)
//   toCoaHex      — Recipient's COA EVM address (40 hex chars, no 0x prefix)
//   publicInputs  — [C_old.x, C_old.y, C_tx.x, C_tx.y, C_new.x, C_new.y] (6 UInt256)
//   proof         — [pA.x, pA.y, pB[0][0], pB[0][1], pB[1][0], pB[1][1], pC.x, pC.y] (8 UInt256)
//
// The proof must have EIP-197 pi_b Fp2 swap applied.
// Signer: openjanus account (holds /storage/openjanusCOA for EVM call authority)

import JanusFlow from 0x28fef3d1d6a12800

transaction(
    fromCoaHex: String,
    toCoaHex: String,
    publicInputs: [UInt256],
    proof: [UInt256]
) {
    prepare(signer: auth(BorrowValue) &Account) {
        let inputs: [UInt256; 6] = [
            publicInputs[0], publicInputs[1], publicInputs[2],
            publicInputs[3], publicInputs[4], publicInputs[5]
        ]
        let proofArr: [UInt256; 8] = [
            proof[0], proof[1], proof[2], proof[3],
            proof[4], proof[5], proof[6], proof[7]
        ]

        JanusFlow.confidentialTransfer(
            signer: signer,
            fromCoaHex: fromCoaHex,
            toCoaHex: toCoaHex,
            publicInputs: inputs,
            proof: proofArr
        )

        log("janus_flow_transfer v1.1.0: OK from=".concat(fromCoaHex)
            .concat(" to=").concat(toCoaHex))
    }
}

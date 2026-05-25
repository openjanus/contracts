// janus_flow_unwrap.cdc — Unwrap FLOW from a confidential commitment via JanusFlow (v1.1.0)
//
// Burns the user's commitment slot and releases FLOW to the recipient.
// The caller must provide (cx, cy) matching the user's on-chain commitment.
//
// Parameters:
//   cx          — Current commitment x-coordinate (must match on-chain for userCoaHex)
//   cy          — Current commitment y-coordinate (must match on-chain for userCoaHex)
//   amount      — FLOW amount to release
//   recipient   — Cadence address to receive FLOW
//   userCoaHex  — User's COA EVM address (40 hex chars, no 0x prefix)
//
// Signer: openjanus account (holds /storage/openjanusCOA for mintXY authority)

import JanusFlow from 0x28fef3d1d6a12800

transaction(cx: UInt256, cy: UInt256, amount: UFix64, recipient: Address, userCoaHex: String) {
    prepare(signer: auth(BorrowValue) &Account) {
        JanusFlow.unwrap(
            signer: signer,
            cx: cx,
            cy: cy,
            amount: amount,
            recipient: recipient,
            userCoaHex: userCoaHex
        )
        log("janus_flow_unwrap v1.1.0: OK amount=".concat(amount.toString())
            .concat(" userCoaHex=").concat(userCoaHex))
    }
}

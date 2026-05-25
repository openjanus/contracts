// janus_flow_unwrap.cdc — Unwrap FLOW from a confidential commitment via JanusFlow
//
// Burns the commitment and releases FLOW to the recipient.
// The caller must know (cx, cy) that matches the on-chain commitment.
//
// Parameters:
//   cx        — Current commitment x-coordinate (must match on-chain)
//   cy        — Current commitment y-coordinate (must match on-chain)
//   amount    — FLOW amount to release
//   recipient — Cadence address to receive FLOW

import JanusFlow from 0x28fef3d1d6a12800

transaction(cx: UInt256, cy: UInt256, amount: UFix64, recipient: Address) {
    prepare(signer: auth(BorrowValue) &Account) {
        JanusFlow.unwrap(
            signer: signer,
            cx: cx,
            cy: cy,
            amount: amount,
            recipient: recipient
        )
        log("janus_flow_unwrap: OK amount=".concat(amount.toString()))
    }
}

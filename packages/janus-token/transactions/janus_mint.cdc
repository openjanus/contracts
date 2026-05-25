// janus_mint.cdc — Mint a Pedersen commitment to an EVM address via JanusToken
//
// Calls JanusToken.mintXY(signer, toHex, cx, cy) on the Cadence contract.
// The JanusToken Cadence contract borrows the COA from /storage/openjanusCOA.
// Only the openjanus account (0x28fef3d1d6a12800) holds this COA.
//
// Parameters:
//   toHex  — recipient EVM address (40 hex chars, no 0x prefix)
//   cx     — Pedersen commitment x-coordinate (BabyJubJub)
//   cy     — Pedersen commitment y-coordinate (BabyJubJub)
//
// Part of zk-prop e2e test suite (Phase 2 — NATIVE mode write test).

import JanusToken from 0x28fef3d1d6a12800

transaction(toHex: String, cx: UInt256, cy: UInt256) {
    prepare(signer: auth(BorrowValue) &Account) {
        JanusToken.mintXY(signer: signer, toHex: toHex, cx: cx, cy: cy)
        log("janus_mint: OK to=".concat(toHex))
    }
}

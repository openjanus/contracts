// janus_balance.cdc — Read balance commitment for an EVM address from JanusToken
//
// Returns [cx, cy] commitment point. Identity point (0, 1) means zero balance.
// Uses JanusToken.balanceXY which internally does EVM.dryCall (no COA required).
//
// Parameters:
//   accountHex — EVM address (40 hex chars, with or without 0x prefix)
//
// Part of zk-prop e2e test suite.

import JanusToken from 0x28fef3d1d6a12800

access(all) fun main(accountHex: String): [UInt256] {
    return JanusToken.balanceXY(accountHex: accountHex)
}

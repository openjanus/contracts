// janus_flow_state.cdc — Read JanusFlow state (v1.1.0)
//
// Returns [totalLocked_scaled, user_cx, user_cy] for a given user's COA EVM address.
//
// Parameters:
//   userCoaHex — User's COA EVM address (40 hex chars, with or without 0x)

import JanusFlow from 0x28fef3d1d6a12800

access(all) fun main(userCoaHex: String): [UInt256] {
    let commit = JanusFlow.userCommitmentXY(userCoaHex: userCoaHex)
    // Convert UFix64 to UInt256 (scaled by 10^8 for lossless representation)
    let lockedScaled = UInt256(JanusFlow.totalLocked() * 100000000.0)
    return [lockedScaled, commit[0], commit[1]]
}

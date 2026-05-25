// janus_flow_state.cdc — Read JanusFlow state
// Returns [totalLocked_as_uint64, tracking_cx, tracking_cy]

import JanusFlow from 0x28fef3d1d6a12800

access(all) fun main(): [UInt256] {
    let commit = JanusFlow.trackingCommitmentXY()
    // Convert UFix64 to UInt256 (scaled by 10^8)
    let lockedScaled = UInt256(JanusFlow.totalLocked() * 100000000.0)
    return [lockedScaled, commit[0], commit[1]]
}

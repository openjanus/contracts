// admin_reset_slot.cdc — TESTNET-ONLY admin recovery transaction.
//
// PRIVACY-BREAKING — never run this against a mainnet deployment. Two layered
// gates make accidental misuse hard:
//
//   1. Cadence side: the signer must hold the JanusFlow AdminResource at
//      /storage/janusFlowAdmin (only the deployer 0x5dcbeb41055ec57e has it).
//   2. EVM side: the proxy's adminResetSlot is gated by `onlyOwner` AND a
//      hard `require(block.chainid == 545)` check, so it will revert on any
//      chain other than Flow EVM testnet.
//
// This transaction zeros out `commitments[targetCOA]` on the EVM JanusFlow
// proxy so the target can wrap fresh with a brand-new blinding chain.
//
// Usage:
//   flow transactions send transactions/admin_reset_slot.cdc 0x<target> \
//     --signer openjanus-flow --network testnet \
//     --gas-limit 9999

import JanusFlow from 0x5dcbeb41055ec57e

transaction(targetAddr: Address) {
    prepare(signer: auth(BorrowValue) &Account) {
        JanusFlow.adminResetSlot(signer: signer, target: targetAddr)
    }
}

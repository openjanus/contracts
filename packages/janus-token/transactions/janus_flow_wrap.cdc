// janus_flow_wrap.cdc — Wrap FLOW tokens into a confidential commitment via JanusFlow (v1.1.0)
//
// Deposits FLOW from the signer's account into JanusFlow escrow and
// mints a Pedersen commitment to the USER's COA EVM address (per-user tracking).
//
// Parameters:
//   amount      — FLOW amount to wrap (UFix64)
//   cx          — Pedersen commitment x-coordinate (UInt256)
//   cy          — Pedersen commitment y-coordinate (UInt256)
//   depositor   — Cadence address of the user depositing (for event emission)
//   userCoaHex  — User's COA EVM address (40 hex chars, no 0x prefix)
//
// Signer: openjanus account (holds /storage/openjanusCOA for mintXY authority)

import JanusFlow from 0x28fef3d1d6a12800
import FlowToken from 0x7e60df042a9c0868
import FungibleToken from 0x9a0766d93b6608b7

transaction(amount: UFix64, cx: UInt256, cy: UInt256, depositor: Address, userCoaHex: String) {
    prepare(signer: auth(BorrowValue) &Account) {
        // Withdraw FLOW from signer (openjanus account holds deposited FLOW)
        let flowVault = signer.storage.borrow<auth(FungibleToken.Withdraw) &FlowToken.Vault>(
            from: /storage/flowTokenVault
        ) ?? panic("No FlowToken vault")

        let depositVault <- flowVault.withdraw(amount: amount) as! @FlowToken.Vault

        // Wrap into JanusFlow — mints commitment to user's COA EVM slot
        JanusFlow.wrap(
            signer: signer,
            vault: <-depositVault,
            cx: cx,
            cy: cy,
            depositor: depositor,
            userCoaHex: userCoaHex
        )

        log("janus_flow_wrap v1.1.0: OK amount=".concat(amount.toString())
            .concat(" userCoaHex=").concat(userCoaHex))
    }
}

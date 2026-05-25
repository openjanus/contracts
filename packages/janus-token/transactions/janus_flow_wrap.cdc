// janus_flow_wrap.cdc — Wrap FLOW tokens into a confidential commitment via JanusFlow
//
// Deposits FLOW from the signer's account into JanusFlow escrow and
// mints a Pedersen commitment to the tracking EVM address.
//
// Parameters:
//   amount  — FLOW amount to wrap (UFix64 as string)
//   cx      — Pedersen commitment x-coordinate (UInt256)
//   cy      — Pedersen commitment y-coordinate (UInt256)

import JanusFlow from 0x28fef3d1d6a12800
import FlowToken from 0x7e60df042a9c0868
import FungibleToken from 0x9a0766d93b6608b7

transaction(amount: UFix64, cx: UInt256, cy: UInt256) {
    prepare(signer: auth(BorrowValue) &Account) {
        // Withdraw FLOW from signer
        let flowVault = signer.storage.borrow<auth(FungibleToken.Withdraw) &FlowToken.Vault>(
            from: /storage/flowTokenVault
        ) ?? panic("No FlowToken vault")

        let depositVault <- flowVault.withdraw(amount: amount) as! @FlowToken.Vault

        // Wrap into JanusFlow
        JanusFlow.wrap(
            signer: signer,
            vault: <-depositVault,
            cx: cx,
            cy: cy,
            depositor: signer.address
        )

        log("janus_flow_wrap: OK amount=".concat(amount.toString()))
    }
}

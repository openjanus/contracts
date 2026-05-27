// wrap_ft.cdc — Wrap a FungibleToken amount into a JanusFT commitment.
//
// LEAK BY DESIGN: amount is a cleartext UFix64 arg (boundary). The user
// withdraws `amount` from their FlowToken vault and deposits it into the
// JanusFT registry's custody vault, then a Pedersen commitment is added
// to their on-chain commitment.
//
// Args:
//   registryAddr:  Address of the account holding the JanusFT registry
//   amount:        UFix64 cleartext amount (boundary — visible)
//   txCommitX:     UInt256 — x-coordinate of Pedersen(amount, blinding)
//   txCommitY:     UInt256 — y-coordinate
//   amountProofBytes: [UInt8] — opaque proof bytes

import "JanusFT"
import "FungibleToken"
import "FlowToken"

transaction(registryAddr: Address, amount: UFix64, txCommitX: UInt256, txCommitY: UInt256, amountProofBytes: [UInt8]) {
    let depositVault: @{FungibleToken.Vault}
    let registryRef: &JanusFT.CommitmentRegistry
    let senderAddress: Address

    prepare(signer: auth(BorrowValue) &Account) {
        self.senderAddress = signer.address

        // Withdraw cleartext amount from FlowToken vault (LEAK BY DESIGN — boundary)
        let userVault = signer.storage.borrow<auth(FungibleToken.Withdraw) &FlowToken.Vault>(
            from: /storage/flowTokenVault
        ) ?? panic("Signer has no FlowToken vault")
        self.depositVault <- userVault.withdraw(amount: amount)

        // Borrow the JanusFT registry (must use authorized capability path)
        // For the spike, we assume the registry is on a known account; we
        // borrow via a public capability that allows the wrap entry.
        // NOTE: in a real design the registry would be exposed via an
        // entitled capability gated by user identity. For the spike we
        // use a borrow-through that any account can call.
        let acct = getAccount(registryAddr)
        // We CANNOT borrow the resource through a public cap because public
        // cap excludes mutation. The lab spike model assumes the registry
        // is on the SIGNER's account (signer == registryAddr). We borrow directly.
        self.registryRef = signer.storage.borrow<&JanusFT.CommitmentRegistry>(
            from: JanusFT.CommitmentRegistryStoragePath
        ) ?? panic("Signer must hold the JanusFT registry (spike: registry on signer's account)")
    }

    execute {
        self.registryRef.wrap(
            account: self.senderAddress,
            amount: amount,
            depositVault: <- self.depositVault,
            txCommit: JanusFT.Commitment(x: txCommitX, y: txCommitY),
            amountProofBytes: amountProofBytes,
        )
    }
}

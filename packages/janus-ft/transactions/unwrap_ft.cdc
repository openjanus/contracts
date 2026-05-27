// unwrap_ft.cdc — Release `claimedAmount` FT from JanusFT custody to a recipient.
//
// LEAK BY DESIGN: claimedAmount is a cleartext UFix64 arg (boundary).
//
// Args:
//   claimedAmount:           UFix64 cleartext amount (boundary — visible)
//   recipient:               Address that will receive the FT vault
//   txCommitX, txCommitY:    Pedersen(claimedAmount, blinding) coords
//   amountProofBytes:        amount_disclose Groth16 proof
//   transferPublicInputs:    [C_old, C_tx, C_new] — must include txCommit at [2..3]
//   transferProofBytes:      ConfidentialTransfer Groth16 proof

import "JanusFT"
import "FungibleToken"
import "FlowToken"

transaction(
    claimedAmount: UFix64,
    recipient: Address,
    txCommitX: UInt256, txCommitY: UInt256,
    amountProofBytes: [UInt8],
    transferPublicInputs: [UInt256; 6],
    transferProofBytes: [UInt8]
) {
    let registryRef: &JanusFT.CommitmentRegistry
    let senderAddress: Address

    prepare(signer: auth(BorrowValue) &Account) {
        self.senderAddress = signer.address
        self.registryRef = signer.storage.borrow<&JanusFT.CommitmentRegistry>(
            from: JanusFT.CommitmentRegistryStoragePath
        ) ?? panic("Signer must hold the JanusFT registry (spike model)")
    }

    execute {
        let withdrawn <- self.registryRef.unwrap(
            account: self.senderAddress,
            claimedAmount: claimedAmount,
            recipient: recipient,
            txCommit: JanusFT.Commitment(x: txCommitX, y: txCommitY),
            amountProofBytes: amountProofBytes,
            transferPublicInputs: transferPublicInputs,
            transferProofBytes: transferProofBytes,
        )
        // Deposit withdrawn FT vault into recipient's FlowToken receiver
        let recipientReceiver = getAccount(recipient)
            .capabilities
            .borrow<&{FungibleToken.Receiver}>(/public/flowTokenReceiver)
            ?? panic("Recipient has no FlowToken receiver")
        recipientReceiver.deposit(from: <- withdrawn)
    }
}

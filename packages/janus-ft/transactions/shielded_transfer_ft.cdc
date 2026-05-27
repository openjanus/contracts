// shielded_transfer_ft.cdc — Hidden transfer between two JanusFT commitments.
//
// PRIVACY-CRITICAL: this transaction takes NO cleartext amount. Only the
// commitment coordinates and proof bytes — all amount info is hidden behind
// Pedersen commitments + Groth16 proof.
//
// Args:
//   toAccount:                   Address of the recipient (visible — account-based model)
//   publicInputs:                [UInt256; 6] — [C_old.x, C_old.y, C_tx.x, C_tx.y, C_new.x, C_new.y]
//   proofBytes:                  [UInt8] — opaque Groth16 proof

import "JanusFT"

transaction(toAccount: Address, publicInputs: [UInt256; 6], proofBytes: [UInt8]) {
    let registryRef: &JanusFT.CommitmentRegistry
    let senderAddress: Address

    prepare(signer: auth(BorrowValue) &Account) {
        self.senderAddress = signer.address
        self.registryRef = signer.storage.borrow<&JanusFT.CommitmentRegistry>(
            from: JanusFT.CommitmentRegistryStoragePath
        ) ?? panic("Signer must hold the JanusFT registry (spike model)")
    }

    execute {
        self.registryRef.shieldedTransfer(
            fromAccount: self.senderAddress,
            toAccount: toAccount,
            publicInputs: publicInputs,
            proofBytes: proofBytes,
        )
    }
}

// setup_janus_ft_registry.cdc
//
// Initialize the JanusFT CommitmentRegistry on the deployment account.
// Funds it with an EMPTY FlowToken vault as the custody vault.
// Run once per deployment.

import "JanusFT"
import "FungibleToken"
import "FlowToken"

transaction {
    prepare(signer: auth(SaveValue, BorrowValue, Capabilities) &Account) {
        // Skip if already set up
        if signer.storage.borrow<&JanusFT.CommitmentRegistry>(from: JanusFT.CommitmentRegistryStoragePath) != nil {
            return
        }

        // Create empty FlowToken vault for custody
        let emptyVault <- FlowToken.createEmptyVault(vaultType: Type<@FlowToken.Vault>())
        let registry <- JanusFT.createRegistry(vault: <- emptyVault)
        signer.storage.save(<- registry, to: JanusFT.CommitmentRegistryStoragePath)

        // Publish public capability for reading commitments
        let cap = signer.capabilities.storage.issue<&{JanusFT.CommitmentRegistryPublic}>(
            JanusFT.CommitmentRegistryStoragePath
        )
        signer.capabilities.publish(cap, at: JanusFT.CommitmentRegistryPublicPath)
    }
}

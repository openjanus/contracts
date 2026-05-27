// reset-janus-ft.cdc — DEV ONLY. Wipes all commitments + totalLocked so the
// stub-crypto smoke can be re-run without overflow. Requires the deployer
// account's Admin resource at /storage/janusFTAdmin.

import "JanusFT"

transaction {
    prepare(signer: auth(BorrowValue) &Account) {
        let admin = signer.storage.borrow<&JanusFT.Admin>(from: JanusFT.AdminStoragePath)
            ?? panic("Admin not found at /storage/janusFTAdmin")
        admin.resetCommitmentsForTestingOnly()
    }
}

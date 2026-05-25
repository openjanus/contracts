// JanusToken.cdc — Cadence wrapper for JanusToken EVM contract
//
// Provides a Cadence-native API for interacting with the JanusToken EVM contract
// via the openjanus Cadence Owned Account (COA). All state lives in EVM — this
// contract is a pure cross-VM interface layer.
//
// JanusToken EVM (testnet): 0x53F49881A1132FF4F674D2c015e35D5B07Fa1F4A
// openjanus COA EVM:         0x0000000000000000000000027eb18dc34b9966fd
//
// Supported operations:
//   mintXY(to, cx, cy)           — NATIVE mode: mint commitment (owner only via COA)
//   confidentialTransfer(...)    — transfer with ZK proof (any caller via COA)
//   balanceXY(account)           — read commitment as [x, y] (view, no COA needed)
//   totalSupplyXY()              — read total supply commitment (view)
//   janusTokenAddress()          — return EVM contract address
//
// Cross-VM patterns used:
//   coa.call(...)                — for state-changing EVM calls
//   EVM.dryCall(...)             — for read-only EVM queries (no COA required)
//   EVM.encodeABIWithSignature   — for calldata construction
//   EVM.decodeABI               — for return value decoding
//
// Part of openjanus/contracts (TIER 2). Named after the Roman god Janus.

import "EVM"

access(all) contract JanusToken {

    // -------------------------------------------------------------------------
    // Constants
    // -------------------------------------------------------------------------

    /// EVM address of the deployed JanusToken.sol (Flow EVM testnet).
    access(all) let EVM_ADDRESS: String

    /// EVM address of the openjanus COA (the owner of the EVM contract).
    access(all) let COA_EVM_ADDRESS: String

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    access(all) event MintCalled(to: String, cx: UInt256, cy: UInt256)
    access(all) event ConfidentialTransferCalled(from: String, to: String)
    access(all) event BalanceQueried(account: String, cx: UInt256, cy: UInt256)

    // -------------------------------------------------------------------------
    // Read functions (use EVM.dryCall — no COA required)
    // -------------------------------------------------------------------------

    /// Return the deployed JanusToken EVM contract address.
    access(all) fun janusTokenAddress(): String {
        return self.EVM_ADDRESS
    }

    /// Return the balance commitment for an EVM address as [x, y].
    ///
    /// @param accountHex  EVM address (with or without 0x prefix)
    /// @return [x, y] BabyJubJub commitment coordinates. [0, 1] = identity = zero balance.
    access(all) fun balanceXY(accountHex: String): [UInt256] {
        let addr = JanusToken._stripHex(accountHex)

        let calldata = EVM.encodeABIWithSignature(
            "balanceOfCommitmentXY(address)",
            [EVM.addressFromString(addr)]
        )

        let result = EVM.dryCall(
            from: EVM.addressFromString("0000000000000000000000000000000000000000"),
            to: EVM.addressFromString(JanusToken._stripHex(self.EVM_ADDRESS)),
            data: calldata,
            gasLimit: 50_000,
            value: EVM.Balance(attoflow: 0)
        )

        assert(
            result.status == EVM.Status.successful,
            message: "balanceXY dryCall failed: ".concat(result.errorMessage)
        )

        let decoded = EVM.decodeABI(
            types: [Type<UInt256>(), Type<UInt256>()],
            data: result.data
        )

        let cx = decoded[0] as! UInt256
        let cy = decoded[1] as! UInt256

        emit BalanceQueried(account: accountHex, cx: cx, cy: cy)
        return [cx, cy]
    }

    /// Return the total supply commitment as [x, y].
    access(all) fun totalSupplyXY(): [UInt256] {
        let calldata = EVM.encodeABIWithSignature(
            "totalSupplyCommitment()",
            []
        )

        let result = EVM.dryCall(
            from: EVM.addressFromString("0000000000000000000000000000000000000000"),
            to: EVM.addressFromString(JanusToken._stripHex(self.EVM_ADDRESS)),
            data: calldata,
            gasLimit: 50_000,
            value: EVM.Balance(attoflow: 0)
        )

        assert(
            result.status == EVM.Status.successful,
            message: "totalSupplyXY dryCall failed: ".concat(result.errorMessage)
        )

        // totalSupplyCommitment() returns a struct (x, y) — encoded as two uint256
        let decoded = EVM.decodeABI(
            types: [Type<UInt256>(), Type<UInt256>()],
            data: result.data
        )

        return [decoded[0] as! UInt256, decoded[1] as! UInt256]
    }

    // -------------------------------------------------------------------------
    // Write functions (require COA borrow — caller must be openjanus account)
    // -------------------------------------------------------------------------

    /// Mint a Pedersen commitment to an EVM address (NATIVE mode, owner/COA only).
    ///
    /// Uses mintXY(address,uint256,uint256) to avoid struct ABI encoding issues.
    /// The caller must be the account that holds the openjanus COA.
    ///
    /// @param signer  Account that holds the openjanus COA at /storage/openjanusCOA
    /// @param toHex   Recipient EVM address (hex, with or without 0x)
    /// @param cx      Pedersen commitment x-coordinate
    /// @param cy      Pedersen commitment y-coordinate
    access(all) fun mintXY(
        signer: auth(BorrowValue) &Account,
        toHex: String,
        cx: UInt256,
        cy: UInt256
    ) {
        let coa = signer.storage
            .borrow<auth(EVM.Call) &EVM.CadenceOwnedAccount>(from: /storage/openjanusCOA)
            ?? panic("JanusToken.cdc: No COA at /storage/openjanusCOA")

        let to = JanusToken._stripHex(toHex)

        let calldata = EVM.encodeABIWithSignature(
            "mintXY(address,uint256,uint256)",
            [EVM.addressFromString(to), cx, cy]
        )

        let result = coa.call(
            to: EVM.addressFromString(JanusToken._stripHex(self.EVM_ADDRESS)),
            data: calldata,
            gasLimit: 200_000,
            value: EVM.Balance(attoflow: 0)
        )

        assert(
            result.status == EVM.Status.successful,
            message: "JanusToken.mintXY failed: ".concat(result.errorMessage)
        )

        emit MintCalled(to: toHex, cx: cx, cy: cy)
    }

    /// Execute a confidential transfer via COA.
    ///
    /// Calls JanusToken.confidentialTransfer(address,uint256[6],uint256[8]).
    /// The proof must have EIP-197 pi_b Fp2 swap applied.
    ///
    /// @param signer        Account holding the COA (must be the token sender in EVM)
    /// @param toHex         Recipient EVM address
    /// @param publicInputs  [C_old.x, C_old.y, C_tx.x, C_tx.y, C_new.x, C_new.y]
    /// @param proof         [pA.x, pA.y, pB[0][0], pB[0][1], pB[1][0], pB[1][1], pC.x, pC.y]
    access(all) fun confidentialTransfer(
        signer: auth(BorrowValue) &Account,
        toHex: String,
        publicInputs: [UInt256; 6],
        proof: [UInt256; 8]
    ) {
        let coa = signer.storage
            .borrow<auth(EVM.Call) &EVM.CadenceOwnedAccount>(from: /storage/openjanusCOA)
            ?? panic("JanusToken.cdc: No COA at /storage/openjanusCOA")

        let to = JanusToken._stripHex(toHex)

        let calldata = EVM.encodeABIWithSignature(
            "confidentialTransfer(address,uint256[6],uint256[8])",
            [EVM.addressFromString(to), publicInputs, proof]
        )

        let result = coa.call(
            to: EVM.addressFromString(JanusToken._stripHex(self.EVM_ADDRESS)),
            data: calldata,
            gasLimit: 800_000,
            value: EVM.Balance(attoflow: 0)
        )

        assert(
            result.status == EVM.Status.successful,
            message: "JanusToken.confidentialTransfer failed: ".concat(result.errorMessage)
        )

        emit ConfidentialTransferCalled(from: coa.address().toString(), to: toHex)
    }

    // -------------------------------------------------------------------------
    // Internal helpers
    // -------------------------------------------------------------------------

    /// Strip leading "0x" or "0X" prefix from a hex string.
    access(self) fun _stripHex(_ hex: String): String {
        if hex.length >= 2 && (hex.slice(from: 0, upTo: 2) == "0x" || hex.slice(from: 0, upTo: 2) == "0X") {
            return hex.slice(from: 2, upTo: hex.length)
        }
        return hex
    }

    // -------------------------------------------------------------------------
    // Initializer
    // -------------------------------------------------------------------------

    init(evmAddress: String) {
        self.EVM_ADDRESS = evmAddress
        self.COA_EVM_ADDRESS = "0x0000000000000000000000027eb18dc34b9966fd"
    }
}

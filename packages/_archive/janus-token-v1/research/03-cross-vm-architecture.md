# Cross-VM Architecture

## The two VMs on Flow

Flow runs two distinct execution environments atomically within a single transaction:

| Aspect | Cadence VM | Flow EVM |
|--------|-----------|----------|
| Language | Cadence | Solidity |
| State | Resources, Capabilities | Mappings, structs |
| Auth model | Capabilities & entitlements | msg.sender |
| Gas | Computation Units (CU) | EVM gas |
| Addressing | 8-byte hex | 20-byte EVM address |

The key insight: a **Cadence Owned Account (COA)** is a resource that bridges them. The COA has an EVM address derived from its Cadence storage path. When a COA calls an EVM contract, the EVM sees the COA's EVM address as `msg.sender`.

The openjanus COA:
- Cadence storage: `0x28fef3d1d6a12800 /storage/evm`
- EVM address: `0x0000000000000000000000027eb18dc34b9966fd`

## Cross-VM call pattern for JanusToken

### Minting from Cadence

```cadence
import "EVM"

transaction(contractHex: String, toHex: String, commitX: UInt256, commitY: UInt256) {
    prepare(signer: auth(BorrowValue) &Account) {
        let coa = signer.storage
            .borrow<auth(EVM.Call) &EVM.CadenceOwnedAccount>(from: /storage/evm)
            ?? panic("No COA")

        let calldata = EVM.encodeABIWithSignature(
            "mintXY(address,uint256,uint256)",
            [EVM.addressFromString(toHex), commitX, commitY]
        )

        let result = coa.call(
            to: EVM.addressFromString(contractHex),
            data: calldata,
            gasLimit: 200_000,
            value: EVM.Balance(attoflow: 0)
        )

        assert(result.status == EVM.Status.successful, message: result.errorMessage)
    }
}
```

### Reading balance from Cadence

```cadence
import "EVM"

access(all) fun main(contractHex: String, accountHex: String): [UInt256] {
    let calldata = EVM.encodeABIWithSignature(
        "balanceOfCommitmentXY(address)",
        [EVM.addressFromString(accountHex)]
    )

    let result = EVM.dryCall(
        from: EVM.addressFromString("0000000000000000000000000000000000000000"),
        to: EVM.addressFromString(contractHex),
        data: calldata,
        gasLimit: 50_000,
        value: EVM.Balance(attoflow: 0)
    )

    assert(result.status == EVM.Status.successful, message: result.errorMessage)

    let decoded = EVM.decodeABI(
        types: [Type<UInt256>(), Type<UInt256>()],
        data: result.data
    )

    return [decoded[0] as! UInt256, decoded[1] as! UInt256]
}
```

## CU budget considerations

The total Cross-VM computation unit ceiling is 9999 CU per Cadence transaction. This limits how much work can be done atomically:

| Operation | Approximate CU cost |
|-----------|---------------------|
| COA borrow | ~10 |
| `EVM.encodeABIWithSignature` | ~50-100 |
| `coa.call` overhead | ~100 |
| EVM `confidentialTransfer` (~310k gas) | ~310 |
| EVM `mint` (~55k gas) | ~55 |

Single mint or transfer operations are well within budget. Batch operations should be split across transactions.

## JanusToken.cdc Cadence wrapper

The Cadence wrapper is a `contract` (not a resource) that exposes:
- `mint(to, cx, cy)` — calls EVM `mintXY` via COA
- `confidentialTransfer(to, publicInputs, proof)` — calls EVM `confidentialTransfer` via COA
- `balanceXY(account)` — reads EVM state via `EVM.dryCall`
- `janusTokenAddress()` — returns the EVM contract address

The wrapper makes JanusToken callable from any Cadence transaction without the caller needing to know about ABI encoding.

## Deployment sequence

1. Compile `JanusToken.sol` → get bytecode
2. Deploy via COA `deploy()` call → get EVM address
3. Update `JanusToken.cdc` with the deployed EVM address
4. Deploy `JanusToken.cdc` to `0x28fef3d1d6a12800`

The Cadence contract stores the EVM address as a constant — it is set at deployment time via the contract initializer argument.

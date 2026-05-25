# Deployments

## JanusToken — Flow EVM testnet (chainId 545)

> This is a DEMO/TEST instance in NATIVE mode.
> Apps should deploy their own JanusToken instances using `examples/deploy-wrapper.ts`.

| Component | Address | Notes |
|-----------|---------|-------|
| `JanusToken.sol` (EVM) | `0x53F49881A1132FF4F674D2c015e35D5B07Fa1F4A` | NATIVE mode (no underlying) |
| `JanusToken.cdc` (Cadence) | `0x28fef3d1d6a12800` | contract name: `JanusToken` |

### Deploy transactions

| What | Transaction |
|------|------------|
| JanusToken EVM deploy (via COA) | `da430e06a5f831505040b284fffdff53fb3bb5c3e2517b3bc1e10e2e2483b291` |
| JanusToken.cdc deploy | `169325b4a47579451e4f4810a4b5fb87110c54bfd9ff90e1a850f866ca252c31` |

### Flowscan links

- [EVM deploy tx](https://testnet.flowscan.io/tx/da430e06a5f831505040b284fffdff53fb3bb5c3e2517b3bc1e10e2e2483b291)
- [openjanus account](https://testnet.flowscan.io/account/0x28fef3d1d6a12800)

---

## JanusFlow — Cadence FLOW wrapper (testnet)

> JanusFlow wraps Cadence FLOW tokens into confidential Pedersen commitments.
> Wrap mechanism: **Option Y (Cadence-native)** — FlowToken.Vault custody.

| Component | Address | Notes |
|-----------|---------|-------|
| `JanusFlow.cdc` (Cadence) | `0x28fef3d1d6a12800` | contract name: `JanusFlow` |

### JanusFlow deploy transactions

| What | Transaction |
|------|------------|
| JanusFlow.cdc initial deploy | `5c05cb4543ca067613bdf6a37db030088f77b5e253b322d1c4b4cbd717eaff7b` |
| JanusFlow.cdc update (v1.0) | `ccff0e143d20a4a4963a1faab17120654866cabe73f8cee3d3b771b0756d4628` |

### JanusFlow write test results (2026-05-24)

| Test | TX Hash | Result |
|------|---------|--------|
| Wrap 10 FLOW | `5403f9f7fb8f0f9c1ded060ebce7b33685e8b1c4c39a441571947f572f208cbd` | SEALED ✓ |
| Unwrap 10 FLOW | `d47ac8c8dfcb33d8481be0ca4c6d6221c7efc065ac3031731758d8bc508486eb` | SEALED ✓ |

### Flowscan links

- [JanusFlow deploy](https://testnet.flowscan.io/transaction/5c05cb4543ca067613bdf6a37db030088f77b5e253b322d1c4b4cbd717eaff7b)
- [Wrap TX](https://testnet.flowscan.io/transaction/5403f9f7fb8f0f9c1ded060ebce7b33685e8b1c4c39a441571947f572f208cbd)
- [Unwrap TX](https://testnet.flowscan.io/transaction/d47ac8c8dfcb33d8481be0ca4c6d6221c7efc065ac3031731758d8bc508486eb)

---

## Primitives (openjanus/primitives — TIER 1, do not redeploy)

| Primitive | Address |
|-----------|---------|
| `BabyJub.sol` | `0x2c40513b343B70f2A0B7e6Ad6F997DDa819D6f07` |
| `Groth16Verifier` (ConfidentialTransferVerifier) | `0x0085F286d89af79EC59E27CD0c5CcD1c55f42Cf5` |
| `PedersenBabyJub.cdc` | `0x28fef3d1d6a12800` |
| openjanus COA EVM | `0x0000000000000000000000027eb18dc34b9966fd` |

---

## How to deploy your own JanusToken instance

### Wrapper mode (wraps FLOW or USDC)

```bash
cd packages/janus-token
PRIVATE_KEY=0x... UNDERLYING_ADDRESS=0xFLOWEVMADDRESS npx ts-node examples/deploy-wrapper.ts
```

### Native mode (own supply)

```bash
cd packages/janus-token
PRIVATE_KEY=0x... npx ts-node examples/deploy-wrapper.ts
# (omit UNDERLYING_ADDRESS for native mode)
```

Then use the printed address with the SDK:

```typescript
import { JanusToken } from "@openjanus/janus-token";

const myToken = new JanusToken({
  address: "YOUR_DEPLOYED_ADDRESS",
  network: "testnet",
  // Optional — include if wrapper mode:
  // underlying: { address: "0x...", symbol: "FLOW", decimals: 8 }
});
await myToken.connect();
```

---

## Deployment notes

- The openjanus COA (`0x0000...27eb18dc34b9966fd`) is the EVM `owner` of the demo JanusToken.
- Only this COA can call `mintXY`/`burnXY` on the demo instance.
- Apps that deploy their own instances become the `owner` of their deployed contract.
- Primitives (BabyJub, Groth16Verifier) are immutable — pinned at deploy time.

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

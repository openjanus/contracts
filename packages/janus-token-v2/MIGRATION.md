# JanusToken v2 — Migration from v1

## Overview

JanusToken v2 is NOT backward compatible with v1 (`ElGamalAccumulator` / Pedersen-based
`JanusToken`). A fresh deployment is required. There are no on-chain migration utilities
because the cryptographic scheme changed fundamentally.

As of 2026-05-25, there are no known production users of v1 — it was deployed as a
testnet proof-of-concept. This migration guide is for reference if any v1 testnet users
exist.

---

## What Changed

| Aspect | v1 | v2 |
|--------|----|----|
| Primitive | Pedersen commitments | Exponential ElGamal |
| Curve | BabyJubJub | BabyJubJub (same curve) |
| Accumulation | Scalar add | Homomorphic point add |
| ZK scheme | Groth16 (Pedersen) | Groth16 (ElGamal) |
| Key format | EC keypair | EC keypair (different derivation) |
| Contract address | `0x53F49881A1132FF4F674D2c015e35D5B07Fa1F4A` | `0xC715b3647536F671Aa25A6B6Ea1d7f5a0b9fA63D` |
| Cadence address | `0x28fef3d1d6a12800` contract `JanusToken` | `0x28fef3d1d6a12800` contract `JanusFlowV2` |

---

## Migration Steps

### 1. Unwrap all v1 balances

If you have FLOW locked in `JanusToken` (v1), unwrap it first:

```cadence
import JanusFlow from 0x28fef3d1d6a12800
// ... call JanusFlow.unwrap() with your v1 commitment proof
```

### 2. Register a new BabyJubJub pubkey on v2

```cadence
import JanusFlowV2 from 0x28fef3d1d6a12800
// ... call JanusFlowV2.registerPubkey() with your new v2 pubkey
```

Note: The key derivation scheme may differ between v1 and v2 SDK implementations.
Check the `@openjanus/janus-token-v2` SDK documentation.

### 3. Re-wrap your FLOW on v2

```cadence
import JanusFlowV2 from 0x28fef3d1d6a12800
// ... call JanusFlowV2.wrap() with a fresh encrypt_consistency ZK proof
```

---

## No Automatic Migration

There is no automatic or assisted migration path. The cryptographic states between v1
and v2 are incompatible (Pedersen commitments cannot be converted to ElGamal ciphertexts
without revealing the plaintext value).

---

## Timeframe

v1 remains deployed and functional for the foreseeable future. There is no planned
deprecation date as of 2026-05-25.

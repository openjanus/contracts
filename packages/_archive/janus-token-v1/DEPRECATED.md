# DEPRECATED — @openjanus/janus-token (v1, Pedersen-hash)

> **This package is deprecated as of openjanus/contracts v0.2.0 (2026-05-25).**
> Use `packages/janus-token-v2/` for all new development.

---

## Deprecation notice

**Package:** `@openjanus/janus-token` (v1)
**Deprecated:** 2026-05-25
**Reason:** Privacy limitation in multi-sender scenarios
**Replacement:** `packages/janus-token-v2/` (ElGamal-on-BabyJub)
**Historical access:** `git checkout v0.1.0-final`

---

## Why this was deprecated

v1 used circomlib's Pedersen hash for balance commitments via `JanusToken.sol` and
`JanusFlow.cdc`. The system claimed to hide tip/transfer amounts from observers.

The privacy property failed in multi-sender scenarios:

1. **Cadence event leakage:** The Cadence `wrap` transaction calls
   `flowVault.withdraw(amount: amount)` where `amount` is plaintext. Flow's standard
   `FungibleToken` interface emits `TokensWithdrawn(amount: <value>, from: <address>)`
   events. Any chain indexer can read the exact FLOW amount each sender deposited and
   correlate it with the `JanusFlow.wrap(...)` call.

2. **Non-additively-homomorphic commitments:** circomlib Pedersen is a multi-base hash
   function, not a two-generator EC commitment. Recipients accumulating deposits from
   multiple senders could not decrypt a cumulative total — they needed each sender's
   individual `(amount, blinding)` pair.

Full public explanation: https://github.com/openjanus/sdk/blob/main/docs/why-v1-was-deprecated.md

---

## Deployed addresses (historical — do not use for new development)

| Contract | Network | Address | Status |
|----------|---------|---------|--------|
| `JanusToken.sol` (NATIVE demo) | Flow EVM testnet | `0x53F49881A1132FF4F674D2c015e35D5B07Fa1F4A` | DEPRECATED — historical |
| `JanusToken.cdc` | Flow Cadence testnet | `0x28fef3d1d6a12800` (contract: `JanusToken`) | DEPRECATED — historical |
| `JanusFlow.cdc` (v1.1.0) | Flow Cadence testnet | `0x28fef3d1d6a12800` (contract: `JanusFlow`) | DEPRECATED — historical |
| Deploy TX (JanusToken.sol) | Flow EVM testnet | `da430e06a5f831505040b284fffdff53fb3bb5c3e2517b3bc1e10e2e2483b291` | historical |

These contracts remain deployed on Flow EVM testnet as an immutable historical record.
They should not be used for new application development.

---

## Migration to v2

```bash
# Install v2 contracts
cd packages/janus-token-v2

# v2 deployed addresses
# JanusTokenV2.sol: 0xC715b3647536F671Aa25A6B6Ea1d7f5a0b9fA63D
# JanusFlowV2.cdc:  0x28fef3d1d6a12800 (contract: JanusFlowV2)
```

See [`packages/janus-token-v2/MIGRATION.md`](../../janus-token-v2/MIGRATION.md) for the full
migration guide.

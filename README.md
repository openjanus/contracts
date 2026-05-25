# openjanus/contracts

Token standards and high-level contracts built on [@openjanus/primitives](https://github.com/openjanus/primitives).

---

## What this repo is

`openjanus/contracts` is **TIER 2** — it consumes primitives (BabyJub, Pedersen, Groth16) and composes them into deployable token contracts with full Cadence and EVM support on Flow.

```
TIER 1  openjanus/primitives   — BabyJub, Pedersen, Groth16 verifier infrastructure
  ↓
TIER 2  openjanus/contracts    — this repo: JanusToken, future Roman-named contracts
  ↓
TIER 3  apps                   — PrivateTip, LetheOrderbook, AuroraReveal, etc.
```

---

## Packages

| Package | Description | Status |
|---------|-------------|--------|
| [`@openjanus/janus-token-v2`](./packages/janus-token-v2) | ElGamal accumulator confidential token with ZK-gated wrap/unwrap and pubkey rotation | **v2.0.0** — Current |
| [`@openjanus/janus-token`](./_archive/janus-token-v1/) (archived) | ERC-7984 confidential token (Pedersen + Groth16) | **Deprecated** — see [_archive/janus-token-v1/DEPRECATED.md](./_archive/janus-token-v1/DEPRECATED.md) |

---

## Roman mythology naming convention

Every contract in this repo takes the name of a Roman deity associated with **doors, transitions, keys, and thresholds** — reflecting the cross-VM nature of the openjanus stack (Cadence ↔ EVM).

| Name | Deity / Association | Contract | Status |
|------|---------------------|----------|--------|
| **Janus** | Dual-faced god of beginnings and thresholds | `JanusTokenV2` — ElGamal accumulator + ZK proofs | **v2.0.0** — Current |
| ~~Janus~~ | ~~Dual-faced god of beginnings and thresholds~~ | ~~`JanusToken` — cross-VM confidential token (v1 Pedersen)~~ | **Deprecated** — archived |
| Cardea | Goddess of door hinges | `CardeaVault` — time-locked vault | future |
| Portunus | God of keys and ports | `PortunusKey` — multisig key manager | future |
| Limen | God of thresholds | `LimenBridge` — cross-VM router | future |
| Iris | Rainbow messenger of the gods | `IrisStream` — streaming payments | future |
| Forculus | God of doors | `ForculusGate` — NFT-gated access | future |
| Vesta | Goddess of the hearth / treasury | `VestaTreasury` — fee router | future |
| Minerva | Goddess of wisdom | `MinervaProof` — ZK proof toolkit | future |
| Lethe | River of forgetting | `LetheOrderbook` — sealed-bid orderbook | future |
| Proteus | Shape-shifting sea-god | `ProteusShuffle` — verifiable shuffle | future |
| Aurora | Goddess of dawn | `AuroraReveal` — time-released reveal | future |
| Vesper | Evening star | `VesperVault` — concealed storage | future |
| Hekate | Goddess of crossroads and keys | `HekateMixer` — mixer pattern | future |
| Mercurius | Messenger of the gods | `MercuriusTransfer` — generic transfer | future |

Package names use lowercase + hyphen: `@openjanus/janus-token`, `@openjanus/cardea-vault`, etc.

---

## Quick start — JanusTokenV2

```bash
npm install github:openjanus/contracts#main
```

```typescript
import { JanusTokenV2, JANUS_TOKEN_V2_TESTNET } from "@openjanus/janus-token-v2";

const token = new JanusTokenV2(JANUS_TOKEN_V2_TESTNET);
await token.connect();

const ciphertext = await token.getBalanceCiphertext("0xYourAddress");
const hasPk = await token.hasPubkey("0xYourAddress");
```

See [packages/janus-token-v2/README.md](./packages/janus-token-v2/README.md) for the full API.

> **v1 users:** See [packages/_archive/janus-token-v1/DEPRECATED.md](./_archive/janus-token-v1/DEPRECATED.md) for migration guidance and the reason for deprecation.

---

## Deployed contracts (testnet)

### Primitive contracts (canonical — used by all versions)

| Contract | Network | Address |
|----------|---------|---------|
| BabyJub.sol | Flow EVM testnet | `0x2c40513b343B70f2A0B7e6Ad6F997DDa819D6f07` |
| Groth16 Verifier | Flow EVM testnet | `0x0085F286d89af79EC59E27CD0c5CcD1c55f42Cf5` |
| PedersenBabyJub.cdc | Flow testnet (Cadence) | `0x28fef3d1d6a12800` |
| openjanus COA | Flow EVM testnet | `0x0000000000000000000000027eb18dc34b9966fd` |

### v2 token contracts (current — RECOMMENDED)

| Contract | Network | Address |
|----------|---------|---------|
| JanusTokenV2.sol | Flow EVM testnet | `0xC715b3647536F671Aa25A6B6Ea1d7f5a0b9fA63D` |
| JanusFlowV2.cdc | Flow Cadence testnet | `0x28fef3d1d6a12800` (contract: `JanusFlowV2`) |
| EncryptConsistencyVerifier | Flow EVM testnet | `0x6F8Cc93dd6aA7B3ED0a3DaA75271815558ad9b5C` |
| DecryptOpenVerifier | Flow EVM testnet | `0x3bB139B5404fD6b152813bC3532367AAa096638b` |

### v1 contracts (historical — DEPRECATED, do not use for new development)

| Contract | Network | Address | Status |
|----------|---------|---------|--------|
| JanusToken.sol | Flow EVM testnet | `0x53F49881A1132FF4F674D2c015e35D5B07Fa1F4A` | DEPRECATED |
| JanusFlow.cdc (v1.1.0) | Flow Cadence testnet | `0x28fef3d1d6a12800` (contract: `JanusFlow`) | DEPRECATED |

---

## Development

```bash
npm install
npm run build
npm run test
npm run typecheck
```

Requires Node 20+.

---

## License

MIT

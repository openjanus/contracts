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
| [`@openjanus/janus-token`](./packages/janus-token) | ERC-7984 confidential token (Pedersen + Groth16) | **v0.1.0** |

---

## Roman mythology naming convention

Every contract in this repo takes the name of a Roman deity associated with **doors, transitions, keys, and thresholds** — reflecting the cross-VM nature of the openjanus stack (Cadence ↔ EVM).

| Name | Deity / Association | Contract | Status |
|------|---------------------|----------|--------|
| **Janus** | Dual-faced god of beginnings and thresholds | `JanusToken` — cross-VM confidential token | **v0.1.0** |
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

## Quick start — JanusToken

```bash
npm install github:openjanus/contracts#main
```

```typescript
import { JanusToken } from "@openjanus/janus-token";

const token = new JanusToken({ network: "testnet" });
await token.connect();

const commit = await token.balanceOfCommitment("0xYourAddress");
```

See [packages/janus-token/README.md](./packages/janus-token/README.md) for the full API.

---

## Deployed primitives (do not redeploy)

| Contract | Network | Address |
|----------|---------|---------|
| BabyJub.sol | Flow EVM testnet | `0x2c40513b343B70f2A0B7e6Ad6F997DDa819D6f07` |
| Groth16 Verifier | Flow EVM testnet | `0x0085F286d89af79EC59E27CD0c5CcD1c55f42Cf5` |
| PedersenBabyJub.cdc | Flow testnet (Cadence) | `0x28fef3d1d6a12800` |
| openjanus COA | Flow EVM testnet | `0x0000000000000000000000027eb18dc34b9966fd` |

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

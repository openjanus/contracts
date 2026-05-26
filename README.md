# openjanus/contracts

Token standards and high-level contracts built on [@openjanus/primitives](https://github.com/openjanus/primitives).

---

## What this repo is

`openjanus/contracts` is **TIER 2** — it consumes primitives (BabyJub, Pedersen, Groth16) and composes them into deployable token contracts with full Cadence and EVM support on Flow.

```
TIER 1  openjanus/primitives   -- BabyJub, Pedersen, Groth16 verifier infrastructure
  |
TIER 2  openjanus/contracts    -- this repo: JanusToken, future Roman-named contracts
  |
TIER 3  apps                   -- PrivateTip, LetheOrderbook, AuroraReveal, etc.
```

---

## Packages

| Package | Description | Status |
|---------|-------------|--------|
| [`@openjanus/janus-token`](./packages/janus-token) | ElGamal accumulator confidential token with ZK-gated wrap/unwrap and pubkey rotation | **Current** |

---

## Roman mythology naming convention

Every contract in this repo takes the name of a Roman deity associated with **doors, transitions, keys, and thresholds** — reflecting the cross-VM nature of the openjanus stack (Cadence + EVM).

| Name | Deity / Association | Contract | Status |
|------|---------------------|----------|--------|
| **Janus** | Dual-faced god of beginnings and thresholds | `JanusToken` — ElGamal accumulator + ZK proofs | **Current** |
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

## Quick start

```bash
npm install github:openjanus/contracts#main
```

```typescript
import { JanusToken, JANUS_TOKEN_TESTNET } from "@openjanus/janus-token";

const token = new JanusToken(JANUS_TOKEN_TESTNET);
await token.connect();

const ciphertext = await token.getBalanceCiphertext("0xYourAddress");
const hasPk = await token.hasPubkey("0xYourAddress");
```

See [packages/janus-token/README.md](./packages/janus-token/README.md) for the full API.

---

## Deployed contracts (testnet)

### Primitive contracts (canonical)

| Contract | Network | Address |
|----------|---------|---------|
| BabyJub.sol | Flow EVM testnet | `0x2c40513b343B70f2A0B7e6Ad6F997DDa819D6f07` |
| Groth16 Verifier | Flow EVM testnet | `0x0085F286d89af79EC59E27CD0c5CcD1c55f42Cf5` |
| PedersenBabyJub.cdc | Flow testnet (Cadence) | `0x28fef3d1d6a12800` |
| openjanus COA | Flow EVM testnet | `0x0000000000000000000000027eb18dc34b9966fd` |

### JanusToken contracts — v0.2.0 (current, ceremony-backed)

Trusted setup: Hermez pot14 (200+ contributors) + Flow VRF beacon (testnet block 323555648).

| Contract | Network | Address |
|----------|---------|---------|
| JanusToken.sol | Flow EVM testnet | `0xb12E600fFcde967210cFD81CF9f32bBB6e68a499` |
| JanusFlow.cdc | Flow Cadence testnet | `0x28fef3d1d6a12800` (contract: `JanusFlow`, LEGACY v1) |
| EncryptConsistencyVerifier | Flow EVM testnet | `0x0C1e731036f4632CF9620bf6C6BB8204eD3a3B1e` |
| DecryptOpenVerifier | Flow EVM testnet | `0x1c248dA94aab9f4A03005E7944a8b745a6236Dbc` |

E2E: 27/27 PASS (2026-05-26). See `docs/DEPLOYMENTS.md` for full details.

#### DEPRECATED — v0.1.0 addresses (single-contributor lab setup — DO NOT USE)

| Contract | DEPRECATED Address |
|----------|--------------------|
| JanusToken.sol | `0xC715b3647536F671Aa25A6B6Ea1d7f5a0b9fA63D` |
| EncryptConsistencyVerifier | `0x6F8Cc93dd6aA7B3ED0a3DaA75271815558ad9b5C` |
| DecryptOpenVerifier | `0x3bB139B5404fD6b152813bC3532367AAa096638b` |

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

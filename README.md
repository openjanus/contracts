# openjanus/contracts

Token standards and high-level contracts built on [@openjanus/primitives](https://github.com/openjanus/primitives).

---

## What this repo is

`openjanus/contracts` is **TIER 2** — it consumes primitives (BabyJub, Pedersen,
Groth16) and composes them into deployable token contracts with full Cadence and
EVM support on Flow.

```
TIER 1  openjanus/primitives   -- BabyJub.sol, Pedersen, Groth16 verifier infrastructure
  |
TIER 2  openjanus/contracts    -- this repo: JanusToken, JanusFlow, JanusERC20
  |
TIER 3  apps                   -- PrivateTip, LetheOrderbook, AuroraReveal, etc.
```

The privacy primitive in every contract is the same: **Pedersen commitments** on
BabyJubJub, gated by **Groth16** ZK proofs for wrap, shielded transfer, and
unwrap. The v0.2 ElGamal accumulator is fully deprecated and no longer appears
in any current package.

---

## Packages

| Package | Description | Status |
|---|---|---|
| [`@openjanus/janus-token`](./packages/janus-token) | Abstract base SDK class (Pedersen-commit confidential token with Groth16-gated wrap/transfer/unwrap) | Current |
| [`@openjanus/janus-flow`](./packages/janus-flow) | Native FLOW concrete token via Cadence cross-VM | Current |
| [`@openjanus/janus-erc20`](./packages/janus-erc20) | ERC20-wrapping confidential token on Flow EVM | Current |
| [`@openjanus/janus-ft`](./packages/janus-ft) | Any Cadence FungibleToken vault (lab-grade) | Lab |

All four packages are also re-exported by [`@openjanus/sdk`](https://github.com/openjanus/sdk)
as `@openjanus/sdk/tokens` — most apps should import from the SDK rather than
from individual package paths.

---

## Roman mythology naming convention

Every contract in this repo takes the name of a Roman deity associated with
**doors, transitions, keys, and thresholds** — reflecting the cross-VM nature
of the openjanus stack (Cadence + EVM). Janus: the two-faced god of beginnings
who stands at every threshold, looking simultaneously inward (Cadence) and
outward (EVM).

| Name | Deity / Association | Contract | Status |
|---|---|---|---|
| **Janus** | Dual-faced god of beginnings and thresholds | `JanusToken` — Pedersen commitments + Groth16 | Current |
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

Package names use lowercase + hyphen: `@openjanus/janus-token`,
`@openjanus/cardea-vault`, etc.

---

## Quick start

```bash
npm install @openjanus/sdk
```

```typescript
import { JanusFlow } from "@openjanus/sdk/tokens";

const flow = new JanusFlow();
await flow.connectWithSigner(wallet);

// Read the caller's on-chain Pedersen commitment (opaque 256-bit point)
const commitment = await flow.balanceOfCommitment(coaEvmAddress);
// { x: bigint, y: bigint } — BabyJubJub point, not cleartext

// Full wrap / shieldedTransfer / unwrap: see @openjanus/sdk README
```

---

## Deployed contracts (testnet)

### TIER 1 — Primitive contracts (shared, canonical)

| Contract | Network | Address |
|---|---|---|
| BabyJub.sol (unchanged since v0.2) | Flow EVM testnet | `0x27139AFda7425f51F68D32e0A38b7D43BcB0f870` |
| JanusFlow proxy (ERC1967 UUPS, unchanged through all upgrades) | Flow EVM testnet | `0x09A3DCa868EcC39360fDe4E22046eCfcbA5b4078` |

### TIER 2 — Token + verifier contracts (current v0.5.1)

| Contract | Network | Address |
|---|---|---|
| JanusFlow impl v0.5 (`setVerifiers`, 2^128 MAX_WRAP) | Flow EVM testnet | `0xa2607E9EAb1718a2fAf5a1328A7d3a9Aa854efff` |
| AmountDiscloseVerifier v0.5.1 (pot18) | Flow EVM testnet | `0x9c83b2b1EFFD3bd375b9Bee93Cb618005D6A2Dc4` |
| ConfidentialTransferVerifier v0.5.1 (pot18) | Flow EVM testnet | `0x48f791D2a4992F448Cc36F12e5500b6553e969b3` |
| JanusFlow.cdc router | Flow Cadence testnet | `0x5dcbeb41055ec57e` |
| JanusFTCadence | Flow Cadence testnet | `0xbef3c77681c15397` |
| JanusERC20 proxy | Flow EVM testnet | `0xf2C04b1A32B815ac7Ffd87a4C312096592BBCa1e` |
| JanusERC20 impl (v0.4, uses v0.3 verifiers) | Flow EVM testnet | `0x7FE0B05ED77E0540519B6f10DD4b4521e867590D` |
| MockUSDC (test underlying — 6 decimals) | Flow EVM testnet | `0x3e8973dE565743Ef9748779bE377BBE050A13C22` |
| Owner (admin COA, EVM) | Flow EVM testnet | `0x0000000000000000000000022f6b30af48a94787` |

Trusted setup (v0.5.1): Hermez pot18 (200+ contributors) + one named phase-2
contributor + Flow VRF beacon at testnet block `324,226,714`. Full provenance in
`circuits/v0.5.1/CEREMONY-RECORD.json` in the SDK package.

### TIER 3 — Reference app

| Contract | Network | Address |
|---|---|---|
| PrivateTip.cdc (router + impl) | Flow Cadence testnet | `0xb9ac529c14a4c5a1` |

---

## Deprecated addresses (DO NOT USE)

All deprecated addresses are superseded by the UUPS upgrade + `setVerifiers()`
rotation. Amounts privacy was compromised in v0.2 and v0.1.

| Contract | Address | Why deprecated |
|---|---|---|
| AmountDiscloseVerifier v0.3 (pot14) | `0xD0ED3936530258C278f5357C1dB709ad34768352` | replaced by v0.5.1 pot18 verifier |
| ConfidentialTransferVerifier v0.3 (pot14) | `0x84852aF72D2EF2A0A937e8Dae0BFA482E707E39B` | replaced by v0.5.1 pot18 verifier |
| JanusToken v0.2 (ElGamal accumulator) | `0x025efe7e89acdb8F315C804BE7245F348AA9c538` | `shieldedTransfer` leaked cleartext `transferUnits` |
| EncryptConsistencyVerifier v0.2 | `0x0C1e731036f4632CF9620bf6C6BB8204eD3a3B1e` | only consumed by v0.2 proxy |
| DecryptOpenVerifier v0.2 | `0x1c248dA94aab9f4A03005E7944a8b745a6236Dbc` | only consumed by v0.2 proxy |
| JanusToken v0.1 (pre-ceremony) | `0xb12E600fFcde967210cFD81CF9f32bBB6e68a499` | single-contributor lab setup |
| JanusToken v0.1 (pre-scale-fix) | `0xC715b3647536F671Aa25A6B6Ea1d7f5a0b9fA63D` | pre-scale-fix |
| Cadence Pedersen zombie v1 | `0x28fef3d1d6a12800` | Flow protocol cannot remove old contracts |

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

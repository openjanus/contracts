# @openjanus/janus-token

JanusToken — confidential token on Flow EVM using ElGamal-on-BabyJubjub.

Implements an exponential ElGamal accumulator with Groth16-gated operations:
each balance slot stores a homomorphic ciphertext `(C1, C2)` that accumulates
contributions from multiple senders. The recipient decrypts the total without
learning per-sender amounts.

---

## Privacy Model

**What is hidden:**
- Individual tip amounts from each sender (Alice tips 10, Carol tips 25, Dave tips 7 — recipient sees total=42 only)

**What is visible (by design):**
- Sender-recipient pairing: `ConfidentialTransfer(from=Alice, to=Bob)` events
- Wrap amounts: visible in EVM transfer events (unavoidable)
- Unwrap amount: when Bob unwraps, the amount is visible

The privacy guarantee is **IND-CPA under DDH on BabyJubJub**. Bob's view of the
accumulated ciphertext is computationally indistinguishable from a fresh encryption of
the total.

See [PRIVACY.md](./PRIVACY.md) for full cryptographic details.

---

## Canonical Deployment — v0.2.0 (testnet, ceremony-backed)

Trusted setup: Hermez pot14 (200+ contributors) + Flow VRF beacon (testnet block 323555648).
E2E: 27/27 PASS (2026-05-26).

| Contract | Address |
|----------|---------|
| JanusToken (EVM) | `0xb12E600fFcde967210cFD81CF9f32bBB6e68a499` |
| JanusFlow (Cadence) | `0x28fef3d1d6a12800` contract `JanusFlow` (LEGACY v1) |

```cadence
import JanusFlow from 0x28fef3d1d6a12800
```

ZK verifiers (v0.2.0 ceremony-backed):
- `BabyJub.sol`: `0x27139AFda7425f51F68D32e0A38b7D43BcB0f870` (unchanged)
- `EncryptConsistencyVerifier`: `0x0C1e731036f4632CF9620bf6C6BB8204eD3a3B1e`
- `DecryptOpenVerifier`: `0x1c248dA94aab9f4A03005E7944a8b745a6236Dbc`

> **DEPRECATED v0.1.0 addresses (single-contributor lab setup — DO NOT USE):**
> JanusToken `0xC715b3647536F671Aa25A6B6Ea1d7f5a0b9fA63D`,
> EncryptConsistencyVerifier `0x6F8Cc93dd6aA7B3ED0a3DaA75271815558ad9b5C`,
> DecryptOpenVerifier `0x3bB139B5404fD6b152813bC3532367AAa096638b`

See [deployments/DEPLOYMENTS.md](./deployments/DEPLOYMENTS.md) for full deployment record.

---

## Architecture

```
Alice/Carol/Dave (Flow accounts)
    |
    | Flow transaction (signed by each user)
    v
User's COA (at /storage/evm)     <- msg.sender in EVM
    |
    | coa.call() with FLOW value + ZK proof
    v
JanusToken.sol (EVM, chainId 545)
    |
    | babyAdd() point ops        | verifyProof()
    v                            v
BabyJub.sol                 Groth16 Verifiers
(twisted Edwards ops)       (encrypt_consistency, decrypt_open)
```

The Cadence layer (`JanusFlow.cdc`) provides a typed API over the raw calldata
encoding. Off-chain SDK code prepares the ABI-encoded calldata and passes it to
`JanusFlow` functions.

---

## Key Operations

### wrap(to, ct, nonce, publicInputs, encryptProof)
Deposit FLOW and add an encrypted amount to the recipient's accumulator slot.
Requires a valid `encrypt_consistency` Groth16 proof.

### unwrap(amount, recipient, publicInputs, decryptProof)
Prove knowledge of the total in your slot and release FLOW.
Requires a valid `decrypt_open` Groth16 proof.

### registerPubkey(x, y)
Register a BabyJubJub public key for your COA address.
First-time registration only. Use `commitPubkeyRotation` for updates.

### commitPubkeyRotation(newX, newY) / finalizePubkeyRotation()
Two-step key rotation with a 1-hour timelock (testnet) / 7-day (mainnet).

---

## Install

```bash
npm install
# No compilation needed -- artifacts are pre-built
```

To recompile the Solidity:
```bash
npm run compile
```

---

## Test

```bash
# End-to-end multi-user test (requires Flow testnet access + node_modules)
npm run test:e2e
```

The test validates:
1. Alice/Carol/Dave wrap FLOW to Bob with ZK proofs
2. Bob decrypts total=42 (not individual amounts)
3. All fraud cases rejected
4. Pubkey rotation timelock enforced

---

## Trusted Setup

Phase 1 uses `pot14` (lab-grade, 2^14 constraints max).
**Testnet only.** Mainnet requires a Hermez-style ceremony.

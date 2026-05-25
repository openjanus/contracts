# @openjanus/janus-token-v2

JanusToken v2 — ElGamal accumulator-based confidential token with ZK-gated operations.

This is the Phase 3 implementation in the openjanus privacy stack. It supersedes the
Pedersen commitment approach from v1 with an exponential ElGamal + Groth16 scheme that
provides privacy of individual tip amounts while revealing the total to the recipient.

---

## What Changed from v1

| Feature | v1 (JanusToken) | v2 (JanusTokenV2) |
|---------|-----------------|-------------------|
| Cryptographic primitive | Pedersen commitments | Exponential ElGamal on BabyJubJub |
| ZK gating on wrap | No | Yes (encrypt_consistency Groth16) |
| ZK gating on unwrap | Partial | Yes (decrypt_open Groth16) |
| Per-sender replay protection | No | Yes (nonce mapping) |
| Pubkey rotation | No | Yes (1-hour timelock on testnet) |
| Privacy model | Commitment-based | IND-CPA under DDH on BabyJubJub |
| Backward compatible | — | No — fresh deployment required |

---

## Privacy Model

**What is hidden:**
- Individual tip amounts from each sender (Alice tips 10, Carol tips 25, Dave tips 7 — recipient sees total=42 only)

**What is visible (by design):**
- Sender-recipient pairing: `ConfidentialTransfer(from=Alice, to=Bob)` events
- Wrap amounts: visible in EVM Transfer events (unavoidable)
- Unwrap amount: when Bob unwraps, the amount is visible

The privacy guarantee is **IND-CPA under DDH on BabyJubJub**. Bob's view of the
accumulated ciphertext is computationally indistinguishable from a fresh encryption of
the total. He cannot recover the individual sender amounts.

See [PRIVACY.md](./PRIVACY.md) for full cryptographic details.

---

## Canonical Deployment (testnet)

| Contract | Address |
|----------|---------|
| JanusTokenV2 (EVM) | `0xC715b3647536F671Aa25A6B6Ea1d7f5a0b9fA63D` |
| JanusFlowV2 (Cadence) | `0x28fef3d1d6a12800` contract `JanusFlowV2` |

```cadence
import JanusFlowV2 from 0x28fef3d1d6a12800
```

Reused ZK verifiers (do not redeploy):
- `BabyJub.sol`: `0x27139AFda7425f51F68D32e0A38b7D43BcB0f870`
- `EncryptConsistencyVerifier`: `0x6F8Cc93dd6aA7B3ED0a3DaA75271815558ad9b5C`
- `DecryptOpenVerifier`: `0x3bB139B5404fD6b152813bC3532367AAa096638b`

See [deployments/DEPLOYMENTS.md](./deployments/DEPLOYMENTS.md) for full deployment record.

---

## Architecture

```
Alice/Carol/Dave (Flow accounts)
    |
    | Flow transaction (signed by each user)
    v
User's COA (at /storage/evm)     ← msg.sender in EVM
    |
    | coa.call() with FLOW value + ZK proof
    v
JanusTokenV2.sol (EVM, chainId 545)
    |
    | babyAdd() point ops        | verifyProof()
    v                            v
BabyJub.sol                 Groth16 Verifiers
(twisted Edwards ops)       (encrypt_consistency, decrypt_open)
```

The Cadence layer (`JanusFlowV2.cdc`) provides a typed API over the raw calldata
encoding. Off-chain SDK code prepares the ABI-encoded calldata and passes it to
`JanusFlowV2` functions.

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
# No compilation needed — artifacts are pre-built
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
3. All 8 fraud cases rejected
4. Pubkey rotation timelock enforced

---

## Trusted Setup

Phase 1 uses `pot14` (lab-grade, 2^14 constraints max).
**Testnet only.** Mainnet requires a Hermez-style ceremony.

---

## Migration from v1

See [MIGRATION.md](./MIGRATION.md) for instructions on migrating from JanusToken v1.

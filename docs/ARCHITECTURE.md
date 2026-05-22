# Architecture

## Three-tier stack

```
┌─────────────────────────────────────────────────────────────────┐
│  TIER 3  — Apps                                                  │
│  PrivateTip, LetheOrderbook, AuroraReveal, ...                  │
│  Install: npm install github:openjanus/contracts#main           │
└──────────────────────────┬──────────────────────────────────────┘
                           │ imports
┌──────────────────────────▼──────────────────────────────────────┐
│  TIER 2  — openjanus/contracts  (this repo)                     │
│  JanusToken, CardeaVault, PortunusKey, ...                      │
│  Roman-named contracts that compose primitives                  │
└──────────────────────────┬──────────────────────────────────────┘
                           │ imports
┌──────────────────────────▼──────────────────────────────────────┐
│  TIER 1  — openjanus/primitives                                 │
│  @openjanus/babyjub  — BabyJub.sol + TypeScript SDK            │
│  @openjanus/pedersen — PedersenBabyJub.cdc + SDK               │
│  @openjanus/groth16  — Groth16 Verifier + SDK                  │
└─────────────────────────────────────────────────────────────────┘
```

## Cross-VM execution model

Flow has two execution environments that can be called atomically within a single Cadence transaction:

```
Cadence VM                          Flow EVM
──────────────────────────────      ──────────────────────────────
JanusToken.cdc (resource API)  ←→  JanusToken.sol (ERC-7984 state)
  • mint()  → coa.call(mintXY)       • commitments mapping
  • transfer → coa.call(...)         • BabyJub.sol (curve math)
  • balance  ← coa.dryCall(...)      • Groth16Verifier (ZK proof)
```

The Cadence Owned Account (COA) bridges the two worlds:
- Cadence transactions call `coa.call(...)` to invoke EVM contracts
- The COA is the EVM `msg.sender` — openjanus COA at `0x0000...27eb18dc34b9966fd`
- `EVM.encodeABIWithSignature` handles calldata encoding without leaving Cadence

## Package anatomy: @openjanus/janus-token

```
packages/janus-token/
├── contracts/solidity/JanusToken.sol   # EVM state + ZK verification
├── contracts/cadence/JanusToken.cdc    # Cadence resource wrapper
├── src/                                # TypeScript SDK
│   ├── token.ts                        # JanusToken class
│   ├── client.ts                       # FCL + ethers integration
│   └── types.ts                        # Shared types
└── tests/                              # Hardhat + Vitest tests
```

## Commitment scheme

All balances are stored as BabyJubJub Pedersen commitments:

```
C = Pedersen(amount, blinding) = amount*BASE8 + blinding*H
```

Where BASE8 and H are standard circomlib generator points on BabyJubJub.

Transfers are proved with Groth16 (ConfidentialTransferVerifier):
1. `C_old` matches sender's on-chain commitment
2. `C_tx = Pedersen(transfer_amount, transfer_blinding)`
3. `C_new = Pedersen(old_balance - transfer_amount, new_blinding)`
4. `transfer_amount in [0, 2^64)` (range check)
5. `transfer_amount <= old_balance` (underflow prevention)

The recipient's balance is updated homomorphically: `C_recipient_new = babyAdd(C_recipient_old, C_tx)`.

## Gas profile (Flow EVM testnet)

| Operation | Gas |
|-----------|-----|
| `confidentialTransfer` | ~310,000 |
| `mint` | ~55,000 |
| `burn` | ~55,000 |
| `balanceOfCommitment` | ~2,000 |

## EIP-197 pi_b Fp2 swap

snarkjs produces `pi_b` in `(re, im)` order per BN254 convention.
The EVM `ecPairing` precompile (EIP-197) requires `(im, re)` order.
The SDK's `proof.ts` applies this swap automatically. If calling the contract
directly, apply the swap before encoding: `pB = [[b01, b00], [b11, b10]]`.

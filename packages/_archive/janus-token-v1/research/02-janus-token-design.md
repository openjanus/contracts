# JanusToken Design

## Overview

JanusToken is the reference implementation of ERC-7984 on Flow. It combines:

- **BabyJub.sol** — on-chain twisted Edwards arithmetic for homomorphic balance updates
- **ConfidentialTransferVerifier** — Groth16 verifier for the v2 circuit
- **JanusToken.cdc** — Cadence resource wrapper enabling atomic cross-VM calls

## State model

```
commitments: mapping(address => Point)
  - key:   EVM address
  - value: BabyJubJub Pedersen commitment (x, y)
  - zero:  identity (0, 1) — means zero balance

totalSupplyCommitment: Point
  - Homomorphic sum of all individual commitments
  - Identity at deploy
  - Updated on every mint/burn
```

## Operations

### mint

```
mint(address to, Point amountCommitment)
mintXY(address to, uint256 cx, uint256 cy)  // cross-VM friendly
```

Issuer-only. No ZK proof required (issuer is trusted). Updates recipient commitment and total supply via `babyAdd`.

`mintXY` exists because Cadence's `EVM.encodeABIWithSignature` cannot encode Solidity structs — it can only encode primitive types and arrays. The `XY` variant takes coordinates separately.

### confidentialTransfer

```
confidentialTransfer(address to, uint256[6] publicInputs, uint256[8] proof)
```

Called by sender. Requires a Groth16 proof. Public inputs layout:

```
[0] C_old.x  — sender's current commitment x
[1] C_old.y  — sender's current commitment y
[2] C_tx.x   — transfer amount commitment x
[3] C_tx.y   — transfer amount commitment y
[4] C_new.x  — sender's new commitment x
[5] C_new.y  — sender's new commitment y
```

The contract binds `C_old` to the sender's on-chain commitment before calling the verifier — no commitment substitution attacks possible.

Proof encoding: `[pA.x, pA.y, pB[0][0], pB[0][1], pB[1][0], pB[1][1], pC.x, pC.y]` with EIP-197 Fp2 swap applied.

### burn

```
burn(address from, Point amountCommitment)
burnXY(address from, uint256 cx, uint256 cy)
```

Issuer-only. The issuer must know `(amount, blinding)` to produce the correct commitment to subtract. This is safe for redemption flows where the user reveals their amount to the issuer off-chain.

## Primitives integration

JanusToken pins primitive addresses as constructor arguments (immutable). This is safer than hardcoding — the deployer must explicitly provide the correct addresses, and they can never be changed post-deploy.

```solidity
address public immutable verifier;  // Groth16 verifier
address public immutable babyJub;   // BabyJub.sol point arithmetic
```

The pinned testnet addresses:

| Primitive | Address |
|-----------|---------|
| `BabyJub.sol` | `0x2c40513b343B70f2A0B7e6Ad6F997DDa819D6f07` |
| `Groth16Verifier` | `0x0085F286d89af79EC59E27CD0c5CcD1c55f42Cf5` |

## pi_b Fp2 swap

This is a well-known footgun. snarkjs produces:
```
pi_b = [[b00, b01], [b10, b11]]  where b00, b10 are real parts
```

EVM `ecPairing` precompile (EIP-197) expects:
```
[[b01, b00], [b11, b10]]  (imaginary before real)
```

The SDK's `proof.ts` applies this swap automatically. The contract itself cannot detect an incorrectly-swapped proof — the verifier will just return false.

## Gas optimization choices

- `mintXY` and `burnXY` avoid struct ABI encoding (saves ~500 gas in calldata)
- `balanceOfCommitmentXY` returns flat `(uint256, uint256)` for easy Cadence decode
- No storage gaps — contract is not designed for upgrades (immutable primitives)
- No ERC-20 compatibility — pure ERC-7984, no `balanceOf(address) → uint256`

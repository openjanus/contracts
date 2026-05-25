# JanusToken v2 — Privacy Properties

## What is Hidden

**Tip amounts are hidden.** When Alice tips Bob 10 FLOW, Carol tips Bob 25 FLOW, and Dave tips Bob
7 FLOW, an on-chain observer sees:
- The addresses involved in each tip (Alice→Bob, Carol→Bob, Dave→Bob) — VISIBLE by design
- The FLOW amounts locked in each wrap() — VISIBLE via EVM transfer events (unavoidable)
- The ciphertexts: random-looking elliptic curve points — cryptographically opaque

Bob can only learn the total he received (42 FLOW), not the breakdown per sender. This is the
core privacy guarantee.

## What is Visible

The following are intentionally visible:

1. **Sender/recipient pairing**: `ConfidentialTransfer(from=Alice, to=Bob)` — by design
2. **Wrap amounts**: When a user wraps FLOW, the FLOW transfer is visible on the EVM
   (unavoidable — FLOW tokens have standard transfer events)
3. **Unwrap amount**: When Bob unwraps, he receives FLOW and the amount is visible
4. **Pubkey registrations**: Public on-chain registry

This is the "tip relationship privacy, not tip amount privacy" model: observers know WHO tipped
WHO but not HOW MUCH.

## Cryptographic Guarantee

**IND-CPA security under the Decisional Diffie-Hellman (DDH) assumption on BabyJubJub.**

Exponential ElGamal: `C1 = r * G, C2 = v * G + r * PK`

Under DDH, no polynomial-time adversary can distinguish `E(v1)` from `E(v2)` for any
`v1 != v2`. The ciphertext accumulation is homomorphic:
```
E(10) + E(25) + E(7) = E(42)
```
This is computationally indistinguishable from a fresh `E(42)` — Bob has no way to factor out
the individual contributions.

**Bob's privacy guarantee**: Given only his private key and the accumulated slot `(C1, C2)`,
Bob's view is equivalent to having received a single tip of 42 FLOW from an unknown sender.

## Trusted Setup

Phase 1 uses pot14 (lab-grade). Suitable for testnet only.

For mainnet: a Hermez-style powers-of-tau ceremony is required, with the Flow VRF beacon
contributing randomness in the phase 2 contribution. DO NOT deploy to mainnet without ceremony.

## ZK Proof Scheme

- **encrypt_consistency** (Groth16, ~10,233 constraints): Proves a ciphertext is well-formed
  for the recipient's pubkey with value in [0, 2^48)
- **decrypt_open** (Groth16, ~10,233 constraints): Proves knowledge of private key that decrypts
  a ciphertext to a specific claimed value

## Current Limitations

- BSGS range: [0, 2^20) for lab — extend to [0, 2^48) with disk-cached table for production
- No per-user UTXO — accumulator model (total only). UTXO is a separate AurumFlow spike.
- Pubkey rotation reveals to observers that a key change occurred (but not the new key)

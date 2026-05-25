# Changelog

All notable changes to this project will be documented in this file.

---

## [0.1.0] — 2026-05-25

### Added

**@openjanus/janus-token**

- `JanusToken.sol` — ElGamal accumulator-based confidential token with ZK-gated operations:
  - `wrap()` — deposit FLOW + encrypt ciphertext to recipient's slot (requires `encrypt_consistency` Groth16 proof)
  - `unwrap()` — prove decryption of accumulated slot + release FLOW (requires `decrypt_open` Groth16 proof)
  - `confidentialTransfer()` — reassign locked FLOW + accumulate ciphertext (no new FLOW deposit)
  - `registerPubkey()` — register BabyJubJub public key for COA address
  - `commitPubkeyRotation()` / `finalizePubkeyRotation()` — two-step key rotation with 1-hour testnet timelock
  - Per-sender nonce replay protection on all state-changing operations
  - Homomorphic ciphertext accumulation via BabyJub.babyAdd()
  - IND-CPA under DDH on BabyJubJub

- `JanusFlow.cdc` — Cadence wrapper for cross-VM access:
  - Per-user COA pattern: each user's COA is their independent `msg.sender` in JanusToken
  - `wrap()`, `confidentialTransfer()`, `unwrap()`, `registerPubkey()`, `commitRotation()`, `finalizeRotation()`
  - FLOW vault custody managed in Cadence, encrypted accounting in EVM

- Tests:
  - 24/24 multi-user e2e tests PASS (`tests/e2e_multiuser.mjs`)
  - Privacy property confirmed: Bob decrypts total=42, NOT individual amounts (10, 25, 7)
  - All fraud cases rejected: wrong amount, wrong privkey, BSGS boundary, range overflow, premature rotation
  - Pubkey rotation timelock enforced

- Deployed to Flow EVM testnet (canonical openjanus account):
  - `JanusToken.sol`: `0xC715b3647536F671Aa25A6B6Ea1d7f5a0b9fA63D`
  - `JanusFlow.cdc`: `0x28fef3d1d6a12800` (contract name `JanusFlow`)
  - EVM deploy tx: `01f053e10270f79c121b80fa93aafbff3148721e813ef597cded8a683853301b`
  - Cadence deploy tx: `6f5f551f6e7af4def5cd9d7d5098b4c13daff9eaaaf0598c10feddbac0b0e7b5`
  - ZK verifiers: `EncryptConsistencyVerifier` at `0x6F8Cc93dd6aA7B3ED0a3DaA75271815558ad9b5C`, `DecryptOpenVerifier` at `0x3bB139B5404fD6b152813bC3532367AAa096638b`

- Documentation:
  - `PRIVACY.md` — cryptographic guarantees and what is/is not hidden
  - `deployments/DEPLOYMENTS.md` — canonical addresses + all e2e TX hashes

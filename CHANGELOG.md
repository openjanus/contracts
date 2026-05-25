# Changelog

All notable changes to this project will be documented in this file.

---

## [2.0.0] — 2026-05-25

### Added

**@openjanus/janus-token-v2**

- `JanusTokenV2.sol` — ElGamal accumulator-based confidential token with ZK-gated operations:
  - `wrap()` — deposit FLOW + encrypt ciphertext to recipient's slot (requires `encrypt_consistency` Groth16 proof)
  - `unwrap()` — prove decryption of accumulated slot + release FLOW (requires `decrypt_open` Groth16 proof)
  - `confidentialTransfer()` — reassign locked FLOW + accumulate ciphertext (no new FLOW deposit)
  - `registerPubkey()` — register BabyJubJub public key for COA address
  - `commitPubkeyRotation()` / `finalizePubkeyRotation()` — two-step key rotation with 1-hour testnet timelock
  - Per-sender nonce replay protection on all state-changing operations
  - Homomorphic ciphertext accumulation via BabyJub.babyAdd()
  - IND-CPA under DDH on BabyJubJub

- `JanusFlowV2.cdc` — Cadence wrapper for cross-VM access:
  - Per-user COA pattern: each user's COA is their independent `msg.sender` in JanusTokenV2
  - `wrap()`, `confidentialTransfer()`, `unwrap()`, `registerPubkey()`, `commitRotation()`, `finalizeRotation()`
  - FLOW vault custody managed in Cadence, encrypted accounting in EVM
  - Deployed alongside v1 `JanusFlow` at the same Cadence account

- Tests:
  - 24/24 multi-user e2e tests PASS (`tests/e2e_multiuser.mjs`)
  - Privacy property confirmed: Bob decrypts total=42, NOT individual amounts (10, 25, 7)
  - All fraud cases rejected: wrong amount, wrong privkey, BSGS boundary, range overflow, premature rotation
  - Pubkey rotation timelock enforced

- Deployed to Flow EVM testnet (canonical openjanus account):
  - `JanusTokenV2.sol`: `0xC715b3647536F671Aa25A6B6Ea1d7f5a0b9fA63D`
  - `JanusFlowV2.cdc`: `0x28fef3d1d6a12800` (contract name `JanusFlowV2`)
  - EVM deploy tx: `01f053e10270f79c121b80fa93aafbff3148721e813ef597cded8a683853301b`
  - Cadence deploy tx: `6f5f551f6e7af4def5cd9d7d5098b4c13daff9eaaaf0598c10feddbac0b0e7b5`
  - Reused ZK verifiers: `EncryptConsistencyVerifier` at `0x6F8Cc93dd6aA7B3ED0a3DaA75271815558ad9b5C`, `DecryptOpenVerifier` at `0x3bB139B5404fD6b152813bC3532367AAa096638b`

- Documentation:
  - `PRIVACY.md` — cryptographic guarantees and what is/is not hidden
  - `MIGRATION.md` — migration from v1
  - `deployments/DEPLOYMENTS.md` — canonical addresses + all e2e TX hashes

---

## [0.1.0] — 2026-05-24

### Added

**@openjanus/janus-token**

- `JanusToken.sol` — ERC-7984 confidential token contract with dual-mode support:
  - **NATIVE mode** (`underlying = address(0)`): own supply, mint/burn authority is owner
  - **WRAPPER mode** (`underlying = ERC20 address`): wraps an ERC-20 1:1 via `wrap()`/`unwrap()`
  - Both modes support `confidentialTransfer()` with Groth16 ZK proof verification
  - Pinned to openjanus/primitives: BabyJub.sol + Groth16Verifier (do not redeploy)
  - Cross-VM friendly: `mintXY`, `burnXY`, `balanceOfCommitmentXY` avoid struct ABI issues
  - Full NatSpec documentation

- `JanusToken.cdc` — Cadence contract wrapper for cross-VM access:
  - `mintXY(signer, to, cx, cy)` — calls EVM via COA
  - `confidentialTransfer(signer, to, publicInputs, proof)` — calls EVM via COA
  - `balanceXY(account)` — reads EVM state via `EVM.dryCall` (no COA required)
  - `totalSupplyXY()` — reads total supply commitment

- TypeScript SDK (`src/`):
  - `JanusToken` class with unified API for both modes
  - `computeCommitment(value, blinding)` — Pedersen commitment off-chain
  - `generateTransferProof(input)` — Groth16 proof generation with EIP-197 pi_b swap
  - `decryptBalance(commit, blinding, maxValue)` — balance decryption by search
  - `TESTNET_DEPLOYMENT` — canonical deployed addresses
  - Type shims for `circomlibjs` and `snarkjs`

- Tests:
  - 18 Hardhat unit tests (NATIVE mode: T1-T13, WRAPPER mode: T14-T18) — all passing
  - 10 SDK unit tests (commitment algebra) — all passing
  - 5 integration tests against deployed contract — all passing

- Deployed to Flow EVM testnet (NATIVE mode demo instance):
  - `JanusToken.sol`: `0x53F49881A1132FF4F674D2c015e35D5B07Fa1F4A`
  - `JanusToken.cdc`: `0x28fef3d1d6a12800` (contract name `JanusToken`)
  - Deploy tx: `da430e06a5f831505040b284fffdff53fb3bb5c3e2517b3bc1e10e2e2483b291`

- Research docs (`research/`):
  - `01-erc7984-explained.md` — ERC-7984 standard overview
  - `02-janus-token-design.md` — design decisions and gas profile
  - `03-cross-vm-architecture.md` — COA pattern and CU budget
  - `04-mythology.md` — why "Janus" and the naming convention

- Examples (`examples/`):
  - `balance.ts` — read balance commitment
  - `mint.ts` — mint a commitment (NATIVE mode)
  - `transfer.ts` — confidential transfer with proof
  - `deploy-wrapper.ts` — deploy a new JanusToken wrapper instance (for apps like PrivateTip)

---

## Roadmap (future packages — Roman mythology naming)

| Package | Contract | Status |
|---------|----------|--------|
| `@openjanus/cardea-vault` | `CardeaVault` | planned |
| `@openjanus/portunus-key` | `PortunusKey` | planned |
| `@openjanus/limen-bridge` | `LimenBridge` | planned |
| `@openjanus/hekate-mixer` | `HekateMixer` | planned |

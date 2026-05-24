# Changelog

All notable changes to this project will be documented in this file.

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

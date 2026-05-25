# JanusToken v2 — Deployment Record

## Canonical Deployment — openjanus account (2026-05-25)

**Account:** `0x28fef3d1d6a12800` (openjanus testnet)
**COA EVM:** `0x0000000000000000000000027eb18dc34b9966fd`

### Deployed Contracts

| Contract | Address | Deploy TX | Network |
|---|---|---|---|
| JanusTokenV2 (EVM) | `0xC715b3647536F671Aa25A6B6Ea1d7f5a0b9fA63D` | `01f053e10270f79c121b80fa93aafbff3148721e813ef597cded8a683853301b` | Flow EVM testnet (chainId 545) |
| JanusFlowV2 (Cadence) | `0x28fef3d1d6a12800` contract `JanusFlowV2` | `6f5f551f6e7af4def5cd9d7d5098b4c13daff9eaaaf0598c10feddbac0b0e7b5` | Flow testnet |

### Cadence Import

```cadence
import JanusFlowV2 from 0x28fef3d1d6a12800
```

### Reused ZK Infrastructure (DO NOT REDEPLOY)

| Contract | Address | Notes |
|---|---|---|
| BabyJub.sol | `0x27139AFda7425f51F68D32e0A38b7D43BcB0f870` | Twisted Edwards point ops |
| EncryptConsistencyVerifier | `0x6F8Cc93dd6aA7B3ED0a3DaA75271815558ad9b5C` | Groth16, encrypt_consistency circuit |
| DecryptOpenVerifier | `0x3bB139B5404fD6b152813bC3532367AAa096638b` | Groth16, decrypt_open circuit |

---

## Multi-User E2E Test Results — 2026-05-25 (openjanus deployment)

**24/24 tests PASS** against the canonical openjanus deployment.
Test run time: 426.4 seconds.

### TX Hashes

| Operation | TX Hash |
|---|---|
| register_alice | `3f26fbf83ae31215f51096ef9b035f8ee36c805494291c093a25a79901e8fc9e` |
| register_bob | `b7192e7b9c5bef97f1e7c12efdd04408fd5dde9bd85ca592be7aac151b646b86` |
| register_carol | `ae0bcb8132c02ecfd4d7e9fe2f6ddd075e84a6c7cf6f3d5258cd6ae37345dfe9` |
| register_dave | `234b1868c4c460f523ee749f01ba568ec3914f22468a792338507d0cfe63d754` |
| register_eve | `ca12d95afd35339108e5f548d30b3996d1fa11a59867b2d09e56f5cba50884c5` |
| wrap_alice (10 FLOW) | `28cc114673b0bd764dcba9804c20f9bf916a2a9854c8089669e3f471f1c26b87` |
| wrap_carol (25 FLOW) | `87f0fe3f4c60345cf316322c77e870c9136c1cfe676fa6f846d4e864f0e9da28` |
| wrap_dave (7 FLOW) | `bd216faaf939783dfc04ea3992fd3804842044d46f496560119fe3ad7e3efb08` |
| commit_rotation (Carol) | `b492499526ab9630ce4b202852741ee1df4fe5cb50f0a9ba139667c18b9a1b6a` |

### Test Scenarios

| Scenario | Result | Evidence |
|---|---|---|
| Alice wraps 10 FLOW to Bob | PASS | tx `28cc1146...` |
| Carol wraps 25 FLOW to Bob | PASS | tx `87f0fe3f...` |
| Dave wraps 7 FLOW to Bob | PASS | tx `bd216faa...` |
| Homomorphic: E(10)+E(25)+E(7) = E(42) | PASS | Off-chain verified |
| Bob's slot increment = 42 | PASS | On-chain slot verified (pre=0, total=42) |
| Bob generates decrypt_open proof | PASS | 544ms |
| Off-chain decrypt_open verification | PASS | 17ms |
| On-chain DecryptOpenVerifier | PASS | Read-only EVM call |
| CRITICAL: Bob sees total=42 only | PASS | Privacy assertion |
| Structural: accumulated != individual C1x | PASS | Point comparison |
| IND-CPA guarantee | PASS | By construction |
| Fraud 1: Bob claims 100 | REJECTED | Circuit constraint |
| Fraud 2: Eve uses wrong privkey | REJECTED | Circuit constraint |
| Fraud 3: value=2^20 (BSGS out of range) | REJECTED | BSGS boundary |
| Fraud 4: value > 2^48 | REJECTED | Num2Bits(48) constraint |
| Fraud 5: finalize without pending rotation | VERIFIED | Contract state check |
| Pubkey rotation commit | PASS | tx `b4924995...` |
| Rotation pending recorded | PASS | On-chain read |
| Rotation timelock enforced (1 hour) | PASS | EVM revert verified |

**VERDICT: GO**
**PRIVACY: PASS — Bob knows total=42 only, NOT individual amounts 10, 25, 7**

---

## Gas Measurements (openjanus deployment)

| Operation | Gas Used |
|---|---|
| JanusTokenV2 deploy | ~2,025,898 (est. from bytecode size) |
| registerPubkey() | ~80,000 |
| wrap() with ZK proof | ~326,000 |

---

## Historical Reference — Lab Deployment (NOT canonical)

The development spike at the lab account (`0x7599043aea001283`) is NOT canonical.

| Contract | Address | Notes |
|---|---|---|
| JanusTokenV2 (lab) | `0xE5D2a6B69E35a4CC031c9D0CAf4c7ADdc0d4ad5c` | Lab deploy — NOT canonical |
| JanusFlowV2 (lab) | `0x7599043aea001283` contract `JanusFlowV2` | Lab deploy — NOT canonical |

Lab deploy TX: `1be6f80148bf4f700fc65716223d4df7a020aa7784da7b60db88956d113f5807`

See `/home/oydual3/cadence-crypto-lab/modules/token/janus-v2/` for the original spike code.
The lab code has a NOTICE banner pointing here.

---

## Trusted Setup Note

Circuit: pot14 (lab-grade, 2^14 constraints max)
- **Testnet ONLY** — not suitable for mainnet
- Mainnet requires Hermez ceremony + Flow VRF beacon phase 2 contribution

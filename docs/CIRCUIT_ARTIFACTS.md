# Circuit Artifacts — Strategy and Location

## Strategy: Option C (Reference path + documentation)

Circuit binary files (`.wasm`, `.zkey`) are NOT included in this repository.
They are large (`.zkey` is ~150MB for this circuit) and not suitable for Git.

**Current location**: Private repository `cadence-crypto-lab` at:
```
modules/zk/confidential-transfer-circuit/
  circuit/build/confidential_transfer_js/confidential_transfer.wasm
  setup/confidential_transfer_final.zkey
  setup/verification_key.json
```

**For tests**: Set `CIRCUIT_ROOT` environment variable:
```bash
export CIRCUIT_ROOT=/path/to/cadence-crypto-lab/modules/zk/confidential-transfer-circuit
node tests/janus_e2e.mjs
```

**Default**: The test assumes `cadence-crypto-lab` is a sibling of `zk-prop`:
```
/home/user/
  zk-prop/          (this repo)
  cadence-crypto-lab/  (private lab, must be cloned separately)
```

## Regenerating artifacts

If you need to regenerate the circuit artifacts (e.g., after circuit changes):

```bash
cd cadence-crypto-lab/modules/zk/confidential-transfer-circuit
npm install
npm run compile   # circom → .wasm + .r1cs
npm run setup     # Powers of Tau + zkey generation (takes ~10 min)
```

The trusted setup uses hermez Powers of Tau (pot13), which is acceptable for
testnet but NOT for production. A proper multi-party ceremony is required for
mainnet deployment.

## Verification key

`setup/verification_key.json` is included in the private lab and IS suitable
for version control (it's a small JSON file with curve parameters).

The EVM verifier (`ConfidentialTransferVerifier.sol`) was generated from this
verification key using `snarkjs zkey export solidityverifier`.

## Circuit specification

Circuit: `confidential_transfer.circom`
- Template: BabyJubJub Pedersen commitments (192-bit input: 64-bit value + 128-bit blinding)
- Constraints: 7,975
- Public inputs: [C_old.x, C_old.y, C_tx.x, C_tx.y, C_new.x, C_new.y]
- Private inputs: old_value, old_blinding, transfer_value, transfer_blinding, new_blinding
- Range checks: 64-bit value range (Num2Bits), transfer <= old_value (LessEqThan)

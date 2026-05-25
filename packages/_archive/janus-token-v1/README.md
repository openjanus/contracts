# @openjanus/janus-token

**JanusToken** — ERC-7984 confidential token on Flow, named after the dual-faced Roman god of beginnings and thresholds.

Like Janus, who looks simultaneously forward and backward through doorways, JanusToken faces two worlds at once: **Flow EVM** (where the cryptography lives) and **Cadence** (where Flow-native apps call it). A single token standard bridges both.

---

## What it is

JanusToken is a **fully private token** where no balance is ever revealed on-chain. Every balance is stored as a BabyJubJub Pedersen commitment. Transfers are proved with Groth16 ZK proofs.

- No amount is visible in any transfer event
- Balance lookups return a commitment point — only the holder can decrypt it
- Homomorphic arithmetic: recipient balances update on-chain without revealing amounts
- ERC-7984 (Draft May 2026) compliant

## ERC-7984 alignment

| ERC-7984 method | JanusToken method |
|-----------------|-------------------|
| `confidentialMint(to, commit)` | `mint(to, amountCommitment)` / `mintXY(to, cx, cy)` |
| `confidentialTransfer(to, proof, inputs)` | `confidentialTransfer(to, publicInputs, proof)` |
| `confidentialBalance(account)` | `balanceOfCommitment(account)` / `balanceOfCommitmentXY(account)` |
| `confidentialBurn(from, commit)` | `burn(from, amountCommitment)` / `burnXY(from, cx, cy)` |

---

## TypeScript SDK

The TypeScript SDK has been consolidated into [`@openjanus/sdk`](https://github.com/openjanus/sdk).

```bash
npm install @openjanus/sdk
```

```typescript
import { JanusToken, JANUS_TOKEN_TESTNET } from "@openjanus/sdk";

const token = new JanusToken(JANUS_TOKEN_TESTNET);
await token.connect();

// Read balance commitment (no amount revealed)
const commit = await token.balanceOfCommitment("0xYourAddress");

// Decrypt your balance (requires your secret blinding factor)
const balance = await token.decryptBalance(commit, yourBlindingFactor);

// Confidential transfer (SDK handles Pedersen + Groth16 proof generation)
await token.confidentialTransfer({
  recipient: "0xRecipientAddress",
  amount: 100n,
  blinding: yourBlindingFactor,
  newBlinding: newBlindingFactor,
  wasmPath: "/path/to/confidential_transfer.wasm",
  zkeyPath: "/path/to/confidential_transfer_final.zkey",
});
```

---

## Deployed addresses

| Contract | Address |
|----------|---------|
| `JanusToken.sol` (Flow EVM testnet) | see [deployments/testnet.json](./deployments/testnet.json) |
| `JanusToken.cdc` (Flow testnet) | `0x28fef3d1d6a12800` |

---

## Primitives (pinned, do not redeploy)

| Primitive | Address |
|-----------|---------|
| `BabyJub.sol` | `0x2c40513b343B70f2A0B7e6Ad6F997DDa819D6f07` |
| `Groth16Verifier` | `0x0085F286d89af79EC59E27CD0c5CcD1c55f42Cf5` |

---

## Janus mythology

Janus is the Roman god of beginnings, transitions, doorways, and time. He is depicted with two faces: one looking to the past, one to the future. He guards every threshold — physical and temporal.

In Roman mythology, no ceremony could begin, no battle be joined, no new year start, without Janus being invoked first. The doors of his temple in the Forum were opened during wartime and closed only in times of peace.

JanusToken inherits this dual nature: it simultaneously speaks EVM (via Solidity + Groth16) and Cadence (via the COA resource wrapper). It stands at the threshold between the two execution environments on Flow.

The `@openjanus` naming convention follows this pattern: every contract is a Roman deity whose domain maps onto the contract's purpose.

---

## License

MIT

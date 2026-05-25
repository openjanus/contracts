# JanusToken Privacy Properties — v1

## Privacy properties (v1)

JanusToken v1 provides:

**Amount privacy** — Transfer amounts are cryptographically hidden using
Pedersen commitments + Groth16 ZK proofs. No observer can determine how
much was transferred without the (value, blinding) pair.

**NOT yet provided in v1**:
- Sender identity: visible on-chain (the wallet that signed the tx)
- Recipient identity: visible on-chain (the destination EVM address)
- Transaction graph: who interacted with whom is observable

For full anonymity (hiding identities + amounts), future versions will
integrate:
- **v2 — Stealth addresses** (ERC-5564 pattern): hides recipient identity
- **v3 — Relayer/burner wallets**: hides sender identity

Today, JanusToken is the right primitive for use cases where AMOUNT
hiding matters more than identity hiding: anti-MEV, anti-value-extraction,
private balance tracking, confidential payment amounts.

## What the ZK proof guarantees

The Groth16 proof (ConfidentialTransfer v2 circuit) proves simultaneously:

1. `old_commit == Pedersen(old_value, old_blinding)` — sender holds the private key to their current balance
2. `transfer_commit == Pedersen(transfer_value, transfer_blinding)` — the transfer amount is committed
3. `new_commit == Pedersen(old_value - transfer_value, new_blinding)` — conservation: balance decreases by transfer amount
4. `transfer_value in [0, 2^64)` — range check prevents overflow attacks
5. `transfer_value <= old_value` — underflow prevention (no negative balances)

What the proof does NOT prove:
- Who the sender is (EVM msg.sender is not in the circuit)
- Who the recipient is (not in the circuit)

## What remains observable on-chain

Any observer of the testnet/mainnet can see:

- The **Cadence account** that signed the transaction (signer field)
- The **EVM address** of the recipient (argument to confidentialTransfer)
- **When** the transfer happened (block timestamp)
- **That a transfer occurred** (ConfidentialTransfer event emitted)
- **Gas cost** of the operation (~310,000 gas for confidentialTransfer)

What they CANNOT see:
- Transfer amount (hidden in Pedersen commitment)
- Sender's remaining balance (updated commitment reveals nothing without blinding factor)
- Receiver's total balance

## JanusFlow wrapper — additional considerations

JanusFlow (FLOW wrapper) adds one more observable:

- The **FLOW amount** deposited on wrap is visible (FlowToken.TokensWithdrawn event)
- The **FLOW amount** released on unwrap is visible (FlowToken.TokensDeposited event)

This means that for JanusFlow, observers can track the total FLOW entering and
leaving the wrapper, even if individual transfers are hidden.

**v1 is suitable for**: hiding payment amounts between parties who know each other,
preventing MEV bots from knowing exact trade sizes, internal accounting.

**v1 is NOT suitable for**: hiding that parties interacted, transaction graph
analysis resistance, or mixer-style anonymity.

## Circuit artifacts

Circuit: `confidential_transfer.circom` (BabyJubJub Pedersen, Groth16)
Constraints: 7,975
Trusted setup: hermez pot13 ceremony (multi-party, acceptable for testnet)

Artifacts location strategy: **Option C (GitHub Releases)**
- `.wasm` and `.zkey` files are excluded from the source repo (too large for Git)
- They are available at: `cadence-crypto-lab` private repository
- For production: publish as GitHub Release assets on openjanus/primitives

## Version roadmap

| Version | Feature | Status |
|---------|---------|--------|
| v1 | Amount privacy (Pedersen + Groth16) | Deployed on testnet |
| v2 | Recipient privacy (ERC-5564 stealth addresses) | Planned |
| v3 | Sender privacy (relayer pattern) | Planned |
| v4 | Mixer-style (nullifiers + Merkle roots) | Research |

# ERC-7984 Explained

ERC-7984 is a draft Ethereum token standard (proposed May 2026) for **always-private fungible tokens** — tokens where no balance is ever visible on-chain, not even in logs.

## Why ERC-20 is not private

An ERC-20 transfer emits:

```
Transfer(address indexed from, address indexed to, uint256 value)
```

Anyone watching the chain can see the amount, sender, and recipient. Even with private addresses, the graph of amounts is fully public. This is inadequate for:

- Payroll and compensation
- Medical payments
- Sealed-bid auctions
- Treasury management
- Personal spending

## The ERC-7984 approach

ERC-7984 replaces cleartext amounts with **Pedersen commitments** — cryptographic commitments that are:
- **Hiding**: the commitment reveals nothing about the amount
- **Binding**: the committer cannot change the amount after committing

A Pedersen commitment on BabyJubJub is:

```
C = Pedersen(amount, blinding) = amount * BASE8 + blinding * H
```

Where BASE8 and H are orthogonal generators (nobody knows the discrete log between them).

## Transfer without revealing amounts

To transfer `v` tokens from Alice to Bob:

1. Alice computes three commitments off-chain:
   - `C_old = Pedersen(alice_balance, alice_blinding)`  — her current balance
   - `C_tx  = Pedersen(v, tx_blinding)`               — the transfer amount
   - `C_new = Pedersen(alice_balance - v, new_blinding)` — her new balance

2. Alice generates a Groth16 ZK proof that:
   - `C_old` matches her on-chain commitment
   - `C_tx` and `C_new` are consistent with subtraction
   - `v` is in `[0, 2^64)` (range proof)
   - `v <= alice_balance` (no underflow)

3. The contract verifies the proof and:
   - Updates Alice's commitment to `C_new`
   - Updates Bob's commitment to `babyAdd(C_bob_old, C_tx)` (homomorphic addition)

4. The event emitted is just `ConfidentialTransfer(from, to)` — **no amount**.

## Homomorphic addition

BabyJubJub commitments support additive homomorphism:

```
Pedersen(a, r1) + Pedersen(b, r2) = Pedersen(a + b, r1 + r2)
```

This is why Bob's balance update is just a point addition — no ZK proof needed for the recipient side.

## ERC-7984 interface

```solidity
interface IERC7984 {
    event ConfidentialTransfer(address indexed from, address indexed to);
    event ConfidentialMint(address indexed to, uint256 commit_x, uint256 commit_y);
    event ConfidentialBurn(address indexed from, uint256 commit_x, uint256 commit_y);

    function balanceOfCommitment(address account) external view returns (Point memory);
    function confidentialTransfer(
        address to,
        uint256[6] calldata publicInputs,
        uint256[8] calldata proof
    ) external;
    function mint(address to, Point calldata amountCommitment) external;
    function burn(address from, Point calldata amountCommitment) external;
}
```

## Security assumptions

| Assumption | Implication |
|------------|-------------|
| Discrete log on BabyJubJub is hard | Commitments are hiding |
| Pedersen is binding | Committer cannot change amount after commit |
| Groth16 is sound | Proof cannot be forged for invalid transfers |
| BN254 pairing is secure | Groth16 verification is sound |
| Issuer is trusted | Mint does not require a proof |

## Limitations vs ERC-20

- Minting requires the issuer to know `(amount, blinding)` — no anonymous minting
- Burning requires the issuer to know the commitment — burn must be coordinated
- Transfer amount is private only to observers; the sender and recipient both know it
- The circuit's range limit is 64 bits (max balance ≈ 1.8 × 10¹⁹)

// SPDX-License-Identifier: MIT
//
// JanusToken.sol — ERC-7984 Confidential Token
//
// Named after Janus, the dual-faced Roman god of beginnings and thresholds.
// Like Janus, this token stands between two worlds: Flow EVM (Solidity) and
// Cadence — both faces visible simultaneously through the COA bridge.
//
// Always-private confidential token on Flow EVM using:
//   - BabyJubJub Pedersen commitments for hidden balances
//   - Groth16 ZK proofs (ConfidentialTransferVerifier) enforcing commitment
//     consistency, 64-bit range check, and underflow prevention
//   - BabyJub.sol for on-chain point arithmetic (homomorphic balance updates)
//
// ERC-7984 (Draft, May 2026) alignment:
//   confidentialMint(to, commit)            → mint(to, amountCommitment)
//   confidentialTransfer(to, proof, inputs) → confidentialTransfer(to, publicInputs, proof)
//   confidentialBalance(account)            → balanceOfCommitment(account)
//   confidentialBurn(from, commit)          → burn(from, amountCommitment)
//
// Deployed primitives (Flow EVM testnet — canonical, do NOT redeploy):
//   @openjanus/groth16 Verifier: 0x0085F286d89af79EC59E27CD0c5CcD1c55f42Cf5
//   @openjanus/babyjub BabyJub:  0x2c40513b343B70f2A0B7e6Ad6F997DDa819D6f07
//
// Circuit public input layout (uint256[6]):
//   [0] C_old.x   — sender's old balance commitment x-coordinate
//   [1] C_old.y   — sender's old balance commitment y-coordinate
//   [2] C_tx.x    — transfer amount commitment x-coordinate
//   [3] C_tx.y    — transfer amount commitment y-coordinate
//   [4] C_new.x   — sender's new balance commitment x-coordinate
//   [5] C_new.y   — sender's new balance commitment y-coordinate
//
// pi_b Fp2 swap (EIP-197):
//   snarkjs proof.pi_b comes as (re, im) per BN254 standard.
//   EVM ecPairing precompile (EIP-197) requires (im, re) order.
//   The caller MUST apply the swap before calling confidentialTransfer.
//   SDK helper: src/proof.ts applies this automatically.
//
// Gas profile (measured on Flow EVM testnet):
//   confidentialTransfer:  ~310,000 gas (253k verify + 35k babyAdd×2 + storage)
//   mint:                  ~55,000  gas (one babyAdd + two SSTORE)
//   burn:                  ~55,000  gas (one babyAdd negate + two SSTORE)
//   balanceOfCommitment:   ~2,000   gas (two SLOAD)
//
// @openjanus/contracts — TIER 2 — built on top of @openjanus/primitives (TIER 1)
// Part of the openjanus Roman mythology naming convention.

pragma solidity ^0.8.20;

// ---------------------------------------------------------------------------
// Interfaces for deployed @openjanus/primitives
// ---------------------------------------------------------------------------

/// @notice Interface to @openjanus/groth16 ConfidentialTransferVerifier
/// @dev Deployed at 0x0085F286d89af79EC59E27CD0c5CcD1c55f42Cf5 on Flow EVM testnet
interface IConfidentialTransferVerifier {
    /// @notice Verify a Groth16 proof for the ConfidentialTransfer v2 circuit.
    /// @param _pA      pi_a: G1 point [x, y]
    /// @param _pB      pi_b: G2 point [[im0, re0], [im1, re1]] (EIP-197 Fp2 swap applied)
    /// @param _pC      pi_c: G1 point [x, y]
    /// @param _pubSignals  6 public inputs: [C_old.x, C_old.y, C_tx.x, C_tx.y, C_new.x, C_new.y]
    /// @return bool    true if proof is valid
    function verifyProof(
        uint[2] calldata _pA,
        uint[2][2] calldata _pB,
        uint[2] calldata _pC,
        uint[6] calldata _pubSignals
    ) external view returns (bool);
}

/// @notice Interface to @openjanus/babyjub BabyJub.sol
/// @dev Deployed at 0x2c40513b343B70f2A0B7e6Ad6F997DDa819D6f07 on Flow EVM testnet
interface IBabyJub {
    /// @notice Twisted Edwards point addition on BabyJubJub.
    /// @dev Identity: (0, 1). The addition law is unified (handles all cases including identity).
    /// @param x1  x-coordinate of first point (must be < P)
    /// @param y1  y-coordinate of first point
    /// @param x2  x-coordinate of second point
    /// @param y2  y-coordinate of second point
    /// @return x3 x-coordinate of result
    /// @return y3 y-coordinate of result
    function babyAdd(
        uint256 x1, uint256 y1,
        uint256 x2, uint256 y2
    ) external view returns (uint256 x3, uint256 y3);

    /// @notice Negate a BabyJubJub point. negate(x, y) = (P - x mod P, y).
    /// @param x  x-coordinate
    /// @param y  y-coordinate
    /// @return nx negated x (= P - x for x != 0, else 0)
    /// @return ny negated y (= y unchanged)
    function negate(uint256 x, uint256 y) external pure returns (uint256 nx, uint256 ny);

    /// @notice Return the identity element (0, 1).
    function identity() external pure returns (uint256 x, uint256 y);
}

// ---------------------------------------------------------------------------
// JanusToken — ERC-7984 Confidential Token
// ---------------------------------------------------------------------------

/// @title JanusToken
/// @author openjanus
/// @notice Always-private confidential token implementing ERC-7984 on Flow EVM.
///         Balances are stored as BabyJubJub Pedersen commitments — no amount is
///         ever revealed on-chain. Transfers are verified with Groth16 ZK proofs.
/// @dev Named after Janus, the dual-faced Roman god of doorways and beginnings,
///      reflecting this token's dual nature across Flow EVM and Cadence.
///      Part of the @openjanus Roman mythology naming convention.
///      This is TIER 2 — built on @openjanus/primitives (TIER 1).
contract JanusToken {

    // -----------------------------------------------------------------------
    // Curve-aligned point struct — BabyJubJub (x, y) over BN254 scalar field
    // Identity element: (0, 1)
    // -----------------------------------------------------------------------

    /// @notice A point on the BabyJubJub twisted Edwards curve.
    /// @dev Identity element is (0, 1). All arithmetic uses @openjanus/babyjub BabyJub.sol.
    struct Point {
        uint256 x;
        uint256 y;
    }

    // -----------------------------------------------------------------------
    // Immutable primitive addresses (pinned at deploy, never updatable)
    // -----------------------------------------------------------------------

    /// @notice @openjanus/groth16 ConfidentialTransferVerifier — Groth16 verifier for the v2 circuit.
    /// @dev Pinned as immutable. Deployed at 0x0085F286d89af79EC59E27CD0c5CcD1c55f42Cf5.
    address public immutable verifier;

    /// @notice @openjanus/babyjub BabyJub.sol — twisted Edwards point arithmetic.
    /// @dev Pinned as immutable. Deployed at 0x2c40513b343B70f2A0B7e6Ad6F997DDa819D6f07.
    address public immutable babyJub;

    // -----------------------------------------------------------------------
    // Token state
    // -----------------------------------------------------------------------

    /// @notice Hidden balance commitments — BabyJubJub Pedersen points, one per address.
    /// @dev Zero balance is represented as the identity element (0, 1).
    ///      Uninitialized storage reads as (0, 0) — callers should use balanceOfCommitment()
    ///      which normalizes (0, 0) to the identity (0, 1).
    ///      The amount is never revealed. Only the holder (who knows their blinding factor)
    ///      can decrypt their balance off-chain.
    mapping(address => Point) public commitments;

    /// @notice Homomorphic sum of all individual balance commitments.
    /// @dev Invariant: totalSupplyCommitment == sum(commitments[addr] for all addr).
    ///      Identity (0, 1) at deploy — zero total supply.
    ///      Updated on every mint and burn.
    Point public totalSupplyCommitment;

    /// @notice Issuer/admin — sole authority for mint and burn.
    /// @dev Set to msg.sender at deploy. Immutable — no transfer path.
    address public immutable owner;

    // -----------------------------------------------------------------------
    // Events (ERC-7984 aligned)
    // -----------------------------------------------------------------------

    /// @notice Emitted on mint. Commitment coordinates are the recipient's updated commitment.
    /// @dev new_commit_x/y is the recipient's new Pedersen commitment after the mint.
    event ConfidentialMint(
        address indexed to,
        uint256 new_commit_x,
        uint256 new_commit_y
    );

    /// @notice Emitted on confidential transfer. No amount is revealed.
    /// @dev Observers learn only that a transfer occurred between these two addresses.
    event ConfidentialTransfer(
        address indexed from,
        address indexed to
    );

    /// @notice Emitted on burn. Commitment coordinates are the account's updated commitment.
    event ConfidentialBurn(
        address indexed from,
        uint256 new_commit_x,
        uint256 new_commit_y
    );

    // -----------------------------------------------------------------------
    // Constructor
    // -----------------------------------------------------------------------

    /// @notice Deploy JanusToken.
    /// @dev Both primitive addresses are pinned as immutable — no update path exists.
    ///      Pass the canonical @openjanus/primitives testnet addresses:
    ///        _verifier = 0x0085F286d89af79EC59E27CD0c5CcD1c55f42Cf5
    ///        _babyJub  = 0x2c40513b343B70f2A0B7e6Ad6F997DDa819D6f07
    /// @param _verifier  @openjanus/groth16 ConfidentialTransferVerifier address
    /// @param _babyJub   @openjanus/babyjub BabyJub.sol address
    constructor(address _verifier, address _babyJub) {
        require(_verifier != address(0), "JanusToken: zero verifier address");
        require(_babyJub  != address(0), "JanusToken: zero babyJub address");

        verifier = _verifier;
        babyJub  = _babyJub;
        owner    = msg.sender;

        // totalSupplyCommitment starts at identity (0, 1) — zero total supply
        totalSupplyCommitment = Point({ x: 0, y: 1 });
    }

    // -----------------------------------------------------------------------
    // Access control
    // -----------------------------------------------------------------------

    modifier onlyOwner() {
        require(msg.sender == owner, "JanusToken: caller is not owner");
        _;
    }

    // -----------------------------------------------------------------------
    // View functions
    // -----------------------------------------------------------------------

    /// @notice Return an account's balance commitment.
    /// @dev This is the ERC-7984 `confidentialBalance` equivalent.
    ///      The returned (x, y) point is a BabyJubJub Pedersen commitment:
    ///        C = Pedersen(balance, blinding) — only the holder knows balance + blinding.
    ///      Identity (0, 1) means zero balance.
    ///      Uninitialized storage is (0, 0); this function normalizes to (0, 1).
    /// @param account Address to query
    /// @return Point BabyJubJub commitment — reveals nothing about the balance amount
    function balanceOfCommitment(address account) external view returns (Point memory) {
        Point memory c = commitments[account];
        if (c.x == 0 && c.y == 0) {
            return Point({ x: 0, y: 1 });
        }
        return c;
    }

    /// @notice Return balance commitment as flat (x, y) pair for cross-VM decoding.
    /// @dev Cadence can decode this directly:
    ///        EVM.decodeABI(types: [Type<UInt256>(), Type<UInt256>()], data: result.data)
    ///      Avoids struct ABI encoding incompatibility with Cadence.
    /// @param account Address to query
    /// @return x Commitment x-coordinate (0 for identity)
    /// @return y Commitment y-coordinate (1 for identity)
    function balanceOfCommitmentXY(address account) external view returns (uint256 x, uint256 y) {
        Point memory c = commitments[account];
        if (c.x == 0 && c.y == 0) {
            return (0, 1);
        }
        return (c.x, c.y);
    }

    // -----------------------------------------------------------------------
    // confidentialTransfer — ERC-7984 core operation
    // -----------------------------------------------------------------------

    /// @notice Transfer a hidden amount from msg.sender to `to`.
    /// @dev The caller provides a Groth16 proof demonstrating:
    ///        1. C_old matches the sender's current on-chain commitment.
    ///        2. C_tx is a valid Pedersen commitment to the transfer amount.
    ///        3. C_new = Pedersen(old_balance - tx_amount, new_blinding).
    ///        4. tx_amount is in [0, 2^64) (range proof via Num2Bits).
    ///        5. tx_amount <= old_balance (underflow prevention via LessEqThan).
    ///
    ///      On success:
    ///        - sender's commitment becomes C_new (publicInputs[4..5])
    ///        - recipient's commitment updates homomorphically: C_recv + C_tx
    ///
    ///      Proof pi_b MUST have EIP-197 Fp2 swap applied (sdk/proof.ts does this).
    ///
    /// @param to           Recipient address (must not be zero or sender)
    /// @param publicInputs [C_old.x, C_old.y, C_tx.x, C_tx.y, C_new.x, C_new.y]
    /// @param proof        Groth16 proof encoded as [pA.x, pA.y, pB[0][0], pB[0][1],
    ///                     pB[1][0], pB[1][1], pC.x, pC.y] (8 elements, pi_b Fp2-swapped)
    function confidentialTransfer(
        address to,
        uint256[6] calldata publicInputs,
        uint256[8] calldata proof
    ) external {
        require(to != address(0), "JanusToken: transfer to zero address");
        require(to != msg.sender, "JanusToken: cannot transfer to self");

        // 1. Bind C_old to the sender's on-chain commitment (prevents substitution attacks)
        Point memory senderCommit = _effectiveCommitment(msg.sender);
        require(
            publicInputs[0] == senderCommit.x && publicInputs[1] == senderCommit.y,
            "JanusToken: C_old mismatch — publicInputs[0..1] must equal sender commitment"
        );

        // 2. Verify Groth16 proof via @openjanus/groth16 ConfidentialTransferVerifier
        uint[2] memory pA  = [proof[0], proof[1]];
        uint[2][2] memory pB = [[proof[2], proof[3]], [proof[4], proof[5]]];
        uint[2] memory pC  = [proof[6], proof[7]];
        uint[6] memory pub = [
            publicInputs[0], publicInputs[1],
            publicInputs[2], publicInputs[3],
            publicInputs[4], publicInputs[5]
        ];

        bool valid = IConfidentialTransferVerifier(verifier).verifyProof(pA, pB, pC, pub);
        require(valid, "JanusToken: ZK proof verification failed");

        // 3. Update sender commitment to C_new (publicInputs[4..5])
        commitments[msg.sender] = Point({ x: publicInputs[4], y: publicInputs[5] });

        // 4. Add C_tx to recipient commitment homomorphically via @openjanus/babyjub
        //    recipient_new = babyAdd(recipient_old, C_tx)
        Point memory recipientCommit = _effectiveCommitment(to);
        (uint256 rx, uint256 ry) = IBabyJub(babyJub).babyAdd(
            recipientCommit.x, recipientCommit.y,
            publicInputs[2], publicInputs[3]
        );
        commitments[to] = Point({ x: rx, y: ry });

        emit ConfidentialTransfer(msg.sender, to);
    }

    // -----------------------------------------------------------------------
    // mint — issuer only
    // -----------------------------------------------------------------------

    /// @notice Mint a hidden amount to `to`.
    /// @dev The issuer computes `amountCommitment = Pedersen(amount, blinding)` off-chain
    ///      and submits the resulting BabyJubJub point. No ZK proof is required for mint
    ///      because the issuer is a trusted authority (same trust model as ERC-20 mint).
    ///
    ///      On success:
    ///        - recipient's commitment: C_recv_new = babyAdd(C_recv_old, amountCommitment)
    ///        - totalSupplyCommitment:  C_supply_new = babyAdd(C_supply_old, amountCommitment)
    ///
    /// @param to               Recipient address
    /// @param amountCommitment Pedersen(amount, blinding) point — computed off-chain
    function mint(address to, Point calldata amountCommitment) external onlyOwner {
        _mintXY(to, amountCommitment.x, amountCommitment.y);
    }

    /// @notice Cross-VM mint: accepts x and y coordinates directly (avoids struct ABI mismatch).
    /// @dev Call from Cadence via:
    ///        EVM.encodeABIWithSignature("mintXY(address,uint256,uint256)", [to, cx, cy])
    ///      This avoids the struct tuple encoding incompatibility between Solidity and Cadence.
    /// @param to  Recipient address
    /// @param cx  Pedersen commitment x-coordinate
    /// @param cy  Pedersen commitment y-coordinate
    function mintXY(address to, uint256 cx, uint256 cy) external onlyOwner {
        _mintXY(to, cx, cy);
    }

    /// @dev Internal mint logic shared by mint() and mintXY().
    function _mintXY(address to, uint256 cx, uint256 cy) internal {
        require(to != address(0), "JanusToken: mint to zero address");

        // Recipient commitment += amountCommitment
        Point memory current = _effectiveCommitment(to);
        (uint256 nx, uint256 ny) = IBabyJub(babyJub).babyAdd(
            current.x, current.y,
            cx, cy
        );
        commitments[to] = Point({ x: nx, y: ny });

        // Total supply commitment += amountCommitment
        (uint256 tx_, uint256 ty_) = IBabyJub(babyJub).babyAdd(
            totalSupplyCommitment.x, totalSupplyCommitment.y,
            cx, cy
        );
        totalSupplyCommitment = Point({ x: tx_, y: ty_ });

        emit ConfidentialMint(to, nx, ny);
    }

    // -----------------------------------------------------------------------
    // burn — issuer only
    // -----------------------------------------------------------------------

    /// @notice Burn a hidden amount from `from`.
    /// @dev The issuer computes `amountCommitment = Pedersen(amount, blinding)` off-chain.
    ///      The burn subtracts the commitment: C_new = C_old + negate(amountCommitment).
    ///
    ///      Note: the issuer must know (amount, blinding) to produce the correct commitment.
    ///      This is safe for redemption flows where the user reveals their cleartext to
    ///      the issuer off-chain to initiate the burn.
    ///
    /// @param from             Account to burn from
    /// @param amountCommitment Pedersen(amount, blinding) point — commitment to subtract
    function burn(address from, Point calldata amountCommitment) external onlyOwner {
        _burnXY(from, amountCommitment.x, amountCommitment.y);
    }

    /// @notice Cross-VM burn: accepts x and y coordinates directly (avoids struct ABI mismatch).
    /// @dev Call from Cadence via:
    ///        EVM.encodeABIWithSignature("burnXY(address,uint256,uint256)", [from, cx, cy])
    /// @param from  Account to burn from
    /// @param cx    Pedersen commitment x-coordinate
    /// @param cy    Pedersen commitment y-coordinate
    function burnXY(address from, uint256 cx, uint256 cy) external onlyOwner {
        _burnXY(from, cx, cy);
    }

    /// @dev Internal burn logic shared by burn() and burnXY().
    function _burnXY(address from, uint256 cx, uint256 cy) internal {
        require(from != address(0), "JanusToken: burn from zero address");

        // Negate the amount commitment to subtract it
        (uint256 negX, uint256 negY) = IBabyJub(babyJub).negate(cx, cy);

        // Account commitment -= amountCommitment (via addition of negated point)
        Point memory current = _effectiveCommitment(from);
        (uint256 nx, uint256 ny) = IBabyJub(babyJub).babyAdd(
            current.x, current.y,
            negX, negY
        );
        commitments[from] = Point({ x: nx, y: ny });

        // Total supply commitment -= amountCommitment
        (uint256 tx_, uint256 ty_) = IBabyJub(babyJub).babyAdd(
            totalSupplyCommitment.x, totalSupplyCommitment.y,
            negX, negY
        );
        totalSupplyCommitment = Point({ x: tx_, y: ty_ });

        emit ConfidentialBurn(from, nx, ny);
    }

    // -----------------------------------------------------------------------
    // Internal helpers
    // -----------------------------------------------------------------------

    /// @dev Return the effective commitment for an account.
    ///      Uninitialized accounts store (0, 0) in the mapping; we treat this as (0, 1)
    ///      (the BabyJubJub identity element, representing zero balance).
    function _effectiveCommitment(address account) internal view returns (Point memory) {
        Point memory c = commitments[account];
        if (c.x == 0 && c.y == 0) {
            return Point({ x: 0, y: 1 });
        }
        return c;
    }
}

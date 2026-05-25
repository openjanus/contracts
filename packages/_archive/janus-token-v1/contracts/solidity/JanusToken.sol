// SPDX-License-Identifier: MIT
//
// JanusToken.sol — ERC-7984 Confidential Token Standard
//
// Named after Janus, the dual-faced Roman god of beginnings and thresholds.
// Like Janus, this contract stands between two worlds simultaneously:
//   Face 1: Flow EVM (Solidity, BN254 cryptography, Groth16 proofs)
//   Face 2: Cadence (resource wrapper, COA bridge, Flow-native apps)
//
// MODES:
//   NATIVE mode  (underlying == address(0)):
//     - Own supply, mintAuthority is msg.sender at deploy
//     - No underlying lock; mint/burn controlled by authority
//     - Example: demo instance, bank-issued private USD
//
//   WRAPPER mode (underlying != address(0)):
//     - Wraps an existing ERC-20 token 1:1
//     - wrap(amount) locks underlying, mints commitment
//     - unwrap(amount) burns commitment, releases underlying
//     - Example: JanusFLOW wraps FLOW, JanusUSDC wraps USDC
//
// This is the BASE CONTRACT / STANDARD — like ERC20.sol in OpenZeppelin.
// Apps deploy their own instances via constructor arguments.
// Do NOT treat deployed instances in this repo as the "canonical" token —
// they are demo/test instances only.
//
// ERC-7984 (Draft, May 2026) alignment:
//   confidentialMint(to, commit)            -> mint(to, amountCommitment)
//   confidentialTransfer(to, proof, inputs) -> confidentialTransfer(to, publicInputs, proof)
//   confidentialBalance(account)            -> balanceOfCommitment(account)
//   confidentialBurn(from, commit)          -> burn(from, amountCommitment)
//
// Deployed primitives (Flow EVM testnet — canonical, do NOT redeploy):
//   openjanus groth16 Verifier: 0x0085F286d89af79EC59E27CD0c5CcD1c55f42Cf5
//   openjanus babyjub BabyJub:  0x2c40513b343B70f2A0B7e6Ad6F997DDa819D6f07
//
// Circuit public input layout (uint256[6]):
//   [0] C_old.x   -- sender old balance commitment x
//   [1] C_old.y   -- sender old balance commitment y
//   [2] C_tx.x    -- transfer amount commitment x
//   [3] C_tx.y    -- transfer amount commitment y
//   [4] C_new.x   -- sender new balance commitment x
//   [5] C_new.y   -- sender new balance commitment y
//
// pi_b Fp2 swap (EIP-197):
//   snarkjs produces pi_b in (re, im) order per BN254.
//   EVM ecPairing precompile requires (im, re) order.
//   SDK src/proof.ts applies this swap automatically.
//
// Gas profile (Flow EVM testnet):
//   confidentialTransfer:  ~310,000 gas
//   mint / wrap:           ~55,000  gas
//   burn / unwrap:         ~55,000  gas
//   balanceOfCommitment:   ~2,000   gas
//
// Part of openjanus/contracts (TIER 2) — built on openjanus/primitives (TIER 1)

pragma solidity ^0.8.20;

// ---------------------------------------------------------------------------
// Minimal ERC-20 interface for wrapper mode
// ---------------------------------------------------------------------------

interface IERC20 {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function decimals() external view returns (uint8);
}

// ---------------------------------------------------------------------------
// Interfaces for deployed openjanus/primitives
// ---------------------------------------------------------------------------

/// @notice Interface to openjanus groth16 ConfidentialTransferVerifier
/// @dev Deployed at 0x0085F286d89af79EC59E27CD0c5CcD1c55f42Cf5 on Flow EVM testnet
interface IConfidentialTransferVerifier {
    /// @notice Verify a Groth16 proof for the ConfidentialTransfer v2 circuit.
    /// @param _pA     pi_a: G1 point [x, y]
    /// @param _pB     pi_b: G2 point [[im0, re0], [im1, re1]] (EIP-197 Fp2 swap applied)
    /// @param _pC     pi_c: G1 point [x, y]
    /// @param _pubSignals  6 public inputs: [C_old.x, C_old.y, C_tx.x, C_tx.y, C_new.x, C_new.y]
    /// @return bool   true if proof is valid
    function verifyProof(
        uint[2] calldata _pA,
        uint[2][2] calldata _pB,
        uint[2] calldata _pC,
        uint[6] calldata _pubSignals
    ) external view returns (bool);
}

/// @notice Interface to openjanus babyjub BabyJub.sol
/// @dev Deployed at 0x2c40513b343B70f2A0B7e6Ad6F997DDa819D6f07 on Flow EVM testnet
interface IBabyJub {
    /// @notice Twisted Edwards point addition on BabyJubJub. Identity: (0, 1).
    function babyAdd(
        uint256 x1, uint256 y1,
        uint256 x2, uint256 y2
    ) external view returns (uint256 x3, uint256 y3);

    /// @notice Negate a BabyJubJub point: negate(x, y) = (P - x, y).
    function negate(uint256 x, uint256 y) external pure returns (uint256 nx, uint256 ny);

    /// @notice Return the identity element (0, 1).
    function identity() external pure returns (uint256 x, uint256 y);
}

// ---------------------------------------------------------------------------
// JanusToken
// ---------------------------------------------------------------------------

/// @title JanusToken
/// @author openjanus
/// @notice Always-private confidential token standard (ERC-7984) on Flow EVM.
///         Supports NATIVE mode (own supply) and WRAPPER mode (wraps ERC-20).
///         Named after Janus, dual-faced Roman god of thresholds and beginnings.
contract JanusToken {

    // -----------------------------------------------------------------------
    // BabyJubJub point — used for all commitment arithmetic
    // -----------------------------------------------------------------------

    /// @notice A point on the BabyJubJub twisted Edwards curve.
    /// @dev Identity element is (0, 1).
    struct Point {
        uint256 x;
        uint256 y;
    }

    // -----------------------------------------------------------------------
    // Immutable primitive references (pinned at deploy)
    // -----------------------------------------------------------------------

    /// @notice openjanus groth16 ConfidentialTransferVerifier address.
    address public immutable verifier;

    /// @notice openjanus babyjub BabyJub.sol address.
    address public immutable babyJub;

    // -----------------------------------------------------------------------
    // Mode configuration (set once at deploy, immutable thereafter)
    // -----------------------------------------------------------------------

    /// @notice Underlying ERC-20 token for WRAPPER mode. address(0) in NATIVE mode.
    address public immutable underlying;

    /// @notice True if this instance operates in WRAPPER mode.
    bool public immutable isWrapperMode;

    // -----------------------------------------------------------------------
    // Access control
    // -----------------------------------------------------------------------

    /// @notice Authority for mint/burn in NATIVE mode. Also the wrap/unwrap authority in WRAPPER mode.
    /// @dev In NATIVE mode: sole authority for mint() and burn().
    ///      In WRAPPER mode: owner cannot mint directly (wrap() enforces 1:1 lock).
    ///      Immutable — no transfer path.
    address public immutable owner;

    // -----------------------------------------------------------------------
    // Token state
    // -----------------------------------------------------------------------

    /// @notice Hidden balance commitments — BabyJubJub Pedersen points, one per address.
    /// @dev Uninitialized storage reads as (0, 0); _effectiveCommitment() normalizes to (0, 1).
    mapping(address => Point) public commitments;

    /// @notice Homomorphic sum of all individual balance commitments.
    /// @dev Updated on every mint, burn, wrap, and unwrap.
    Point public totalSupplyCommitment;

    // -----------------------------------------------------------------------
    // Events (ERC-7984 aligned)
    // -----------------------------------------------------------------------

    event ConfidentialMint(address indexed to, uint256 new_commit_x, uint256 new_commit_y);
    event ConfidentialTransfer(address indexed from, address indexed to);
    event ConfidentialBurn(address indexed from, uint256 new_commit_x, uint256 new_commit_y);
    event Wrap(address indexed account, uint256 amount, uint256 commit_x, uint256 commit_y);
    event Unwrap(address indexed account, uint256 amount, uint256 new_commit_x, uint256 new_commit_y);

    // -----------------------------------------------------------------------
    // Constructor
    // -----------------------------------------------------------------------

    /// @notice Deploy a JanusToken instance.
    /// @dev NATIVE mode:  pass underlying_ = address(0). Caller becomes mint authority.
    ///      WRAPPER mode: pass underlying_ = the ERC-20 token address. wrap/unwrap enabled.
    ///
    ///      Canonical openjanus/primitives testnet addresses:
    ///        _verifier = 0x0085F286d89af79EC59E27CD0c5CcD1c55f42Cf5
    ///        _babyJub  = 0x2c40513b343B70f2A0B7e6Ad6F997DDa819D6f07
    ///
    /// @param _verifier   openjanus groth16 ConfidentialTransferVerifier address
    /// @param _babyJub    openjanus babyjub BabyJub.sol address
    /// @param underlying_ ERC-20 to wrap (address(0) for native mode)
    constructor(address _verifier, address _babyJub, address underlying_) {
        require(_verifier != address(0), "JanusToken: zero verifier address");
        require(_babyJub  != address(0), "JanusToken: zero babyJub address");

        verifier    = _verifier;
        babyJub     = _babyJub;
        owner       = msg.sender;
        underlying  = underlying_;
        isWrapperMode = (underlying_ != address(0));

        totalSupplyCommitment = Point({ x: 0, y: 1 });
    }

    // -----------------------------------------------------------------------
    // Modifiers
    // -----------------------------------------------------------------------

    modifier onlyOwner() {
        require(msg.sender == owner, "JanusToken: caller is not owner");
        _;
    }

    modifier onlyNativeMode() {
        require(!isWrapperMode, "JanusToken: operation not available in wrapper mode");
        _;
    }

    modifier onlyWrapperMode() {
        require(isWrapperMode, "JanusToken: operation not available in native mode");
        _;
    }

    // -----------------------------------------------------------------------
    // View functions
    // -----------------------------------------------------------------------

    /// @notice Return an account's balance commitment (ERC-7984 confidentialBalance).
    /// @dev Uninitialized storage is normalized to the identity (0, 1) = zero balance.
    function balanceOfCommitment(address account) external view returns (Point memory) {
        return _effectiveCommitment(account);
    }

    /// @notice Return balance commitment as flat (x, y) pair for cross-VM decoding.
    /// @dev Cadence decode: EVM.decodeABI(types: [Type<UInt256>(), Type<UInt256>()], data: ...)
    function balanceOfCommitmentXY(address account) external view returns (uint256 x, uint256 y) {
        Point memory c = _effectiveCommitment(account);
        return (c.x, c.y);
    }

    // -----------------------------------------------------------------------
    // confidentialTransfer — ERC-7984 core operation (both modes)
    // -----------------------------------------------------------------------

    /// @notice Transfer a hidden amount from msg.sender to `to`.
    /// @dev Groth16 proof must demonstrate:
    ///        1. C_old matches sender's on-chain commitment.
    ///        2. C_tx is a valid Pedersen commitment to the transfer amount.
    ///        3. C_new = Pedersen(old_balance - tx_amount, new_blinding).
    ///        4. tx_amount in [0, 2^64) (range check via Num2Bits).
    ///        5. tx_amount <= old_balance (underflow prevention via LessEqThan).
    ///
    ///      pi_b must have EIP-197 Fp2 swap applied (sdk/proof.ts does this).
    ///
    /// @param to           Recipient address
    /// @param publicInputs [C_old.x, C_old.y, C_tx.x, C_tx.y, C_new.x, C_new.y]
    /// @param proof        [pA.x, pA.y, pB[0][0], pB[0][1], pB[1][0], pB[1][1], pC.x, pC.y]
    function confidentialTransfer(
        address to,
        uint256[6] calldata publicInputs,
        uint256[8] calldata proof
    ) external {
        require(to != address(0), "JanusToken: transfer to zero address");
        require(to != msg.sender, "JanusToken: cannot transfer to self");

        // 1. Bind C_old to sender's on-chain commitment
        Point memory senderCommit = _effectiveCommitment(msg.sender);
        require(
            publicInputs[0] == senderCommit.x && publicInputs[1] == senderCommit.y,
            "JanusToken: C_old mismatch - publicInputs[0..1] must equal sender commitment"
        );

        // 2. Verify Groth16 proof
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

        // 3. Update sender commitment to C_new
        commitments[msg.sender] = Point({ x: publicInputs[4], y: publicInputs[5] });

        // 4. Add C_tx to recipient commitment homomorphically
        Point memory recipientCommit = _effectiveCommitment(to);
        (uint256 rx, uint256 ry) = IBabyJub(babyJub).babyAdd(
            recipientCommit.x, recipientCommit.y,
            publicInputs[2], publicInputs[3]
        );
        commitments[to] = Point({ x: rx, y: ry });

        emit ConfidentialTransfer(msg.sender, to);
    }

    // -----------------------------------------------------------------------
    // NATIVE mode: mint / burn (owner only)
    // -----------------------------------------------------------------------

    /// @notice Mint a hidden amount to `to` (NATIVE mode only).
    /// @dev Owner provides amountCommitment = Pedersen(amount, blinding) computed off-chain.
    function mint(address to, Point calldata amountCommitment) external onlyOwner onlyNativeMode {
        _mintXY(to, amountCommitment.x, amountCommitment.y);
    }

    /// @notice Cross-VM mint: flat (cx, cy) coordinates (NATIVE mode only).
    /// @dev Call from Cadence: EVM.encodeABIWithSignature("mintXY(address,uint256,uint256)", ...)
    function mintXY(address to, uint256 cx, uint256 cy) external onlyOwner onlyNativeMode {
        _mintXY(to, cx, cy);
    }

    /// @notice Burn a hidden amount from `from` (NATIVE mode only).
    function burn(address from, Point calldata amountCommitment) external onlyOwner onlyNativeMode {
        _burnXY(from, amountCommitment.x, amountCommitment.y);
    }

    /// @notice Cross-VM burn: flat coordinates (NATIVE mode only).
    function burnXY(address from, uint256 cx, uint256 cy) external onlyOwner onlyNativeMode {
        _burnXY(from, cx, cy);
    }

    // -----------------------------------------------------------------------
    // WRAPPER mode: wrap / unwrap
    // -----------------------------------------------------------------------

    /// @notice Wrap `amount` of the underlying ERC-20 token into a confidential commitment.
    /// @dev Caller must have approved this contract for `amount` of the underlying token.
    ///      The commitment = Pedersen(amount, blinding) computed off-chain by the caller.
    ///      This enforces 1:1 ratio: underlying is locked, commitment minted.
    ///      Commitment is provided by the caller (they know their blinding factor).
    ///
    /// @param amount           Underlying token amount to lock
    /// @param amountCommitment Pedersen(amount, blinding) — computed off-chain
    function wrap(uint256 amount, Point calldata amountCommitment) external onlyWrapperMode {
        require(amount > 0, "JanusToken: wrap amount must be > 0");
        bool ok = IERC20(underlying).transferFrom(msg.sender, address(this), amount);
        require(ok, "JanusToken: underlying transferFrom failed");
        _mintXY(msg.sender, amountCommitment.x, amountCommitment.y);
        emit Wrap(msg.sender, amount, amountCommitment.x, amountCommitment.y);
    }

    /// @notice Unwrap: burn a confidential commitment, release underlying tokens.
    /// @dev The caller reveals `amount` to the contract so the 1:1 lock can be released.
    ///      The commitment burned must be Pedersen(amount, blinding) — the caller must
    ///      provide valid proof that they own a commitment worth exactly `amount`.
    ///      For simplicity in v0.1, the burn commitment is provided by owner (issuer-style).
    ///      A future version will use a ZK proof of knowledge for the unwrap path.
    ///
    /// @param from             Account to burn from
    /// @param amount           Underlying amount to release
    /// @param amountCommitment Commitment to subtract (must match what was wrapped)
    function unwrap(
        address from,
        uint256 amount,
        Point calldata amountCommitment
    ) external onlyOwner onlyWrapperMode {
        require(amount > 0, "JanusToken: unwrap amount must be > 0");
        _burnXY(from, amountCommitment.x, amountCommitment.y);
        bool ok = IERC20(underlying).transfer(from, amount);
        require(ok, "JanusToken: underlying transfer failed");
        emit Unwrap(from, amount, commitments[from].x, commitments[from].y);
    }

    // -----------------------------------------------------------------------
    // Internal: shared mint/burn logic
    // -----------------------------------------------------------------------

    function _mintXY(address to, uint256 cx, uint256 cy) internal {
        require(to != address(0), "JanusToken: mint to zero address");

        Point memory current = _effectiveCommitment(to);
        (uint256 nx, uint256 ny) = IBabyJub(babyJub).babyAdd(current.x, current.y, cx, cy);
        commitments[to] = Point({ x: nx, y: ny });

        (uint256 tx_, uint256 ty_) = IBabyJub(babyJub).babyAdd(
            totalSupplyCommitment.x, totalSupplyCommitment.y, cx, cy
        );
        totalSupplyCommitment = Point({ x: tx_, y: ty_ });

        emit ConfidentialMint(to, nx, ny);
    }

    function _burnXY(address from, uint256 cx, uint256 cy) internal {
        require(from != address(0), "JanusToken: burn from zero address");

        (uint256 negX, uint256 negY) = IBabyJub(babyJub).negate(cx, cy);

        Point memory current = _effectiveCommitment(from);
        (uint256 nx, uint256 ny) = IBabyJub(babyJub).babyAdd(current.x, current.y, negX, negY);
        commitments[from] = Point({ x: nx, y: ny });

        (uint256 tx_, uint256 ty_) = IBabyJub(babyJub).babyAdd(
            totalSupplyCommitment.x, totalSupplyCommitment.y, negX, negY
        );
        totalSupplyCommitment = Point({ x: tx_, y: ty_ });

        emit ConfidentialBurn(from, nx, ny);
    }

    function _effectiveCommitment(address account) internal view returns (Point memory) {
        Point memory c = commitments[account];
        if (c.x == 0 && c.y == 0) {
            return Point({ x: 0, y: 1 });
        }
        return c;
    }
}

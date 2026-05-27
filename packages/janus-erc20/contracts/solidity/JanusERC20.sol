// SPDX-License-Identifier: MIT
// EXPERIMENTAL — NOT AUDITED — DO NOT USE FOR PRODUCTION
//
// JanusERC20.sol — Concrete confidential-amount wrapper for an ERC20 underlying.
//
// Plugs ERC20 custody into the JanusToken abstract base (UUPS-upgradeable, v0.3+).
// Mirrors the JanusFlow concrete shape:
//
//   - `initialize(...)` is called atomically inside the JanusERC20Proxy constructor.
//   - `_wrap` takes custody of `amount` of the underlying via `transferFrom`.
//   - `_unwrap` releases `claimedAmount` of the underlying via `transfer`.
//
// Approval pattern (one boundary leak by design):
//   1. user calls IERC20(underlying).approve(janusERC20Proxy, amount)
//   2. user calls janusERC20Proxy.wrap(amount, txCommit, amountProof)
//   3. wrap() pulls via transferFrom(user, address(this), amount)
//      → emits standard ERC20 Transfer(user, janusERC20Proxy, amount) — boundary
//        leak BY DESIGN (equivalent to msg.value at JanusFlow.wrap).
//
// Unwrap pattern:
//   1. proxy.unwrap(claimedAmount, recipient, ...)
//   2. unwrap() calls transfer(recipient, claimedAmount)
//      → emits standard ERC20 Transfer(janusERC20Proxy, recipient, claimedAmount)
//        — boundary leak BY DESIGN.
//
// shieldedTransfer (inherited from JanusToken) hides amount on all 5 channels
// AND does NOT touch the underlying ERC20 (no ERC20.Transfer event from the
// underlying layer during a shielded transfer).
//
// The underlying ERC20 is pinned at `initialize` time — one Janus instance per
// underlying. To wrap a different ERC20, deploy a new proxy.
//
// Storage layout (extends JanusToken's __gap[40] — see header in JanusToken.sol):
//   slot N    — address underlying
//   slot N+1  — uint256[39] __gap (reduced from 40 by one slot)

pragma solidity ^0.8.20;

import {JanusToken} from "./JanusToken.sol";

interface IERC20 {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function decimals() external view returns (uint8);
}

contract JanusERC20 is JanusToken {
    // -----------------------------------------------------------------------
    // Storage — see JanusToken header for layout constraints.
    //
    // We consume ONE slot from JanusToken's __gap[40] for the underlying
    // address, so concrete subclasses MUST treat __gap as starting at slot
    // (JanusToken's __gap start + 1) going forward. To remain a drop-in
    // replacement we declare our own __gap of size 39 here.
    // -----------------------------------------------------------------------

    /// The single ERC20 this Janus instance wraps. Pinned at initialize time.
    address public underlying;

    /// Reserved storage for future subclass state vars. Decrement when adding.
    uint256[39] private __gapJanusERC20;

    // -----------------------------------------------------------------------
    // Per-call wrap cap
    // -----------------------------------------------------------------------

    /// Per-call wrap cap. Matches the circuit's range proof boundary — the
    /// confidential_transfer circuit's Num2Bits tops out at 2^64 units, so a
    /// single wrap is capped here in raw token units. For a 6-decimal ERC20
    /// (USDC-like), this is ~18.4 trillion units = 18.4 million USDC.
    uint256 public constant MAX_WRAP = 18_000_000_000_000_000_000;

    // -----------------------------------------------------------------------
    // Initializer
    // -----------------------------------------------------------------------

    /// @notice Initialize a JanusERC20 proxy.
    /// Called atomically from the ERC1967Proxy constructor via
    /// `abi.encodeCall(JanusERC20.initialize, (...))`.
    function initialize(
        address _babyJub,
        address _transferVerifier,
        address _amountDiscloseVerifier,
        address _underlying,
        address _owner
    ) external initializer {
        require(_underlying != address(0), "JanusERC20: zero underlying");
        __JanusToken_init(_babyJub, _transferVerifier, _amountDiscloseVerifier, _owner);
        underlying = _underlying;
    }

    // -----------------------------------------------------------------------
    // Public wrap / unwrap (concrete signatures — no msg.value, no payable)
    // -----------------------------------------------------------------------

    /// @notice Wrap `amount` of the underlying ERC20 into the caller's hidden
    /// balance. Caller MUST have previously approved the proxy to spend at
    /// least `amount` of the underlying.
    /// @dev    `amount` is VISIBLE BY DESIGN — boundary leak.
    function wrap(
        uint256 amount,
        uint256[2] calldata txCommit,
        uint256[8] calldata amountProof
    ) external {
        _wrap(amount, txCommit, amountProof);
    }

    /// @notice Release `claimedAmount` of the underlying ERC20 to `recipient`
    /// while keeping the sender's residual balance commitment hidden.
    function unwrap(
        uint256 claimedAmount,
        address payable recipient,
        uint256[2] calldata txCommit,
        uint256[8] calldata amountProof,
        uint256[6] calldata transferPublicInputs,
        uint256[8] calldata transferProof
    ) external {
        _unwrap(
            claimedAmount,
            recipient,
            txCommit,
            amountProof,
            transferPublicInputs,
            transferProof
        );
    }

    // -----------------------------------------------------------------------
    // Template-method overrides
    // -----------------------------------------------------------------------

    function _wrap(
        uint256 amount,
        uint256[2] calldata txCommit,
        uint256[8] calldata amountProof
    ) internal override {
        require(amount > 0,         "JanusERC20: zero wrap");
        require(amount <= MAX_WRAP, "JanusERC20: exceeds MAX_WRAP");

        require(
            _verifyAmountDisclose(amount, txCommit, amountProof),
            "JanusERC20: invalid amount_disclose proof"
        );

        // Pull underlying — standard ERC20.Transfer event from the underlying
        // token contract is the intentional boundary leak.
        bool ok = IERC20(underlying).transferFrom(msg.sender, address(this), amount);
        require(ok, "JanusERC20: transferFrom failed");

        // Shielded credit (commitments + totalSupplyCommitment)
        _acceptShieldedCredit(msg.sender, txCommit);

        // Custody accounting (visible by design)
        totalLocked += amount;

        emit Wrapped(msg.sender, amount);
    }

    function _unwrap(
        uint256 claimedAmount,
        address payable recipient,
        uint256[2] calldata txCommit,
        uint256[8] calldata amountProof,
        uint256[6] calldata transferPublicInputs,
        uint256[8] calldata transferProof
    ) internal override {
        require(claimedAmount > 0,            "JanusERC20: zero unwrap");
        require(recipient != address(0),      "JanusERC20: zero recipient");
        require(totalLocked >= claimedAmount, "JanusERC20: pool exhausted");

        // 1) amount_disclose: txCommit binds to claimedAmount
        require(
            _verifyAmountDisclose(claimedAmount, txCommit, amountProof),
            "JanusERC20: invalid amount_disclose proof"
        );

        // 2) Transfer proof must reference sender's current commitment.
        Point memory senderCommit = _effectiveCommitment(msg.sender);
        require(
            transferPublicInputs[0] == senderCommit.x &&
            transferPublicInputs[1] == senderCommit.y,
            "JanusERC20: C_old mismatch"
        );

        // 3) Same txCommit must be the C_tx in the transfer proof.
        require(
            transferPublicInputs[2] == txCommit[0] &&
            transferPublicInputs[3] == txCommit[1],
            "JanusERC20: C_tx mismatch between proofs"
        );

        // 4) Verify Groth16 transfer proof.
        require(
            _verifyTransferProof(transferPublicInputs, transferProof),
            "JanusERC20: invalid transfer proof"
        );

        // 5) Apply shielded debit (sender → C_new ; totalSupplyCommitment -= C_tx)
        _processShieldedDebit(msg.sender, txCommit, transferPublicInputs);

        // 6) Release underlying ERC20 (boundary leak — intentional).
        totalLocked -= claimedAmount;
        bool ok = IERC20(underlying).transfer(recipient, claimedAmount);
        require(ok, "JanusERC20: transfer failed");

        emit Unwrapped(msg.sender, recipient, claimedAmount);
    }

    // -----------------------------------------------------------------------
    // View helper for tests
    // -----------------------------------------------------------------------

    function underlyingBalance() external view returns (uint256) {
        return IERC20(underlying).balanceOf(address(this));
    }
}

// SPDX-License-Identifier: MIT
// EXPERIMENTAL — NOT AUDITED — DO NOT USE FOR PRODUCTION
//
// JanusFlow.sol — Concrete native-FLOW openjanus confidential token (v0.3).
//
// Inherits the JanusToken abstract base and plugs in native-FLOW custody via
// `payable wrap()` and `unwrap()` that calls `recipient.call{value: ...}`.
//
// Privacy properties (claimed; empirically validated in v03-smoke.mjs):
//
//   Q1 msg.value          : LEAK at wrap (intentional) | HIDE elsewhere.
//   Q2 calldata           : LEAK at wrap+unwrap (amount params) | HIDE on transfer.
//   Q3 storage view       : HIDE per-account commitments | LEAK aggregate totalLocked.
//   Q4 events             : LEAK Wrapped / Unwrapped amount | HIDE on ConfidentialTransfer.
//   Q5 commitment opacity : HIDE (128-bit Pedersen blinding).
//
// Deployment shape:
//
//   ERC1967Proxy(JanusFlow impl, initData) — UUPS-upgradeable.
//   `initialize(...)` is called atomically inside the proxy constructor.
//   Upgrades are gated by `_authorizeUpgrade` (owner-only, see JanusToken).
//
// The lab MAX_WRAP cap is ported as-is — ~18 FLOW (2^64 attoFLOW headroom for
// circuit-side range proof). Tighten via an upgrade before any mainnet deploy.

pragma solidity ^0.8.20;

import {JanusToken} from "./JanusToken.sol";

contract JanusFlow is JanusToken {
    // -----------------------------------------------------------------------
    // Constants
    // -----------------------------------------------------------------------

    /// Per-call wrap cap. Matches the lab ConfidentialFLOW reference: the
    /// confidential_transfer circuit's Num2Bits range proof tops out at 2^64
    /// units, so a single wrap is capped at the same boundary in attoFLOW.
    /// ~18.4 FLOW = 2^64 attoFLOW.
    uint256 public constant MAX_WRAP = 18_000_000_000_000_000_000;

    // -----------------------------------------------------------------------
    // Initializer
    // -----------------------------------------------------------------------

    /// @notice Initialize a JanusFlow proxy.
    /// Called atomically from the ERC1967Proxy constructor via
    /// `abi.encodeCall(JanusFlow.initialize, (...))`.
    function initialize(
        address _babyJub,
        address _transferVerifier,
        address _amountDiscloseVerifier,
        address _owner
    ) external initializer {
        __JanusToken_init(_babyJub, _transferVerifier, _amountDiscloseVerifier, _owner);
    }

    // -----------------------------------------------------------------------
    // Public wrap / unwrap
    // -----------------------------------------------------------------------

    /// @notice Deposit `msg.value` of native FLOW into a hidden balance.
    /// @dev    `msg.value` is VISIBLE BY DESIGN — boundary leak.
    function wrap(
        uint256[2] calldata txCommit,
        uint256[8] calldata amountProof
    ) external payable {
        _wrap(msg.value, txCommit, amountProof);
    }

    /// @notice Release `claimedAmount` of native FLOW to `recipient` while
    /// keeping the sender's residual balance commitment hidden.
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
        require(amount > 0,           "JanusFlow: zero wrap");
        require(amount <= MAX_WRAP,   "JanusFlow: exceeds MAX_WRAP");

        require(
            _verifyAmountDisclose(amount, txCommit, amountProof),
            "JanusFlow: invalid amount_disclose proof"
        );

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
        require(claimedAmount > 0,             "JanusFlow: zero unwrap");
        require(recipient != address(0),       "JanusFlow: zero recipient");
        require(totalLocked >= claimedAmount,  "JanusFlow: pool exhausted");

        // 1) amount_disclose: txCommit binds to claimedAmount
        require(
            _verifyAmountDisclose(claimedAmount, txCommit, amountProof),
            "JanusFlow: invalid amount_disclose proof"
        );

        // 2) Transfer proof must reference sender's current commitment.
        Point memory senderCommit = _effectiveCommitment(msg.sender);
        require(
            transferPublicInputs[0] == senderCommit.x &&
            transferPublicInputs[1] == senderCommit.y,
            "JanusFlow: C_old mismatch"
        );

        // 3) Same txCommit must be the C_tx in the transfer proof.
        require(
            transferPublicInputs[2] == txCommit[0] &&
            transferPublicInputs[3] == txCommit[1],
            "JanusFlow: C_tx mismatch between proofs"
        );

        // 4) Verify Groth16 transfer proof (C_new = C_old − C_tx + range).
        require(
            _verifyTransferProof(transferPublicInputs, transferProof),
            "JanusFlow: invalid transfer proof"
        );

        // 5) Apply shielded debit (sender → C_new ; totalSupplyCommitment -= C_tx)
        _processShieldedDebit(msg.sender, txCommit, transferPublicInputs);

        // 6) Release native FLOW (boundary leak — intentional).
        totalLocked -= claimedAmount;
        (bool sent, ) = recipient.call{value: claimedAmount}("");
        require(sent, "JanusFlow: FLOW transfer failed");

        emit Unwrapped(msg.sender, recipient, claimedAmount);
    }

    // -----------------------------------------------------------------------
    // Receive — disabled (FLOW must enter only via wrap to be tracked)
    // -----------------------------------------------------------------------

    receive() external payable {
        revert("JanusFlow: bare FLOW deposit disabled - use wrap()");
    }
}

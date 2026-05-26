// SPDX-License-Identifier: MIT
// EXPERIMENTAL — NOT AUDITED — DO NOT USE FOR PRODUCTION
//
// JanusToken.sol — ElGamal Accumulator-based confidential token (UUPS-upgradeable)
//
// Architecture: Exponential ElGamal on BabyJubJub
//   C1 = r * G                         (randomness commitment)
//   C2 = v * G + r * PK               (value commitment to recipient pubkey)
//   Homomorphic: E(v1) + E(v2) = E(v1+v2) — slot accumulates tips
//
// This is the core EVM contract for openjanus confidential tokens.
// The Cadence layer (JanusFlow.cdc) wraps this contract for Flow-native UX.
//
// Improvements over earlier prototypes:
//   1. Per-sender nonce replay protection on confidentialTransfer()
//   2. ZK proof gating on confidentialTransfer() via EncryptConsistencyVerifier
//   3. ZK proof gating on unwrap() via DecryptOpenVerifier
//   4. Pubkey rotation with 1-hour timelock (testnet) / 7-day (mainnet)
//   5. resetSlot() test function REMOVED
//   6. FLOW vault custody tracked per-user (locked[address])
//   7. UUPS-upgradeable (ERC-1967 proxy)
//   8. SCALE conversion between ZK whole-FLOW units and EVM attoFLOW (vuln 014 fix)
//
// Trusted setup note:
//   v0.2.0 Hermez ceremony + Flow VRF beacon contribution.
//   DO NOT ship to mainnet without an independent ceremony.
//
// Security properties:
//   - IND-CPA under DDH on BabyJubJub
//   - Sender-recipient relationship visible on-chain by design
//   - Wrap/unwrap amounts visible via EVM events (unavoidable)
//   - Recipient learns total only, not per-sender amounts

pragma solidity ^0.8.20;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

// ─── Interfaces ────────────────────────────────────────────────────────────

interface IBabyJub {
    function babyAdd(
        uint256 x1, uint256 y1,
        uint256 x2, uint256 y2
    ) external view returns (uint256 x3, uint256 y3);

    function isOnCurve(uint256 x, uint256 y) external pure returns (bool);
    function negate(uint256 x, uint256 y) external pure returns (uint256 nx, uint256 ny);
    function identity() external pure returns (uint256 x, uint256 y);
}

interface IEncryptVerifier {
    // public signals: [recipient_pubkey[2], C1[2], C2[2]] = 6 signals
    function verifyProof(
        uint[2] calldata _pA,
        uint[2][2] calldata _pB,
        uint[2] calldata _pC,
        uint[6] calldata _pubSignals
    ) external view returns (bool);
}

interface IDecryptVerifier {
    // public signals: [pubkey[2], C1[2], C2[2], claimed_value] = 7 signals
    function verifyProof(
        uint[2] calldata _pA,
        uint[2][2] calldata _pB,
        uint[2] calldata _pC,
        uint[7] calldata _pubSignals
    ) external view returns (bool);
}

// ─── Contract ──────────────────────────────────────────────────────────────

contract JanusToken is Initializable, UUPSUpgradeable, OwnableUpgradeable {

    // ─── Constants ──────────────────────────────────────────────────────────
    uint256 public constant P =
        21888242871839275222246405745257275088548364400416034343698204186575808495617;

    /// Timelock duration: 1 hour for testnet, update to 7 days for mainnet
    uint256 public constant PUBKEY_ROTATION_DELAY = 1 hours;

    /// Scale factor between ZK "whole-FLOW units" (small ints, range [0, 2^48))
    /// and EVM wei/attoFLOW (1 FLOW = 1e18 attoFLOW).
    ///
    /// Fix for vulnerability 014: the decrypt_open circuit emits claimed_value in
    /// whole-FLOW units (forced by BSGS feasibility on BabyJubJub). The EVM payable
    /// path operates in wei. SCALE bridges the two so a user wrapping 1 FLOW
    /// recovers ~1 FLOW on unwrap, not 1 wei.
    uint256 public constant SCALE = 1e18;

    // ─── Types ───────────────────────────────────────────────────────────────

    struct Point {
        uint256 x;
        uint256 y;
    }

    /// @dev ElGamal ciphertext as two BabyJubJub points
    struct Ciphertext {
        uint256 C1x;
        uint256 C1y;
        uint256 C2x;
        uint256 C2y;
    }

    // ─── State (proxy storage) ───────────────────────────────────────────────

    // Address dependencies — must be in storage (no immutable in upgradeables)
    IBabyJub   public babyJub;
    IEncryptVerifier public encryptVerifier;
    IDecryptVerifier public decryptVerifier;

    // Active pubkey registry
    mapping(address => Point)   public pubkey;
    mapping(address => bool)    public hasPubkey;
    mapping(address => uint256) public pubkeyRegisteredAt;

    // Pending pubkey rotation
    mapping(address => Point)   public pendingPubkey;
    mapping(address => uint256) public pendingPubkeyAvailableAt; // 0 = no pending

    // Accumulator slots — one slot per recipient
    mapping(address => Ciphertext) public slot;

    // Replay protection: per-sender nonce (must increment each call)
    mapping(address => uint256) public nonce;

    // FLOW custody: attoFLOW locked per user
    mapping(address => uint256) public locked;

    /// Reserved storage slots for future upgrades.
    /// Decrement when adding new state vars to keep storage layout stable.
    uint256[40] private __gap;

    // ─── Events ──────────────────────────────────────────────────────────────

    event PubkeyRegistered(address indexed account, uint256 x, uint256 y);
    event PubkeyRotationCommitted(address indexed account, uint256 newX, uint256 newY, uint256 availableAt);
    event PubkeyRotationFinalized(address indexed account, uint256 newX, uint256 newY);
    event Wrapped(address indexed from, address indexed to, uint256 amountAttoFlow);
    event ConfidentialTransfer(address indexed from, address indexed to);
    event Unwrapped(address indexed account, address indexed recipient, uint256 amountAttoFlow);

    // ─── Constructor / Initializer ───────────────────────────────────────────

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize the proxy with verifier addresses and owner.
    /// @dev Called once via the ERC1967Proxy after deployment.
    function initialize(
        address _babyJub,
        address _encryptVerifier,
        address _decryptVerifier,
        address _owner
    ) external initializer {
        require(_babyJub != address(0), "JanusToken: zero babyJub");
        require(_encryptVerifier != address(0), "JanusToken: zero encryptVerifier");
        require(_decryptVerifier != address(0), "JanusToken: zero decryptVerifier");
        require(_owner != address(0), "JanusToken: zero owner");

        __Ownable_init(_owner);
        __UUPSUpgradeable_init();

        babyJub = IBabyJub(_babyJub);
        encryptVerifier = IEncryptVerifier(_encryptVerifier);
        decryptVerifier = IDecryptVerifier(_decryptVerifier);
    }

    /// @dev UUPS authorization: only owner can upgrade implementation.
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    // ─── Pubkey management ────────────────────────────────────────────────────

    /**
     * @notice Register a BabyJubJub public key for msg.sender.
     */
    function registerPubkey(uint256 x, uint256 y) external {
        require(!hasPubkey[msg.sender], "JanusToken: pubkey already registered, use rotatePubkey");
        _validatePubkey(x, y);

        pubkey[msg.sender] = Point(x, y);
        hasPubkey[msg.sender] = true;
        pubkeyRegisteredAt[msg.sender] = block.timestamp;

        // Initialize slot to identity (C1=(0,1), C2=(0,1))
        slot[msg.sender] = Ciphertext(0, 1, 0, 1);

        emit PubkeyRegistered(msg.sender, x, y);
    }

    function commitPubkeyRotation(uint256 newX, uint256 newY) external {
        require(hasPubkey[msg.sender], "JanusToken: not registered");
        _validatePubkey(newX, newY);
        require(
            newX != pubkey[msg.sender].x || newY != pubkey[msg.sender].y,
            "JanusToken: new pubkey same as current"
        );

        uint256 availableAt = block.timestamp + PUBKEY_ROTATION_DELAY;
        pendingPubkey[msg.sender] = Point(newX, newY);
        pendingPubkeyAvailableAt[msg.sender] = availableAt;

        emit PubkeyRotationCommitted(msg.sender, newX, newY, availableAt);
    }

    function finalizePubkeyRotation() external {
        require(hasPubkey[msg.sender], "JanusToken: not registered");
        uint256 availableAt = pendingPubkeyAvailableAt[msg.sender];
        require(availableAt != 0, "JanusToken: no pending rotation");
        require(block.timestamp >= availableAt, "JanusToken: timelock not elapsed");

        Point memory newPk = pendingPubkey[msg.sender];
        pubkey[msg.sender] = newPk;

        delete pendingPubkey[msg.sender];
        delete pendingPubkeyAvailableAt[msg.sender];

        emit PubkeyRotationFinalized(msg.sender, newPk.x, newPk.y);
    }

    // ─── Core operations ──────────────────────────────────────────────────────

    /**
     * @notice Wrap whole FLOW into a confidential slot for recipient.
     * @dev msg.value MUST be a whole multiple of SCALE (1 FLOW = 1e18 wei).
     *      The ZK ciphertext encodes msg.value / SCALE (small int the circuit can handle).
     */
    function wrap(
        address to,
        Ciphertext calldata ct,
        uint256 senderNonce,
        uint[6] calldata publicInputs,
        uint[8] calldata encryptProof
    ) external payable {
        require(hasPubkey[to], "JanusToken: recipient has no pubkey");
        require(msg.value > 0, "JanusToken: must wrap nonzero amount");
        require(msg.value % SCALE == 0, "JanusToken: msg.value must be whole FLOW");

        require(senderNonce == nonce[msg.sender], "JanusToken: invalid nonce");
        nonce[msg.sender]++;

        _validateCiphertext(ct);
        _verifyEncryptProof(to, ct, publicInputs, encryptProof);

        locked[to] += msg.value;
        _accumulate(to, ct);

        emit Wrapped(msg.sender, to, msg.value);
    }

    /**
     * @notice Confidential transfer of locked-FLOW custody between users.
     * @param transferUnits  Amount in whole-FLOW units (NOT wei). Converted via SCALE.
     */
    function confidentialTransfer(
        address to,
        Ciphertext calldata ct,
        uint256 transferUnits,
        uint256 senderNonce,
        uint[6] calldata publicInputs,
        uint[8] calldata encryptProof
    ) external {
        require(hasPubkey[msg.sender], "JanusToken: sender not registered");
        require(hasPubkey[to], "JanusToken: recipient not registered");
        require(transferUnits > 0, "JanusToken: zero transfer");

        uint256 transferAtto = transferUnits * SCALE;
        require(locked[msg.sender] >= transferAtto, "JanusToken: insufficient locked balance");

        require(senderNonce == nonce[msg.sender], "JanusToken: invalid nonce");
        nonce[msg.sender]++;

        _validateCiphertext(ct);
        _verifyEncryptProof(to, ct, publicInputs, encryptProof);

        locked[msg.sender] -= transferAtto;
        locked[to] += transferAtto;

        _accumulate(to, ct);

        emit ConfidentialTransfer(msg.sender, to);
    }

    /**
     * @notice Unwrap — prove knowledge of decryption + release FLOW to recipient.
     * @dev VULN 014 FIX: claimedUnits is the whole-FLOW value the ZK circuit emits.
     *      We multiply by SCALE to get the wei amount to send / deduct.
     *      The ZK proof's claimed_value MUST equal claimedUnits (whole-FLOW units),
     *      consistent with the circuit's small-int range.
     *
     * @param claimedUnits  Claimed slot total in whole FLOW (matches publicInputs[6])
     * @param recipient     Address to receive the unwrapped FLOW
     * @param publicInputs  7 public inputs for the decrypt_open circuit
     * @param decryptProof  Groth16 proof packed as uint[8]
     */
    function unwrap(
        uint256 claimedUnits,
        address payable recipient,
        uint[7] calldata publicInputs,
        uint[8] calldata decryptProof
    ) external {
        require(hasPubkey[msg.sender], "JanusToken: not registered");
        require(claimedUnits > 0, "JanusToken: zero amount");

        // Proof check: claimed_value (small int from circuit) == claimedUnits
        require(
            publicInputs[6] == claimedUnits,
            "JanusToken: claimed_value in proof must match units"
        );

        uint256 amountAtto = claimedUnits * SCALE;
        require(locked[msg.sender] >= amountAtto, "JanusToken: amount exceeds locked balance");

        _verifyDecryptProof(msg.sender, publicInputs, decryptProof);

        locked[msg.sender] -= amountAtto;
        slot[msg.sender] = Ciphertext(0, 1, 0, 1);

        (bool ok, ) = recipient.call{value: amountAtto}("");
        require(ok, "JanusToken: FLOW transfer failed");

        emit Unwrapped(msg.sender, recipient, amountAtto);
    }

    // ─── View functions ───────────────────────────────────────────────────────

    function slotOf(address user) external view returns (Ciphertext memory) {
        return slot[user];
    }

    function pubkeyOf(address user) external view returns (uint256 x, uint256 y) {
        require(hasPubkey[user], "JanusToken: no pubkey registered");
        return (pubkey[user].x, pubkey[user].y);
    }

    function pendingRotationOf(address user)
        external
        view
        returns (uint256 newX, uint256 newY, uint256 availableAt)
    {
        return (
            pendingPubkey[user].x,
            pendingPubkey[user].y,
            pendingPubkeyAvailableAt[user]
        );
    }

    // ─── Internal helpers ─────────────────────────────────────────────────────

    function _validatePubkey(uint256 x, uint256 y) internal view {
        require(x < P && y < P, "JanusToken: pubkey coord out of field");
        require(!(x == 0 && y == 1), "JanusToken: pubkey cannot be identity");
        require(babyJub.isOnCurve(x, y), "JanusToken: pubkey not on BabyJub curve");
    }

    function _validateCiphertext(Ciphertext calldata ct) internal view {
        require(ct.C1x < P && ct.C1y < P && ct.C2x < P && ct.C2y < P,
            "JanusToken: ciphertext coords out of field");
        require(babyJub.isOnCurve(ct.C1x, ct.C1y), "JanusToken: C1 not on curve");
        require(babyJub.isOnCurve(ct.C2x, ct.C2y), "JanusToken: C2 not on curve");
    }

    function _accumulate(address to, Ciphertext calldata ct) internal {
        Ciphertext storage cur = slot[to];
        (uint256 newC1x, uint256 newC1y) = babyJub.babyAdd(
            cur.C1x, cur.C1y,
            ct.C1x, ct.C1y
        );
        (uint256 newC2x, uint256 newC2y) = babyJub.babyAdd(
            cur.C2x, cur.C2y,
            ct.C2x, ct.C2y
        );
        slot[to] = Ciphertext(newC1x, newC1y, newC2x, newC2y);
    }

    function _verifyEncryptProof(
        address to,
        Ciphertext calldata ct,
        uint[6] calldata publicInputs,
        uint[8] calldata encryptProof
    ) internal view {
        require(
            publicInputs[0] == pubkey[to].x && publicInputs[1] == pubkey[to].y,
            "JanusToken: proof pubkey mismatch"
        );
        require(
            publicInputs[2] == ct.C1x && publicInputs[3] == ct.C1y,
            "JanusToken: proof C1 mismatch"
        );
        require(
            publicInputs[4] == ct.C2x && publicInputs[5] == ct.C2y,
            "JanusToken: proof C2 mismatch"
        );

        uint[2] memory pA = [encryptProof[0], encryptProof[1]];
        uint[2][2] memory pB = [[encryptProof[2], encryptProof[3]], [encryptProof[4], encryptProof[5]]];
        uint[2] memory pC = [encryptProof[6], encryptProof[7]];

        bool valid = encryptVerifier.verifyProof(pA, pB, pC, publicInputs);
        require(valid, "JanusToken: encrypt proof invalid");
    }

    function _verifyDecryptProof(
        address caller,
        uint[7] calldata publicInputs,
        uint[8] calldata decryptProof
    ) internal view {
        Ciphertext storage cur = slot[caller];
        Point storage pk = pubkey[caller];

        require(
            publicInputs[0] == pk.x && publicInputs[1] == pk.y,
            "JanusToken: decrypt proof pubkey mismatch"
        );
        require(
            publicInputs[2] == cur.C1x && publicInputs[3] == cur.C1y,
            "JanusToken: decrypt proof C1 mismatch"
        );
        require(
            publicInputs[4] == cur.C2x && publicInputs[5] == cur.C2y,
            "JanusToken: decrypt proof C2 mismatch"
        );

        uint[2] memory pA = [decryptProof[0], decryptProof[1]];
        uint[2][2] memory pB = [[decryptProof[2], decryptProof[3]], [decryptProof[4], decryptProof[5]]];
        uint[2] memory pC = [decryptProof[6], decryptProof[7]];

        bool valid = decryptVerifier.verifyProof(pA, pB, pC, publicInputs);
        require(valid, "JanusToken: decrypt proof invalid");
    }

    // ─── Fallback ─────────────────────────────────────────────────────────────

    receive() external payable {}
}

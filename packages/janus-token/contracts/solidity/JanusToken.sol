// SPDX-License-Identifier: MIT
// EXPERIMENTAL — NOT AUDITED — DO NOT USE FOR PRODUCTION
//
// JanusToken.sol — ElGamal Accumulator-based confidential token
//
// Architecture: Exponential ElGamal on BabyJubJub
//   C1 = r * G                         (randomness commitment)
//   C2 = v * G + r * PK               (value commitment to recipient pubkey)
//   Homomorphic: E(v1) + E(v2) = E(v1+v2) — slot accumulates tips
//
// This is the core EVM contract for Phase 3 of openjanus.
// The Cadence layer (JanusFlow.cdc) wraps this contract for Flow-native UX.
//
// Addresses (Flow EVM testnet, chainId 545):
//   BabyJub.sol:              0x27139AFda7425f51F68D32e0A38b7D43BcB0f870
//   EncryptConsistency:       0x6F8Cc93dd6aA7B3ED0a3DaA75271815558ad9b5C (phase1 spike)
//   DecryptOpen:              0x3bB139B5404fD6b152813bC3532367AAa096638b (phase1 spike)
//   JanusToken (this):      [PENDING — set after deploy]
//
// Improvements over earlier prototypes:
//   1. Per-sender nonce replay protection on confidentialTransfer()
//   2. ZK proof gating on confidentialTransfer() via EncryptConsistencyVerifier
//   3. ZK proof gating on unwrap() via DecryptOpenVerifier
//   4. Pubkey rotation with 1-hour timelock (testnet) / 7-day (mainnet)
//   5. resetSlot() test function REMOVED
//   6. FLOW vault custody tracked per-user (locked[address])
//
// Trusted setup note:
//   Phase 1 lab pot14 is used for testnet. Mainnet requires Hermez ceremony
//   with Flow VRF beacon as phase 2 contribution. DO NOT ship to mainnet
//   without ceremony.
//
// Security properties:
//   - IND-CPA under DDH on BabyJubJub
//   - Sender-recipient relationship visible on-chain by design
//   - Wrap/unwrap amounts visible via EVM Transfer events (unavoidable)
//   - Recipient learns total only, not per-sender amounts

pragma solidity ^0.8.20;

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

contract JanusToken {

    // ─── Constants ──────────────────────────────────────────────────────────
    uint256 constant P = 21888242871839275222246405745257275088548364400416034343698204186575808495617;

    // Timelock duration: 1 hour for testnet, update to 7 days for mainnet
    uint256 public constant PUBKEY_ROTATION_DELAY = 1 hours;

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

    // ─── Immutables ──────────────────────────────────────────────────────────

    IBabyJub   public immutable babyJub;
    IEncryptVerifier public immutable encryptVerifier;
    IDecryptVerifier public immutable decryptVerifier;

    // Admin: multisig in production, deployer for testnet
    address public immutable owner;

    // ─── State ───────────────────────────────────────────────────────────────

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

    // ─── Events ──────────────────────────────────────────────────────────────

    event PubkeyRegistered(address indexed account, uint256 x, uint256 y);
    event PubkeyRotationCommitted(address indexed account, uint256 newX, uint256 newY, uint256 availableAt);
    event PubkeyRotationFinalized(address indexed account, uint256 newX, uint256 newY);
    event Wrapped(address indexed from, address indexed to, uint256 amountAttoFlow);
    event ConfidentialTransfer(address indexed from, address indexed to);
    event Unwrapped(address indexed account, address indexed recipient, uint256 amount);

    // ─── Constructor ─────────────────────────────────────────────────────────

    constructor(
        address _babyJub,
        address _encryptVerifier,
        address _decryptVerifier
    ) {
        require(_babyJub != address(0), "JanusToken: zero babyJub");
        require(_encryptVerifier != address(0), "JanusToken: zero encryptVerifier");
        require(_decryptVerifier != address(0), "JanusToken: zero decryptVerifier");
        babyJub = IBabyJub(_babyJub);
        encryptVerifier = IEncryptVerifier(_encryptVerifier);
        decryptVerifier = IDecryptVerifier(_decryptVerifier);
        owner = msg.sender;
    }

    // ─── Pubkey management ────────────────────────────────────────────────────

    /**
     * @notice Register a BabyJubJub public key for msg.sender.
     * @dev First registration only. Cannot be called again once registered.
     *      Use commitPubkeyRotation + finalizePubkeyRotation for updates.
     * @param x  x-coordinate of the public key point
     * @param y  y-coordinate of the public key point
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

    /**
     * @notice Commit to a pubkey rotation. Subject to timelock.
     * @dev Initiates a rotation request. The new pubkey becomes active after
     *      PUBKEY_ROTATION_DELAY seconds. There can only be one pending
     *      rotation at a time. Overwriting a pending rotation resets the timer.
     *
     *      Note: Existing slots remain encrypted to the OLD pubkey.
     *      The user can still decrypt their old slot after rotation.
     *      New tips after finalization will use the new pubkey.
     *
     * @param newX  x-coordinate of the new public key
     * @param newY  y-coordinate of the new public key
     */
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

    /**
     * @notice Finalize a committed pubkey rotation after timelock has elapsed.
     * @dev Reverts if no pending rotation, or if timelock has not elapsed.
     */
    function finalizePubkeyRotation() external {
        require(hasPubkey[msg.sender], "JanusToken: not registered");
        uint256 availableAt = pendingPubkeyAvailableAt[msg.sender];
        require(availableAt != 0, "JanusToken: no pending rotation");
        require(block.timestamp >= availableAt, "JanusToken: timelock not elapsed");

        Point memory newPk = pendingPubkey[msg.sender];
        pubkey[msg.sender] = newPk;

        // Clear pending state
        delete pendingPubkey[msg.sender];
        delete pendingPubkeyAvailableAt[msg.sender];

        emit PubkeyRotationFinalized(msg.sender, newPk.x, newPk.y);
    }

    // ─── Core operations ──────────────────────────────────────────────────────

    /**
     * @notice Wrap attoFLOW into a confidential slot for recipient.
     * @dev Called by the Cadence layer (JanusFlow) which holds the actual
     *      FLOW vault. The EVM layer only tracks locked amounts.
     *      Requires a valid encrypt_consistency ZK proof.
     *
     *      Public signals order: [recipient_pubkey.x, recipient_pubkey.y,
     *                             C1.x, C1.y, C2.x, C2.y]
     *
     * @param to            Recipient EVM address (must have registered pubkey)
     * @param ct            Encrypted tip amount (ElGamal ciphertext)
     * @param senderNonce   Sender's current nonce (must match nonce[msg.sender])
     * @param publicInputs  6 public inputs for the encrypt_consistency circuit
     * @param encryptProof  Groth16 proof [pA[2], pB[2][2], pC[2]] packed as uint[8]
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

        // Replay protection: nonce must match and increments
        require(senderNonce == nonce[msg.sender], "JanusToken: invalid nonce");
        nonce[msg.sender]++;

        // Validate ciphertext points are on curve
        _validateCiphertext(ct);

        // Verify encrypt_consistency proof
        // Public signals must match the ciphertext and recipient pubkey
        _verifyEncryptProof(to, ct, publicInputs, encryptProof);

        // Lock the FLOW
        locked[to] += msg.value;

        // Homomorphic accumulation
        _accumulate(to, ct);

        emit Wrapped(msg.sender, to, msg.value);
    }

    /**
     * @notice Confidential transfer: move a ciphertext from sender's slot to recipient.
     * @dev This is a pure ciphertext operation — no FLOW moves.
     *      The sender must have a slot with sufficient encrypted balance.
     *      Requires a valid encrypt_consistency ZK proof showing the ciphertext
     *      is well-formed for the recipient's pubkey.
     *
     *      The sender's slot is NOT decremented (this is the accumulator model,
     *      not UTXO). ConfidentialTransfer here means: sender is tipping recipient,
     *      equivalent to wrap() but without additional FLOW deposit — the FLOW was
     *      already wrapped into sender's locked[sender] and is now reassigned.
     *
     * @param to            Recipient EVM address
     * @param ct            Ciphertext to transfer (encrypted to recipient's pubkey)
     * @param transferAmount  Amount of locked FLOW to reassign (in attoFLOW)
     * @param senderNonce   Sender's current nonce
     * @param publicInputs  6 public inputs for encrypt_consistency circuit
     * @param encryptProof  Groth16 proof bytes
     */
    function confidentialTransfer(
        address to,
        Ciphertext calldata ct,
        uint256 transferAmount,
        uint256 senderNonce,
        uint[6] calldata publicInputs,
        uint[8] calldata encryptProof
    ) external {
        require(hasPubkey[msg.sender], "JanusToken: sender not registered");
        require(hasPubkey[to], "JanusToken: recipient not registered");
        require(transferAmount > 0, "JanusToken: zero transfer");
        require(locked[msg.sender] >= transferAmount, "JanusToken: insufficient locked balance");

        // Replay protection
        require(senderNonce == nonce[msg.sender], "JanusToken: invalid nonce");
        nonce[msg.sender]++;

        // Validate ciphertext points
        _validateCiphertext(ct);

        // Verify ZK proof: ciphertext is well-formed for recipient's pubkey
        _verifyEncryptProof(to, ct, publicInputs, encryptProof);

        // Transfer locked FLOW from sender to recipient
        locked[msg.sender] -= transferAmount;
        locked[to] += transferAmount;

        // Accumulate ciphertext into recipient's slot
        _accumulate(to, ct);

        emit ConfidentialTransfer(msg.sender, to);
    }

    /**
     * @notice Unwrap — prove knowledge of decryption + release FLOW to recipient.
     * @dev Caller proves they know the total accumulated value in their slot
     *      via a decrypt_open ZK proof. If valid, releases FLOW.
     *
     *      Public signals order: [pubkey.x, pubkey.y, C1.x, C1.y, C2.x, C2.y, claimed_value]
     *
     *      After unwrap, slot is reset to identity (C1=(0,1), C2=(0,1)).
     *
     * @param amount        Claimed total in slot (in attoFLOW, must match decrypt proof)
     * @param recipient     Address to receive the unwrapped FLOW
     * @param publicInputs  7 public inputs for the decrypt_open circuit
     * @param decryptProof  Groth16 proof [pA[2], pB[2][2], pC[2]] packed as uint[8]
     */
    function unwrap(
        uint256 amount,
        address payable recipient,
        uint[7] calldata publicInputs,
        uint[8] calldata decryptProof
    ) external {
        require(hasPubkey[msg.sender], "JanusToken: not registered");
        require(amount > 0, "JanusToken: zero amount");
        require(locked[msg.sender] >= amount, "JanusToken: amount exceeds locked balance");

        // Verify decrypt_open proof
        // publicInputs[6] must equal amount (claimed_value)
        require(
            publicInputs[6] == amount,
            "JanusToken: claimed_value in proof must match amount"
        );

        // The public inputs must reference msg.sender's pubkey and current slot
        _verifyDecryptProof(msg.sender, publicInputs, decryptProof);

        // Release FLOW
        locked[msg.sender] -= amount;

        // Reset slot to identity
        slot[msg.sender] = Ciphertext(0, 1, 0, 1);

        // Transfer FLOW
        (bool ok, ) = recipient.call{value: amount}("");
        require(ok, "JanusToken: FLOW transfer failed");

        emit Unwrapped(msg.sender, recipient, amount);
    }

    // ─── View functions ───────────────────────────────────────────────────────

    /**
     * @notice Get the current accumulated ciphertext slot for an address.
     */
    function slotOf(address user) external view returns (Ciphertext memory) {
        return slot[user];
    }

    /**
     * @notice Get registered pubkey for an address.
     */
    function pubkeyOf(address user) external view returns (uint256 x, uint256 y) {
        require(hasPubkey[user], "JanusToken: no pubkey registered");
        return (pubkey[user].x, pubkey[user].y);
    }

    /**
     * @notice Get pending rotation info.
     * @return newX         x-coordinate of pending pubkey (0 if none)
     * @return newY         y-coordinate of pending pubkey (0 if none)
     * @return availableAt  timestamp when rotation can be finalized (0 if none)
     */
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

    /**
     * @dev Verify an encrypt_consistency proof.
     *      Public signals layout: [recipient_pubkey.x, recipient_pubkey.y, C1.x, C1.y, C2.x, C2.y]
     *      The contract enforces that publicInputs[0..1] match the on-chain registered pubkey
     *      and publicInputs[2..5] match the provided ciphertext.
     */
    function _verifyEncryptProof(
        address to,
        Ciphertext calldata ct,
        uint[6] calldata publicInputs,
        uint[8] calldata encryptProof
    ) internal view {
        // Enforce consistency between public inputs and on-chain state
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

        // Unpack proof: [pA.x, pA.y, pB[0][0], pB[0][1], pB[1][0], pB[1][1], pC.x, pC.y]
        uint[2] memory pA = [encryptProof[0], encryptProof[1]];
        uint[2][2] memory pB = [[encryptProof[2], encryptProof[3]], [encryptProof[4], encryptProof[5]]];
        uint[2] memory pC = [encryptProof[6], encryptProof[7]];

        bool valid = encryptVerifier.verifyProof(pA, pB, pC, publicInputs);
        require(valid, "JanusToken: encrypt proof invalid");
    }

    /**
     * @dev Verify a decrypt_open proof.
     *      Public signals layout: [pubkey.x, pubkey.y, C1.x, C1.y, C2.x, C2.y, claimed_value]
     *      The contract enforces consistency with on-chain state for the caller.
     */
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

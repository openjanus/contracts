// SPDX-License-Identifier: MIT
// MockVerifier.sol — Configurable mock for ConfidentialTransferVerifier.
//
// Returns a pre-configured result regardless of proof inputs.
// Used in Hardhat tests to verify the JanusToken state machine independently
// of ZK proof correctness — keeps tests fast and deterministic.

pragma solidity ^0.8.20;

contract MockVerifier {
    bool private _shouldVerify;

    /// @param initialResult Initial verification result (true = accept all proofs)
    constructor(bool initialResult) {
        _shouldVerify = initialResult;
    }

    /// @notice Configure the result for subsequent verifyProof calls.
    function setResult(bool result) external {
        _shouldVerify = result;
    }

    /// @notice Mock verifyProof — ignores all inputs, returns the configured result.
    function verifyProof(
        uint[2] calldata,
        uint[2][2] calldata,
        uint[2] calldata,
        uint[6] calldata
    ) external view returns (bool) {
        return _shouldVerify;
    }
}

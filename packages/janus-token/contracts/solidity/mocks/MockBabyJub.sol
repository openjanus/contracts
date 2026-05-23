// SPDX-License-Identifier: MIT
// MockBabyJub.sol — Test mock implementing full BabyJubJub arithmetic.
//
// Identical to production BabyJub.sol logic using modexp precompile for modular inverse.
// Used in Hardhat tests instead of calling the deployed testnet contract — allows
// deterministic test vectors without network access.
//
// BabyJubJub curve parameters (over BN254 scalar field):
//   a = 168700
//   d = 168696
//   P = 21888242871839275222246405745257275088548364400416034343698204186575808495617
//
// Addition law (twisted Edwards):
//   x3 = (x1*y2 + y1*x2) / (1 + d*x1*x2*y1*y2)
//   y3 = (y1*y2 - a*x1*x2) / (1 - d*x1*x2*y1*y2)

pragma solidity ^0.8.20;

contract MockBabyJub {
    uint256 internal constant P =
        21888242871839275222246405745257275088548364400416034343698204186575808495617;
    uint256 internal constant A = 168700;
    uint256 internal constant D = 168696;

    /// @notice Twisted Edwards point addition. Identity: (0, 1).
    function babyAdd(
        uint256 x1, uint256 y1,
        uint256 x2, uint256 y2
    ) external view returns (uint256 x3, uint256 y3) {
        uint256 x1y2 = mulmod(x1, y2, P);
        uint256 y1x2 = mulmod(y1, x2, P);
        uint256 y1y2 = mulmod(y1, y2, P);
        uint256 x1x2 = mulmod(x1, x2, P);

        uint256 dx1x2y1y2 = mulmod(D, mulmod(x1x2, y1y2, P), P);

        uint256 numX = addmod(x1y2, y1x2, P);
        uint256 denX = addmod(1, dx1x2y1y2, P);

        uint256 numY = addmod(y1y2, P - mulmod(A, x1x2, P), P);
        uint256 denY = addmod(1, P - dx1x2y1y2, P);

        x3 = mulmod(numX, _modInverse(denX), P);
        y3 = mulmod(numY, _modInverse(denY), P);
    }

    /// @notice Negate a BabyJubJub point. negate(x, y) = (P - x, y).
    function negate(uint256 x, uint256 y) external pure returns (uint256 nx, uint256 ny) {
        nx = x == 0 ? 0 : P - x;
        ny = y;
    }

    /// @notice Return the identity element (0, 1).
    function identity() external pure returns (uint256 x, uint256 y) {
        return (0, 1);
    }

    function _modInverse(uint256 a) internal view returns (uint256 result) {
        require(a != 0, "MockBabyJub: inverse of zero");
        bool success;
        bytes memory input = abi.encodePacked(
            uint256(32), uint256(32), uint256(32), a, P - 2, P
        );
        bytes memory out = new bytes(32);
        assembly {
            success := staticcall(gas(), 0x05, add(input, 0x20), mload(input), add(out, 0x20), 32)
        }
        require(success, "MockBabyJub: modexp failed");
        result = abi.decode(out, (uint256));
    }
}

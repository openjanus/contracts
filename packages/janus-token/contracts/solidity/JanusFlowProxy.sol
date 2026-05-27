// SPDX-License-Identifier: MIT
//
// JanusFlowProxy.sol — ERC1967 proxy wrapper for the JanusFlow UUPS impl.
//
// Pure re-export so hardhat compiles ERC1967Proxy into the package artifacts;
// no code changes vs. the upstream OpenZeppelin contract.

pragma solidity ^0.8.20;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract JanusFlowProxy is ERC1967Proxy {
    constructor(address implementation, bytes memory data)
        ERC1967Proxy(implementation, data)
    {}
}

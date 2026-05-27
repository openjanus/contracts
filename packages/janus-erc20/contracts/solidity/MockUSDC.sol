// SPDX-License-Identifier: MIT
// EXPERIMENTAL — NOT FOR PRODUCTION
//
// MockUSDC.sol — Minimal mintable 6-decimal ERC20 for testing JanusERC20 on
// Flow EVM testnet. Flow EVM testnet does NOT have a canonical USDC, so we
// deploy our own placeholder. This is intentionally permissionlessly mintable
// for smoke tests — DO NOT reuse for mainnet.

pragma solidity ^0.8.20;

contract MockUSDC {
    string public constant name     = "Mock USD Coin";
    string public constant symbol   = "mUSDC";
    uint8  public constant decimals = 6;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    /// Permissionless mint — testnet only.
    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply   += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "MockUSDC: insufficient");
        balanceOf[msg.sender] -= amount;
        balanceOf[to]         += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "MockUSDC: insufficient");
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "MockUSDC: insufficient allowance");
        if (allowed != type(uint256).max) {
            allowance[from][msg.sender] = allowed - amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to]   += amount;
        emit Transfer(from, to, amount);
        return true;
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title Decentroneum
 * @dev Highly secure ERC-20 token with automatic allocation on deployment, ensuring transparency.
 */
contract Decentroneum is ERC20, Ownable, ReentrancyGuard {
    uint256 private constant _maxSupply = 210_000_000 * (10 ** 18);

    event OwnershipRenounced();
    event TokensAllocated(string category, address indexed recipient, uint256 amount);

    // Placeholder addresses for token allocation
    address private constant _foundingMembers = 0x39F95A20DdD14517618a954359448beE741cf82f;
    address private constant _marketing = 0x2b8E286f2E18F3e873e8dBef5EfcD3Ae78441746;
    address private constant _airdrop = 0x88a7B8C976115c7dcCe7D80186AC0FcC7A75338d;
    address private constant _projectGrowth = 0x64C15b7d89a9a72269C5DA98122cA6CC02c76338;
    address private constant _liquidity = 0xFaFB975e657f6e779FaA3fDd9e48100137144922;

    constructor() ERC20("Decentroneum", "DECETN") Ownable(msg.sender) {
        // Mint and allocate tokens
        _allocateTokens("Founding Members", _foundingMembers, (_maxSupply * 8) / 100);
        _allocateTokens("Marketing", _marketing, (_maxSupply * 12) / 100);
        _allocateTokens("Airdrop", _airdrop, (_maxSupply * 20) / 100);
        _allocateTokens("Project Growth & Reserve", _projectGrowth, (_maxSupply * 10) / 100);
        _allocateTokens("Liquidity", _liquidity, (_maxSupply * 50) / 100);
    }

    function _allocateTokens(string memory category, address recipient, uint256 amount) internal {
        require(recipient != address(0), "Invalid recipient");
        _mint(recipient, amount);
        emit TokensAllocated(category, recipient, amount);
    }

    function increaseAllowance(address spender, uint256 addedValue) public returns (bool) {
        _approve(msg.sender, spender, allowance(msg.sender, spender) + addedValue);
        return true;
    }

    function decreaseAllowance(address spender, uint256 subtractedValue) public returns (bool) {
        require(allowance(msg.sender, spender) >= subtractedValue, "Decreased allowance below zero");
        _approve(msg.sender, spender, allowance(msg.sender, spender) - subtractedValue);
        return true;
    }

    function renounceOwnership() public override onlyOwner {
        emit OwnershipRenounced();
        _transferOwnership(address(0));
    }
}

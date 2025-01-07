// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

/**
 * @title DecentTokenCreatorERC20 (Token Creator DApp)
 * This contract allows users to create their own ERC20 token with a specified name, symbol, and total supply.
 */
contract DecentTokenCreatorERC20 is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;

    mapping(address => uint256) private balances;
    mapping(address => mapping(address => uint256)) private allowances;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(string memory _name, string memory _symbol, uint256 _totalSupply, address owner)
        Ownable(msg.sender)
    {
        name = _name;
        symbol = _symbol;
        totalSupply = _totalSupply;

        // Initially, assign the total supply to the owner of the contract
        balances[owner] = totalSupply;
        emit Transfer(address(0), owner, totalSupply);

        // Transfer ownership of the contract to the given address
        transferOwnership(owner);
    }

    function balanceOf(address account) external view returns (uint256) {
        return balances[account];
    }

    function transfer(address to, uint256 value) external nonReentrant returns (bool) {
        require(to != address(0), "ERC20: transfer to the zero address");
        require(value <= balances[msg.sender], "ERC20: insufficient balance");

        _safeTransfer(msg.sender, to, value);
        return true;
    }

    function approve(address spender, uint256 value) external returns (bool) {
        allowances[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) external nonReentrant returns (bool) {
        require(to != address(0), "ERC20: transfer to the zero address");
        require(value <= balances[from], "ERC20: insufficient balance");
        require(value <= allowances[from][msg.sender], "ERC20: insufficient allowance");

        unchecked {
            allowances[from][msg.sender] -= value;
        }

        _safeTransfer(from, to, value);
        return true;
    }

    function allowance(address owner, address spender) external view returns (uint256) {
        return allowances[owner][spender];
    }

    function increaseAllowance(address spender, uint256 addedValue) external returns (bool) {
        allowances[msg.sender][spender] += addedValue;
        emit Approval(msg.sender, spender, allowances[msg.sender][spender]);
        return true;
    }

    function decreaseAllowance(address spender, uint256 subtractedValue) external returns (bool) {
        require(allowances[msg.sender][spender] >= subtractedValue, "ERC20: decreased allowance below zero");
        allowances[msg.sender][spender] -= subtractedValue;
        emit Approval(msg.sender, spender, allowances[msg.sender][spender]);
        return true;
    }

    function _safeTransfer(address from, address to, uint256 value) internal {
        balances[from] -= value;
        balances[to] += value;
        emit Transfer(from, to, value);
    }

    /**
     * @notice Renounce ownership of the contract. This will leave the contract without an owner,
     * and it will no longer be possible to call functions with the `onlyOwner` modifier.
     */
    function renounceOwnership() public override onlyOwner {
        require(totalSupply > 0, "DecentTokenCreatorERC20: Contract must have a total supply to renounce ownership");
        super.renounceOwnership();
    }
}

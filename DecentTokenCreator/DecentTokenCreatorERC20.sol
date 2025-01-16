// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

/**
 * @title DecentTokenCreatorERC20 (Token Creator DApp)
 * This contract allows users to create their own ERC20 token with a specified name, symbol, and total supply.
 */
contract DecentTokenCreatorERC20 is Ownable, ReentrancyGuard {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;

    mapping(address => uint256) private balances;
    mapping(address => mapping(address => uint256)) private allowances;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(
        string memory _name, 
        string memory _symbol, 
        uint256 _totalSupply, 
        address initialOwner
    ) Ownable(initialOwner) {
        name = _name;
        symbol = _symbol;
        totalSupply = _totalSupply;

        // Initially, assign the total supply to the specified owner
        balances[initialOwner] = totalSupply;
        emit Transfer(address(0), initialOwner, totalSupply);
    }

    function balanceOf(address account) external view returns (uint256) {
        return balances[account];
    }

    function transfer(address to, uint256 value) external nonReentrant returns (bool) {
        require(to != address(0), "ERC20: transfer to the zero address");
        require(value <= balances[msg.sender], "ERC20: insufficient balance");

        _transfer(msg.sender, to, value);
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

        allowances[from][msg.sender] -= value;
        _transfer(from, to, value);
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

    function _transfer(address from, address to, uint256 value) internal {
        balances[from] -= value;
        balances[to] += value;
        emit Transfer(from, to, value);
    }

    /**
     * @notice Renounce ownership of the contract. This will leave the contract without an owner,
     * and it will no longer be possible to call functions with the `onlyOwner` modifier.
     */
    function renounceOwnership() public override onlyOwner {
        super.renounceOwnership();
    }
}

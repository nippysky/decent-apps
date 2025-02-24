// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract TestSending is ReentrancyGuard {
    address public owner;
    uint256 public constant MAX_ADDRESSES = 1000;

    event BulkTransfer(address indexed token, address indexed sender, uint256 totalRecipients, uint256 totalAmount);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    modifier onlyOwner() {
        require(msg.sender == owner, "Not contract owner");
        _;
    }

    constructor() {
        owner = msg.sender;
    }

    function bulkSend(
        address token,
        address[] calldata recipients,
        uint256[] calldata amounts
    ) external nonReentrant {
        require(recipients.length == amounts.length, "Recipients and amounts mismatch");
        require(recipients.length > 0 && recipients.length <= MAX_ADDRESSES, "Invalid recipient count");
        
        IERC20 erc20 = IERC20(token);
        uint256 totalAmount = 0;

        for (uint256 i = 0; i < recipients.length; i++) {
            require(recipients[i] != address(0), "Invalid recipient");
            require(amounts[i] > 0, "Invalid amount");
            unchecked { totalAmount += amounts[i]; }
        }

        require(erc20.allowance(msg.sender, address(this)) >= totalAmount, "Insufficient allowance");
        require(erc20.balanceOf(msg.sender) >= totalAmount, "Insufficient balance");

        for (uint256 i = 0; i < recipients.length; i++) {
            erc20.transferFrom(msg.sender, recipients[i], amounts[i]);
        }

        emit BulkTransfer(token, msg.sender, recipients.length, totalAmount);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Invalid new owner");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }
}

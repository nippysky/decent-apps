// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract DecentLocker is ReentrancyGuard {
    using SafeMath for uint256;

    struct LockInfo {
        address tokenAddress;
        uint256 amount;
        uint256 unlockTime;
    }

    address public feeRecipient; // Wallet to receive the fees
    uint256 public feePercentage = 1; // 1% fee

    mapping(address => LockInfo[]) public lockedTokens;

    event TokensLocked(address indexed user, address tokenAddress, uint256 amount, uint256 unlockTime);
    event TokensWithdrawn(address indexed user, address tokenAddress, uint256 amount);
    event FeePaid(address indexed user, address tokenAddress, uint256 feeAmount);

    constructor(address _feeRecipient) {
        require(_feeRecipient != address(0), "Invalid fee recipient address");
        feeRecipient = _feeRecipient;
    }

    function lockTokens(address tokenAddress, uint256 amount, uint256 timeInSeconds) external nonReentrant {
        require(amount > 0, "Amount must be greater than 0");
        require(timeInSeconds > 0, "Time must be greater than 0");
        require(IERC20(tokenAddress).balanceOf(msg.sender) >= amount, "Insufficient token balance");
        require(IERC20(tokenAddress).allowance(msg.sender, address(this)) >= amount, "Allowance not set for token");

        // Calculate the fee and amount after fee
        uint256 fee = amount.mul(feePercentage).div(100);
        uint256 amountAfterFee = amount.sub(fee);

        // Transfer the fee to the feeRecipient
        bool feeTransferSuccess = IERC20(tokenAddress).transferFrom(msg.sender, feeRecipient, fee);
        require(feeTransferSuccess, "Fee transfer failed");

        // Transfer the remaining amount to the contract
        bool success = IERC20(tokenAddress).transferFrom(msg.sender, address(this), amountAfterFee);
        require(success, "Token transfer failed");

        uint256 unlockTime = block.timestamp.add(timeInSeconds);
        lockedTokens[msg.sender].push(LockInfo(tokenAddress, amountAfterFee, unlockTime));

        emit TokensLocked(msg.sender, tokenAddress, amountAfterFee, unlockTime);
        emit FeePaid(msg.sender, tokenAddress, fee);
    }

    function withdrawTokens(uint256 index) external nonReentrant {
        require(index < lockedTokens[msg.sender].length, "Invalid index");
        LockInfo memory lockInfo = lockedTokens[msg.sender][index];
        require(block.timestamp >= lockInfo.unlockTime, "Tokens are still locked");

        _removeLockedToken(msg.sender, index);

        bool success = IERC20(lockInfo.tokenAddress).transfer(msg.sender, lockInfo.amount);
        require(success, "Token transfer failed");

        emit TokensWithdrawn(msg.sender, lockInfo.tokenAddress, lockInfo.amount);
    }

    function _removeLockedToken(address user, uint256 index) internal {
        require(index < lockedTokens[user].length, "Invalid index");
        lockedTokens[user][index] = lockedTokens[user][lockedTokens[user].length - 1];
        lockedTokens[user].pop();
    }

    function getLockCount(address user) external view returns (uint256) {
        return lockedTokens[user].length;
    }

    function getLockInfo(address user, uint256 index) external view returns (address tokenAddress, uint256 amount, uint256 unlockTime) {
        require(index < lockedTokens[user].length, "Invalid index");
        LockInfo memory lockInfo = lockedTokens[user][index];
        return (lockInfo.tokenAddress, lockInfo.amount, lockInfo.unlockTime);
    }
}

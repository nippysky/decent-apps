// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract SingleVestV2 is ReentrancyGuard {
    address public token;
    address public beneficiary;

    uint256 public totalAmount;
    uint256 public released;

    uint64 public start;
    uint64 public cliff;
    uint64 public duration;

    bool public initialized;
    bytes32 public vestingHash;

    struct Unlock {
        uint64 unlockTime;
        uint256 amount;
        bool claimed;
    }
    Unlock[] public unlocks;

    event Initialized(
        address indexed token,
        address indexed beneficiary,
        uint256 totalAmount,
        uint64 start,
        uint64 cliff,
        uint64 duration,
        bytes32 vestingHash
    );
    event Claimed(
        address indexed beneficiary,
        uint256 amount,
        uint256 timestamp
    );
    event SliceClaimed(
        uint256 indexed index,
        address indexed beneficiary,
        uint256 amount,
        uint256 timestamp
    );

    modifier onlyBeneficiary() {
        require(msg.sender == beneficiary, "Not beneficiary");
        _;
    }
    modifier onlyOnce() {
        require(!initialized, "Already initialized");
        _;
    }

    function initialize(
        address _token,
        address _beneficiary,
        uint256 _totalAmount,
        uint64 _startOffset,
        uint64 _cliff,
        uint64 _duration,
        uint64[] calldata _unlockOffsets,
        uint256[] calldata _amounts
    ) external onlyOnce {
        require(_beneficiary != address(0), "Invalid beneficiary");
        require(_duration > 0, "Duration must be > 0");
        require(
            _unlockOffsets.length == _amounts.length,
            "Array length mismatch"
        );

        token = _token;
        beneficiary = _beneficiary;
        totalAmount = _totalAmount;

        start = uint64(block.timestamp + _startOffset);
        cliff = _cliff;
        duration = _duration;

        uint256 sum;
        for (uint i; i < _unlockOffsets.length; i++) {
            uint64 t = start + _unlockOffsets[i];
            require(t >= start + cliff, "Unlock before cliff");
            require(t <= start + duration, "Unlock after duration");
            sum += _amounts[i];
            unlocks.push(
                Unlock({unlockTime: t, amount: _amounts[i], claimed: false})
            );
        }
        require(sum == _totalAmount, "Unlocks do not sum to total");

        vestingHash = keccak256(
            abi.encodePacked(
                _token,
                _beneficiary,
                _totalAmount,
                _startOffset,
                _cliff,
                _duration,
                _unlockOffsets,
                _amounts
            )
        );

        initialized = true;
        emit Initialized(
            _token,
            _beneficiary,
            _totalAmount,
            start,
            cliff,
            duration,
            vestingHash
        );
    }

    function claim() external nonReentrant onlyBeneficiary {
        require(block.timestamp >= start + cliff, "Cliff not reached");
        uint256 claimable;
        for (uint i; i < unlocks.length; i++) {
            if (
                !unlocks[i].claimed && unlocks[i].unlockTime <= block.timestamp
            ) {
                claimable += unlocks[i].amount;
                unlocks[i].claimed = true;
                emit SliceClaimed(
                    i,
                    beneficiary,
                    unlocks[i].amount,
                    block.timestamp
                );
            }
        }
        require(claimable > 0, "Nothing to claim");
        released += claimable;
        require(
            IERC20(token).transfer(beneficiary, claimable),
            "Transfer failed"
        );
        emit Claimed(beneficiary, claimable, block.timestamp);
    }

    function claimSlice(uint256 index) external nonReentrant onlyBeneficiary {
        Unlock storage u = unlocks[index];
        require(!u.claimed, "Already claimed");
        require(block.timestamp >= u.unlockTime, "Not unlocked yet");
        u.claimed = true;
        released += u.amount;
        require(
            IERC20(token).transfer(beneficiary, u.amount),
            "Transfer failed"
        );
        emit SliceClaimed(index, beneficiary, u.amount, block.timestamp);
    }

    function getUnlockCount() external view returns (uint256) {
        return unlocks.length;
    }

    function getUnlock(
        uint256 index
    ) external view returns (uint64 unlockTime, uint256 amount, bool claimed) {
        Unlock storage u = unlocks[index];
        return (u.unlockTime, u.amount, u.claimed);
    }

    function getReleased() external view returns (uint256) {
        return released;
    }

    function getClaimableAmount() external view returns (uint256) {
        if (block.timestamp < start + cliff) return 0;
        uint256 unlocked;
        for (uint i; i < unlocks.length; i++) {
            if (unlocks[i].unlockTime <= block.timestamp) {
                unlocked += unlocks[i].amount;
            }
        }
        return unlocked - released;
    }

    function getRemaining() external view returns (uint256) {
        return totalAmount - released;
    }

    function getVestingDetails()
        external
        view
        returns (
            address _token,
            address _beneficiary,
            uint256 _totalAmount,
            uint256 _released,
            uint64 _start,
            uint64 _cliff,
            uint64 _duration,
            bytes32 _hash
        )
    {
        return (
            token,
            beneficiary,
            totalAmount,
            released,
            start,
            cliff,
            duration,
            vestingHash
        );
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract DecentMultiVester is ReentrancyGuard {
    address public token;
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

    struct BeneficiaryData {
        uint256 totalAmount;
        uint256 released;
        Unlock[] unlocks;
        bool exists;
    }

    mapping(address => BeneficiaryData) private beneficiaries;

    event Initialized(
        address indexed token,
        uint64 start,
        uint64 cliff,
        uint64 duration,
        bytes32 vestingHash
    );
    event BeneficiaryAdded(address indexed beneficiary, uint256 totalAmount);
    event Claimed(
        address indexed beneficiary,
        uint256 amount,
        uint256 timestamp
    );
    event SliceClaimed(
        address indexed beneficiary,
        uint256 indexed index,
        uint256 amount,
        uint256 timestamp
    );

    modifier onlyOnce() {
        require(!initialized, "Already initialized");
        _;
    }

    function initialize(
        address _token,
        uint64 _startOffset,
        uint64 _cliff,
        uint64 _duration,
        address[] calldata _beneficiaries,
        uint64[][] calldata _unlockOffsets,
        uint256[][] calldata _amounts
    ) external onlyOnce {
        require(_beneficiaries.length > 0, "No beneficiaries");
        require(
            _beneficiaries.length == _unlockOffsets.length &&
                _beneficiaries.length == _amounts.length,
            "Array length mismatch"
        );

        token = _token;
        start = uint64(block.timestamp + _startOffset);
        cliff = _cliff;
        duration = _duration;

        uint256 totalToLock;
        for (uint i; i < _beneficiaries.length; i++) {
            address ben = _beneficiaries[i];
            require(ben != address(0), "Invalid beneficiary");
            require(!beneficiaries[ben].exists, "Duplicate beneficiary");

            BeneficiaryData storage data = beneficiaries[ben];
            data.exists = true;
            data.released = 0;

            uint64[] calldata offs = _unlockOffsets[i];
            uint256[] calldata amts = _amounts[i];
            require(offs.length == amts.length, "Unlock mismatch");

            uint256 sum;
            for (uint j; j < offs.length; j++) {
                uint64 t = start + offs[j];
                require(t >= start + cliff, "Unlock before cliff");
                require(t <= start + duration, "Unlock after duration");
                sum += amts[j];
                data.unlocks.push(
                    Unlock({unlockTime: t, amount: amts[j], claimed: false})
                );
            }

            data.totalAmount = sum;
            totalToLock += sum;
            emit BeneficiaryAdded(ben, sum);
        }

        vestingHash = keccak256(
            abi.encode(
                _token,
                _startOffset,
                _cliff,
                _duration,
                _beneficiaries,
                _unlockOffsets,
                _amounts
            )
        );
        initialized = true;
        emit Initialized(_token, start, cliff, duration, vestingHash);
    }

    function claim() external nonReentrant {
        BeneficiaryData storage d = beneficiaries[msg.sender];
        require(d.exists, "Not a beneficiary");
        require(block.timestamp >= start + cliff, "Cliff not reached");

        uint256 total;
        for (uint i; i < d.unlocks.length; i++) {
            Unlock storage u = d.unlocks[i];
            if (!u.claimed && u.unlockTime <= block.timestamp) {
                u.claimed = true;
                total += u.amount;
                emit SliceClaimed(msg.sender, i, u.amount, block.timestamp);
            }
        }
        require(total > 0, "Nothing to claim");
        d.released += total;
        require(IERC20(token).transfer(msg.sender, total), "Transfer failed");
        emit Claimed(msg.sender, total, block.timestamp);
    }

    function claimSlice(uint256 index) external nonReentrant {
        BeneficiaryData storage d = beneficiaries[msg.sender];
        require(d.exists, "Not a beneficiary");
        Unlock storage u = d.unlocks[index];
        require(!u.claimed, "Already claimed");
        require(u.unlockTime <= block.timestamp, "Not unlocked yet");

        u.claimed = true;
        d.released += u.amount;
        require(
            IERC20(token).transfer(msg.sender, u.amount),
            "Transfer failed"
        );
        emit SliceClaimed(msg.sender, index, u.amount, block.timestamp);
    }

    function numUnlocks(address user) external view returns (uint256) {
        return beneficiaries[user].unlocks.length;
    }

    function getUserUnlock(
        address user,
        uint256 index
    ) external view returns (uint64 unlockTime, uint256 amount, bool claimed) {
        Unlock storage u = beneficiaries[user].unlocks[index];
        return (u.unlockTime, u.amount, u.claimed);
    }

    function getClaimableAmount(address user) external view returns (uint256) {
        BeneficiaryData storage d = beneficiaries[user];
        if (!d.exists || block.timestamp < start + cliff) {
            return 0;
        }
        uint256 unlocked;
        for (uint i; i < d.unlocks.length; i++) {
            if (d.unlocks[i].unlockTime <= block.timestamp) {
                unlocked += d.unlocks[i].amount;
            }
        }
        return unlocked - d.released;
    }

    function getGlobalVesting()
        external
        view
        returns (
            address _token,
            uint64 _start,
            uint64 _cliff,
            uint64 _duration,
            bytes32 _hash
        )
    {
        return (token, start, cliff, duration, vestingHash);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/proxy/Clones.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface ISingleVesting {
    function initialize(
        address token,
        address beneficiary,
        uint256 totalAmount,
        uint64 startOffset,
        uint64 cliff,
        uint64 duration,
        uint64[] calldata unlockOffsets,
        uint256[] calldata amounts
    ) external;
}

interface IMultiVesting {
    function initialize(
        address token,
        uint64 startOffset,
        uint64 cliff,
        uint64 duration,
        address[] calldata beneficiaries,
        uint64[][] calldata unlockOffsets,
        uint256[][] calldata amounts
    ) external;
}

contract DecentVesterFactory is Ownable {
    address public immutable singleVestingImpl;
    address public immutable multiVestingImpl;

    uint256 public feeSingle;
    uint256 public feeMulti;
    address public feeRecipient;

    /// @notice when *creator* makes a single‐vest for *beneficiary*
    event SingleVestCreated(
        address indexed creator,
        address indexed vestingContract,
        address indexed beneficiary
    );
    /// @notice when *creator* makes a multi‐vest
    event MultiVestCreated(
        address indexed creator,
        address indexed vestingContract
    );
    event FeesUpdated(uint256 feeSingle, uint256 feeMulti);
    event FeeRecipientUpdated(address feeRecipient);

    constructor(
        address _singleVestingImpl,
        address _multiVestingImpl,
        address _feeRecipient
    ) Ownable(msg.sender) {
        require(
            _singleVestingImpl != address(0) && _multiVestingImpl != address(0),
            "Invalid implementation"
        );
        require(_feeRecipient != address(0), "Invalid fee recipient");

        singleVestingImpl = _singleVestingImpl;
        multiVestingImpl = _multiVestingImpl;
        feeRecipient = _feeRecipient;
        feeSingle = 0.01 ether;
        feeMulti = 0.02 ether;
    }

    function updateFees(
        uint256 _feeSingle,
        uint256 _feeMulti
    ) external onlyOwner {
        feeSingle = _feeSingle;
        feeMulti = _feeMulti;
        emit FeesUpdated(_feeSingle, _feeMulti);
    }

    function updateFeeRecipient(address _recipient) external onlyOwner {
        require(_recipient != address(0), "Invalid recipient");
        feeRecipient = _recipient;
        emit FeeRecipientUpdated(_recipient);
    }

    function createSingleVesting(
        address token,
        address beneficiary,
        uint256 totalAmount,
        uint64 startOffset,
        uint64 cliff,
        uint64 duration,
        uint64[] calldata unlockOffsets,
        uint256[] calldata amounts
    ) external payable returns (address) {
        require(msg.value >= feeSingle, "Insufficient fee");
        payable(feeRecipient).transfer(feeSingle);

        address clone = Clones.clone(singleVestingImpl);
        IERC20(token).transferFrom(msg.sender, clone, totalAmount);

        ISingleVesting(clone).initialize(
            token,
            beneficiary,
            totalAmount,
            startOffset,
            cliff,
            duration,
            unlockOffsets,
            amounts
        );

        emit SingleVestCreated(msg.sender, clone, beneficiary);
        return clone;
    }

    function createMultiVesting(
        address token,
        uint64 startOffset,
        uint64 cliff,
        uint64 duration,
        address[] calldata beneficiaries,
        uint64[][] calldata unlockOffsets,
        uint256[][] calldata amounts
    ) external payable returns (address) {
        require(msg.value >= feeMulti, "Insufficient fee");
        payable(feeRecipient).transfer(feeMulti);

        address clone = Clones.clone(multiVestingImpl);

        uint256 totalToLock;
        for (uint256 i = 0; i < beneficiaries.length; i++) {
            for (uint256 j = 0; j < amounts[i].length; j++) {
                totalToLock += amounts[i][j];
            }
        }
        IERC20(token).transferFrom(msg.sender, clone, totalToLock);

        IMultiVesting(clone).initialize(
            token,
            startOffset,
            cliff,
            duration,
            beneficiaries,
            unlockOffsets,
            amounts
        );

        emit MultiVestCreated(msg.sender, clone);
        return clone;
    }
}

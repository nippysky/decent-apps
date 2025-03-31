// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract DecentGiver is ReentrancyGuard {
    // 1% fee in basis points
    uint256 public constant PLATFORM_FEE_BPS = 100;

    // Auto-incrementing campaign ID
    uint256 public donationCounter;

    // Address that receives 1% fees
    address public immutable feeRecipient;

    // Struct for each donation campaign
    struct Donation {
        address payable creator;
        string title;
        string description;
        uint256 goalAmount;
        uint256 deadline;
        uint256 totalRaised;
        bool withdrawn;
    }

    // Struct for each donation's individual contributor
    struct DonorInfo {
        address donor;
        uint256 amount;
    }

    // donationID => Donation struct
    mapping(uint256 => Donation) public donations;

    // donationID => array of donors
    mapping(uint256 => DonorInfo[]) public donorsOfDonation;

    // creator => array of their donation IDs
    mapping(address => uint256[]) public creatorToDonationIds;

    // Events
    event DonationCreated(
        uint256 indexed id,
        address indexed creator,
        string title,
        uint256 goal,
        uint256 deadline
    );

    event DonationReceived(
        uint256 indexed id,
        address indexed donor,
        uint256 amount,
        uint256 blockNumber
    );

    event DonationWithdrawn(
        uint256 indexed id,
        address indexed creator,
        uint256 amountAfterFee,
        uint256 fee
    );

    constructor(address _feeRecipient) {
        require(_feeRecipient != address(0), "Invalid fee address");
        feeRecipient = _feeRecipient;
    }

    modifier onlyCreator(uint256 _id) {
        require(donations[_id].creator == msg.sender, "Not creator");
        _;
    }

    modifier onlyAfterDeadline(uint256 _id) {
        require(block.timestamp >= donations[_id].deadline, "Deadline not reached");
        _;
    }

    // =================
    // CREATE A CAMPAIGN
    // =================
    function createDonation(
        string calldata _title,
        string calldata _description,
        uint256 _goalAmount,
        uint256 _durationInSeconds
    ) external {
        require(_goalAmount > 0, "Invalid goal");
        require(_durationInSeconds > 0, "Invalid duration");

        uint256 id = donationCounter++;

        donations[id] = Donation({
            creator: payable(msg.sender),
            title: _title,
            description: _description,
            goalAmount: _goalAmount,
            deadline: block.timestamp + _durationInSeconds,
            totalRaised: 0,
            withdrawn: false
        });

        creatorToDonationIds[msg.sender].push(id);

        emit DonationCreated(
            id,
            msg.sender,
            _title,
            _goalAmount,
            block.timestamp + _durationInSeconds
        );
    }

    // =============
    // DONATE TO ID
    // =============
    function donate(uint256 _id) external payable nonReentrant {
        Donation storage d = donations[_id];
        require(block.timestamp < d.deadline, "Donation expired");
        require(msg.value > 0, "Must donate > 0");

        // Increase the totalRaised
        d.totalRaised += msg.value;

        // Store donor info
        donorsOfDonation[_id].push(DonorInfo({
            donor: msg.sender,
            amount: msg.value
        }));

        // Emit event with block number for reference
        emit DonationReceived(_id, msg.sender, msg.value, block.number);
    }

    // ==========================
    // WITHDRAW AFTER DEADLINE
    // ==========================
    function withdraw(uint256 _id)
        external
        nonReentrant
        onlyCreator(_id)
        onlyAfterDeadline(_id)
    {
        Donation storage d = donations[_id];
        require(!d.withdrawn, "Already withdrawn");
        require(d.totalRaised > 0, "Nothing to withdraw");

        // Mark as withdrawn so it can't happen again
        d.withdrawn = true;

        // Calculate the 1% fee
        uint256 fee = (d.totalRaised * PLATFORM_FEE_BPS) / 10000;
        uint256 amountAfterFee = d.totalRaised - fee;

        // Transfer to the creator
        (bool sentCreator, ) = d.creator.call{value: amountAfterFee}("");
        require(sentCreator, "Transfer to creator failed");

        // Transfer the fee
        (bool sentFee, ) = payable(feeRecipient).call{value: fee}("");
        require(sentFee, "Transfer to fee recipient failed");

        emit DonationWithdrawn(_id, d.creator, amountAfterFee, fee);
    }

    // =============
    // VIEW HELPERS
    // =============
    // Return an array of campaign IDs for the connected user
    function getMyDonations() external view returns (uint256[] memory) {
        return creatorToDonationIds[msg.sender];
    }

    // Return the array of donor info for a specific campaign ID
    function getDonorsForDonation(uint256 _id) external view returns (DonorInfo[] memory) {
        return donorsOfDonation[_id];
    }
}

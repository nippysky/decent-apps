// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*
 * FeaturedAuction.sol
 *
 * One contract for both TEST and PROD:
 * - DEFAULT_DURATION (seconds) set at deploy (e.g., 30 min for test, ~28 days for prod).
 * - START_DELAY (seconds) to give UI time before a cycle starts.
 * - startNextCycleNow() or startNextCycle() use DEFAULT_DURATION automatically.
 *
 * Bidding:
 *  - First bid sets your collection address for the cycle; must >= minBidWei and beat leader (if any).
 *  - increaseBid() lets you top-up; if not leader you must strictly beat leader’s total.
 *
 * Settlement:
 *  - finalizeCycle(cycleId, refundBatch) locks the winner; optionally processes some loser refunds.
 *  - batchRefund(cycleId, maxRefunds) continues refunds safely.
 *  - withdrawTreasury(cycleId) pays winner’s total to the treasury once.
 *  - claimRefund(cycleId) lets an individual loser pull their refund after finalize.
 *
 * Security:
 *  - Ownable2Step admin, operator role for automation, Pausable, ReentrancyGuard.
 *  - No generic owner withdraw. Funds only flow as refunds or treasury payout.
 */

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract FeaturedAuction is Ownable2Step, Pausable, ReentrancyGuard {
    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/
    event OperatorChanged(address indexed oldOperator, address indexed newOperator);
    event TreasuryChanged(address indexed oldTreasury, address indexed newTreasury);

    event CycleStarted(bytes32 indexed cycleId, uint256 startAt, uint256 endAt, uint256 minBidWei);
    event BidPlaced(bytes32 indexed cycleId, address indexed bidder, address indexed collection, uint256 amountWei, uint256 newTotalWei);
    event BidIncreased(bytes32 indexed cycleId, address indexed bidder, uint256 addAmountWei, uint256 newTotalWei);
    event LeaderChanged(bytes32 indexed cycleId, address indexed newLeader, uint256 newAmountWei);
    event CycleFinalized(bytes32 indexed cycleId, address indexed winner, address indexed winnerCollection, uint256 winnerAmountWei);
    event RefundIssued(bytes32 indexed cycleId, address indexed loser, uint256 amountWei, bool success);
    event PayoutToTreasury(bytes32 indexed cycleId, address indexed treasury, uint256 amountWei, bool success);

    /*//////////////////////////////////////////////////////////////
                               ERRORS
    //////////////////////////////////////////////////////////////*/
    error Unauthorized();
    error BadParams();
    error CycleExists();
    error CycleMissing();
    error CycleNotActive();
    error CycleAlreadyFinalized();
    error TooEarly();
    error MinBidNotMet();
    error MustBeatLeader();
    error AlreadyBid();
    error NoExistingBid();
    error AlreadyRefunded();
    error AlreadyPaidTreasury();
    error ZeroAddress();

    /*//////////////////////////////////////////////////////////////
                              STRUCTS
    //////////////////////////////////////////////////////////////*/
    struct Bid {
        uint256 total;        // running total in WEI
        address collection;   // immutable per cycle (first bid sets it)
        bool exists;
        bool refunded;        // set true after refund sent
    }

    struct Cycle {
        uint256 startAt;
        uint256 endAt;
        uint256 minBidWei;

        address leader;       // highest total bidder
        uint256 leaderAmount; // highest total in WEI

        address winner;             // set at finalize
        address winnerCollection;
        uint256 winnerAmount;

        bool finalized;
        bool payoutDone;
        bool exists;

        address[] bidders;    // registry for refunds
        uint256 refundCursor; // batched refund cursor
    }

    /*//////////////////////////////////////////////////////////////
                           STORAGE & MODIFIERS
    //////////////////////////////////////////////////////////////*/
    address public operator;                 // hot wallet for automation
    address public treasury;                 // Panthart funds receiver

    uint256 public immutable DEFAULT_DURATION;
    uint256 public immutable START_DELAY;

    mapping(bytes32 => Cycle) private _cycles;
    mapping(bytes32 => mapping(address => Bid)) private _bids; // cycleId => bidder => Bid
    mapping(bytes32 => mapping(address => bool)) private _isBidder;

    modifier onlyOperatorOrOwner() {
        if (msg.sender != operator && msg.sender != owner()) revert Unauthorized();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/
    constructor(
        address _treasury,
        address _operator,
        uint256 _defaultDurationSeconds,
        uint256 _startDelaySeconds
    )
        Ownable(msg.sender) // OZ v5: pass initial owner
    {
        if (_treasury == address(0)) revert ZeroAddress();
        if (_defaultDurationSeconds == 0) revert BadParams();

        treasury = _treasury;
        operator = _operator;
        DEFAULT_DURATION = _defaultDurationSeconds;
        START_DELAY = _startDelaySeconds;

        emit TreasuryChanged(address(0), _treasury);
        emit OperatorChanged(address(0), _operator);
    }

    /*//////////////////////////////////////////////////////////////
                            ADMIN / CONFIG
    //////////////////////////////////////////////////////////////*/
    function setOperator(address _op) external onlyOwner {
        emit OperatorChanged(operator, _op);
        operator = _op;
    }

    function setTreasury(address _treasury) external onlyOwner {
        if (_treasury == address(0)) revert ZeroAddress();
        emit TreasuryChanged(treasury, _treasury);
        treasury = _treasury;
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    /*//////////////////////////////////////////////////////////////
                         CYCLE START (DURATION-BASED)
    //////////////////////////////////////////////////////////////*/

    /// Deterministic helper for UIs/cron: derive a cycleId from a planned start time.
    function computeCycleId(uint256 startAt) public view returns (bytes32) {
        return keccak256(abi.encodePacked("CYCLE:", address(this), DEFAULT_DURATION, startAt));
    }

    /// Start a new cycle that begins in START_DELAY seconds and lasts DEFAULT_DURATION.
    /// If cycleId is 0x0, a unique one is auto-generated.
    function startNextCycleNow(bytes32 cycleId, uint256 minBidWei) external onlyOperatorOrOwner {
        if (minBidWei == 0) revert BadParams();
        if (cycleId == bytes32(0)) {
            cycleId = computeCycleId(block.timestamp + START_DELAY);
        }
        uint256 startAt = block.timestamp + START_DELAY;
        uint256 endAt = startAt + DEFAULT_DURATION;
        _startCycle(cycleId, startAt, endAt, minBidWei);
    }

    /// Start a new cycle at a specific startAt, duration = DEFAULT_DURATION. endAt is computed.
    /// If cycleId is 0x0, a unique one is auto-generated.
    function startNextCycle(bytes32 cycleId, uint256 startAt, uint256 minBidWei) external onlyOperatorOrOwner {
        if (minBidWei == 0 || startAt == 0) revert BadParams();
        if (cycleId == bytes32(0)) {
            cycleId = computeCycleId(startAt);
        }
        uint256 endAt = startAt + DEFAULT_DURATION;
        _startCycle(cycleId, startAt, endAt, minBidWei);
    }

    function _startCycle(bytes32 cycleId, uint256 startAt, uint256 endAt, uint256 minBidWei) internal {
        if (_cycles[cycleId].exists) revert CycleExists();
        if (startAt >= endAt) revert BadParams();

        Cycle storage c = _cycles[cycleId];
        c.startAt = startAt;
        c.endAt = endAt;
        c.minBidWei = minBidWei;
        c.exists = true;

        emit CycleStarted(cycleId, startAt, endAt, minBidWei);
    }

    /*//////////////////////////////////////////////////////////////
                           CYCLE FINALIZATION
    //////////////////////////////////////////////////////////////*/
    function finalizeCycle(bytes32 cycleId, uint256 refundBatch)
        external
        onlyOperatorOrOwner
        nonReentrant
    {
        Cycle storage c = _requireExistingCycle(cycleId);
        if (c.finalized) revert CycleAlreadyFinalized();
        if (block.timestamp < c.endAt) revert TooEarly();

        c.finalized = true;
        c.winner = c.leader;
        c.winnerAmount = c.leaderAmount;

        if (c.winner != address(0)) {
            c.winnerCollection = _bids[cycleId][c.winner].collection;
        }

        emit CycleFinalized(cycleId, c.winner, c.winnerCollection, c.winnerAmount);

        if (refundBatch > 0) {
            _refundLosers(cycleId, refundBatch);
        }
    }

    function batchRefund(bytes32 cycleId, uint256 maxRefunds)
        external
        onlyOperatorOrOwner
        nonReentrant
    {
        _refundLosers(cycleId, maxRefunds);
    }

    /// Individual loser can claim their own refund after finalize.
    function claimRefund(bytes32 cycleId) external nonReentrant {
        Cycle storage c = _requireExistingCycle(cycleId);
        if (!c.finalized) revert CycleNotActive();

        if (msg.sender == c.winner) revert BadParams(); // winner has no refund

        Bid storage b = _bids[cycleId][msg.sender];
        if (!b.exists) revert NoExistingBid();
        if (b.refunded) revert AlreadyRefunded();

        uint256 amt = b.total;
        if (amt == 0) revert AlreadyRefunded();

        // effects first
        b.total = 0;
        b.refunded = true;

        (bool ok, ) = payable(msg.sender).call{value: amt}("");
        emit RefundIssued(cycleId, msg.sender, amt, ok);
        require(ok, "Refund failed");
    }

    function withdrawTreasury(bytes32 cycleId) external onlyOperatorOrOwner nonReentrant {
        Cycle storage c = _requireExistingCycle(cycleId);
        if (!c.finalized) revert CycleNotActive();
        if (c.payoutDone) revert AlreadyPaidTreasury();

        uint256 amt = c.winnerAmount;
        c.payoutDone = true;

        (bool ok, ) = payable(treasury).call{value: amt}("");
        emit PayoutToTreasury(cycleId, treasury, amt, ok);
        require(ok, "Treasury payout failed");
    }

    /*//////////////////////////////////////////////////////////////
                               BIDDING
    //////////////////////////////////////////////////////////////*/
    function placeBid(bytes32 cycleId, address collection) external payable whenNotPaused nonReentrant {
        if (collection == address(0)) revert BadParams();

        Cycle storage c = _requireExistingCycle(cycleId);
        if (c.finalized) revert CycleAlreadyFinalized();
        if (block.timestamp < c.startAt || block.timestamp >= c.endAt) revert CycleNotActive();

        Bid storage b = _bids[cycleId][msg.sender];
        if (b.exists) revert AlreadyBid();

        uint256 amount = msg.value;
        if (amount < c.minBidWei) revert MinBidNotMet();
        if (c.leader != address(0) && amount <= c.leaderAmount) revert MustBeatLeader();

        b.total = amount;
        b.collection = collection;
        b.exists = true;

        if (!_isBidder[cycleId][msg.sender]) {
            _isBidder[cycleId][msg.sender] = true;
            _cycles[cycleId].bidders.push(msg.sender);
        }

        emit BidPlaced(cycleId, msg.sender, collection, amount, b.total);

        c.leader = msg.sender;
        c.leaderAmount = amount;
        emit LeaderChanged(cycleId, msg.sender, amount);
    }

    function increaseBid(bytes32 cycleId) external payable whenNotPaused nonReentrant {
        Cycle storage c = _requireExistingCycle(cycleId);
        if (c.finalized) revert CycleAlreadyFinalized();
        if (block.timestamp < c.startAt || block.timestamp >= c.endAt) revert CycleNotActive();

        Bid storage b = _bids[cycleId][msg.sender];
        if (!b.exists) revert NoExistingBid();
        if (msg.value == 0) revert BadParams();

        uint256 newTotal = b.total + msg.value;

        if (msg.sender != c.leader && newTotal <= c.leaderAmount) revert MustBeatLeader();

        b.total = newTotal;

        emit BidIncreased(cycleId, msg.sender, msg.value, newTotal);

        if (newTotal > c.leaderAmount) {
            c.leader = msg.sender;
            c.leaderAmount = newTotal;
            emit LeaderChanged(cycleId, msg.sender, newTotal);
        }
    }

    /*//////////////////////////////////////////////////////////////
                                VIEWS
    //////////////////////////////////////////////////////////////*/
    function isActive(bytes32 cycleId) external view returns (bool) {
        Cycle storage c = _cycles[cycleId];
        if (!c.exists) return false;
        return !c.finalized && block.timestamp >= c.startAt && block.timestamp < c.endAt;
    }

    function getCycle(bytes32 cycleId)
        external
        view
        returns (
            uint256 startAt,
            uint256 endAt,
            uint256 minBidWei,
            address leader,
            uint256 leaderAmount,
            address winner,
            address winnerCollection,
            uint256 winnerAmount,
            bool finalized,
            bool payoutDone,
            uint256 bidderCount,
            uint256 refundCursor
        )
    {
        Cycle storage c = _cycles[cycleId];
        if (!c.exists) revert CycleMissing();
        return (
            c.startAt,
            c.endAt,
            c.minBidWei,
            c.leader,
            c.leaderAmount,
            c.winner,
            c.winnerCollection,
            c.winnerAmount,
            c.finalized,
            c.payoutDone,
            c.bidders.length,
            c.refundCursor
        );
    }

    function getBid(bytes32 cycleId, address bidder)
        external
        view
        returns (uint256 total, address collection, bool exists, bool refunded)
    {
        Bid storage b = _bids[cycleId][bidder];
        return (b.total, b.collection, b.exists, b.refunded);
    }

 function getBiddersRange(bytes32 cycleId, uint256 start, uint256 count)
    external
    view
    returns (address[] memory out)
{
    Cycle storage c = _cycles[cycleId];
    if (!c.exists) revert CycleMissing();

    uint256 len = c.bidders.length;
    if (start >= len) return new address[](0);

    uint256 take = count;
    if (start + take > len) take = len - start;

    out = new address[](take);
    for (uint256 i = 0; i < take; i++) {
        out[i] = c.bidders[start + i];
    }
}

    /*//////////////////////////////////////////////////////////////
                           INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/
    function _requireExistingCycle(bytes32 cycleId) internal view returns (Cycle storage c) {
        c = _cycles[cycleId];
        if (!c.exists) revert CycleMissing();
    }

    function _refundLosers(bytes32 cycleId, uint256 maxRefunds) internal {
        Cycle storage c = _requireExistingCycle(cycleId);
        if (!c.finalized) revert CycleNotActive();
        if (maxRefunds == 0) return;

        uint256 len = c.bidders.length;
        uint256 processed = 0;

        while (processed < maxRefunds && c.refundCursor < len) {
            address addr = c.bidders[c.refundCursor];
            c.refundCursor++;

            if (addr == c.winner) {
                // skip winner
            } else {
                Bid storage b = _bids[cycleId][addr];
                if (b.exists && !b.refunded && b.total > 0) {
                    uint256 amt = b.total;
                    b.total = 0;
                    b.refunded = true;

                    (bool ok, ) = payable(addr).call{value: amt}("");
                    emit RefundIssued(cycleId, addr, amt, ok);

                    if (!ok) { // revert state so we can retry later
                        b.total = amt;
                        b.refunded = false;
                    }
                }
            }
            processed++;
        }
    }

    /*//////////////////////////////////////////////////////////////
                              RECEIVE/RESCUE
    //////////////////////////////////////////////////////////////*/
    receive() external payable {}
    fallback() external payable {}
}

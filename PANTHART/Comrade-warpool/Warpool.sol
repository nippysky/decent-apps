// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

interface IERC721 {
    function ownerOf(uint256 tokenId) external view returns (address owner);
    function safeTransferFrom(address from, address to, uint256 tokenId) external;
}

interface IERC721Receiver {
    function onERC721Received(address operator, address from, uint256 tokenId, bytes calldata data)
        external
        returns (bytes4);
}

interface IWarpoolConfig {
    struct QueueConfig {
        bool enabled;
        bool singleEntryPerWallet;
        uint8 tier;
        uint8 mode;
        uint16 targetSize;
        uint16 minStartSize;
        uint32 openDurationSeconds;
        uint96 stakeAmount;
        uint16 platformFeeBps;
        uint16 firstPlaceBps;
        uint16 secondPlaceBps;
        uint16 thirdPlaceBps;
    }

    struct RelicConfig {
        uint16 minDiscountBps;
        uint16 maxDiscountBps;
        uint8 discountSeatCap;
        uint8 token11SeatCap;
        uint32 reservationTtlSeconds;
    }

    struct FatigueConfig {
        uint8 maxConsecutiveEntries;
        uint32 cooldownSeconds;
    }

    function workerOperator() external view returns (address);

    function comradesCollection() external view returns (address);
    function relicsCollection() external view returns (address);
    function dcntToken() external view returns (address);
    function treasury() external view returns (address);

    function entriesPaused() external view returns (bool);
    function reservationsPaused() external view returns (bool);
    function settlementsPaused() external view returns (bool);

    function relicsEnabled() external view returns (bool);
    function fatigueEnabled() external view returns (bool);
    function token11FeeShareEnabled() external view returns (bool);
    function token11FeeShareBps() external view returns (uint16);
    function configVersion() external view returns (uint64);

    function getQueueConfig(bytes32 key) external view returns (QueueConfig memory);
    function getRelicConfig() external view returns (RelicConfig memory);
    function getFatigueConfig() external view returns (FatigueConfig memory);
}

abstract contract ReentrancyGuardLite {
    uint256 private _locked = 1;

    error ReentrantCall();

    modifier nonReentrant() {
        if (_locked != 1) revert ReentrantCall();
        _locked = 2;
        _;
        _locked = 1;
    }
}

contract PanthartComradeWarpoolCore is IERC721Receiver, ReentrancyGuardLite {
    // =============================================================
    //                             ERRORS
    // =============================================================

    error Unauthorized();
    error InvalidAddress();
    error InvalidConfig();
    error InvalidState();
    error InvalidReservation();
    error InvalidWinner();
    error TokenUnavailable();
    error PoolCapacityReached();
    error TransferFailed();
    error AlreadyProcessed();
    error NotReady();

    // =============================================================
    //                             ENUMS
    // =============================================================

    enum Tier {
        NONE,
        FORGE,
        LEGION,
        CROWN
    }

    enum Mode {
        NONE,
        SAFEGUARD,
        VAULTBOUND
    }

    enum PoolState {
        NONE,
        OPEN,
        LOCKED,
        BATTLE_READY,
        SETTLING,
        SETTLED,
        CLOSED,
        EXPIRED_REFUNDED
    }

    enum EntryStatus {
        NONE,
        JOINED,
        REFUNDED,
        SELECTED,
        SETTLED,
        CAPTURED,
        RETURNED
    }

    enum ReservationStatus {
        NONE,
        ACTIVE,
        CONSUMED,
        EXPIRED,
        CANCELLED
    }

    enum RelicType {
        NONE,
        DISCOUNT,
        GOD
    }

    // =============================================================
    //                            STRUCTS
    // =============================================================

    struct Pool {
        uint64 id;
        uint64 configVersion;
        uint32 openedAt;
        uint32 expiresAt;
        uint32 lockedAt;
        uint32 seedBlockNumber;

        uint16 targetSize;
        uint16 minStartSize;
        uint16 entrantCount;
        uint16 runnableSize;

        uint8 tier;
        uint8 mode;
        uint8 state;

        bool singleEntryPerWallet;

        uint16 platformFeeBps;
        uint16 firstPlaceBps;
        uint16 secondPlaceBps;
        uint16 thirdPlaceBps;

        uint16 relicMinDiscountBps;
        uint16 relicMaxDiscountBps;

        uint8 discountSeatCap;
        uint8 token11SeatCap;

        uint16 token11FeeShareBps;

        uint96 stakeAmount;

        address comradesCollection;
        address relicsCollection;
        address dcntToken;
        address treasury;

        bytes32 queueKey;
    }

    struct Entry {
        uint64 id;
        uint64 poolId;
        uint32 joinedAt;

        address user;

        uint32 comradeTokenId;
        uint32 relicTokenId;

        uint8 relicType;
        uint8 status;
        uint8 placement;
        bool selectedForBattle;

        uint16 relicDiscountBps;

        uint96 baseStakeAmount;
        uint96 paidStakeAmount;
        uint96 refundedStakeAmount;
        uint96 prizeAmount;
    }

    struct Reservation {
        uint64 id;
        uint64 poolId;
        uint32 createdAt;
        uint32 expiresAt;

        address user;

        uint32 comradeTokenId;
        uint32 relicTokenId;

        uint8 reservationType;
        uint8 status;

        uint16 discountBps;
        uint64 nonce;
    }

    struct FighterUsage {
        uint8 consecutiveEntries;
        uint64 fatiguedUntil;
        uint64 lastSettledPoolId;
    }

    struct SettlementData {
        uint256 firstEntryId;
        uint256 secondEntryId;
        uint256 thirdEntryId;
    }

    // =============================================================
    //                           OWNERSHIP
    // =============================================================

    address public owner;
    address public pendingOwner;

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    modifier onlyWorker() {
        if (msg.sender != config.workerOperator()) revert Unauthorized();
        _;
    }

    modifier onlyOwnerOrWorker() {
        if (msg.sender != owner && msg.sender != config.workerOperator()) revert Unauthorized();
        _;
    }

    // =============================================================
    //                            STORAGE
    // =============================================================

    IWarpoolConfig public immutable config;

    uint256 public nextPoolId;
    uint256 public nextEntryId;
    uint256 public nextReservationId;

    mapping(uint256 => Pool) public pools;
    mapping(uint256 => Entry) public entries;
    mapping(uint256 => Reservation) public reservations;

    mapping(bytes32 => uint256) public activePoolByQueue;

    mapping(uint256 => mapping(uint256 => uint256)) public poolEntryIdAtIndex;
    mapping(uint256 => uint256) public poolEntryCount;

    mapping(uint256 => mapping(address => uint256)) public activeReservationByPoolAndUser;
    mapping(uint256 => mapping(address => uint256)) public walletEntryCountByPool;

    mapping(bytes32 => bool) public nftLocked;
    mapping(bytes32 => FighterUsage) public fighterUsageByKey;

    mapping(uint256 => uint8) public discountRelicSeatsUsedByPool;
    mapping(uint256 => uint8) public token11SeatsUsedByPool;
    mapping(uint256 => uint8) public discountRelicSeatsReservedByPool;

    mapping(uint256 => bool) public poolSettled;

    // =============================================================
    //                             EVENTS
    // =============================================================

    event OwnershipTransferStarted(address indexed oldOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed oldOwner, address indexed newOwner);

    event PoolOpened(
        uint256 indexed poolId,
        bytes32 indexed queueKey,
        uint8 indexed tier,
        uint8 mode,
        bool singleEntryPerWallet,
        uint16 targetSize,
        uint16 minStartSize,
        uint96 stakeAmount,
        uint32 openedAt,
        uint32 expiresAt,
        uint64 configVersion
    );

    event PoolLocked(
        uint256 indexed poolId,
        uint16 entrantCount,
        uint16 runnableSize,
        uint32 lockedAt,
        uint32 seedBlockNumber
    );

    event PoolBattleReady(uint256 indexed poolId, bytes32 bracketSeed);
    event PoolExpiredRefunded(uint256 indexed poolId, uint16 entrantCount);

    event PoolReopened(
        uint256 indexed previousPoolId,
        uint256 indexed newPoolId,
        bytes32 indexed queueKey
    );

    event RelicBonusReserved(
        uint256 indexed reservationId,
        uint256 indexed poolId,
        address indexed user,
        uint256 comradeTokenId,
        uint256 relicTokenId,
        uint16 discountBps,
        uint32 expiresAt
    );

    event ReservationConsumed(
        uint256 indexed reservationId,
        uint256 indexed poolId,
        address indexed user
    );

    event ReservationExpired(
        uint256 indexed reservationId,
        uint256 indexed poolId,
        address indexed user
    );

    event EntryJoined(
        uint256 indexed entryId,
        uint256 indexed poolId,
        address indexed user,
        uint256 comradeTokenId,
        uint256 relicTokenId,
        uint8 relicType,
        uint16 relicDiscountBps,
        uint96 baseStakeAmount,
        uint96 paidStakeAmount
    );

    event EntrySelectedForBattle(
        uint256 indexed entryId,
        uint256 indexed poolId,
        bool selected
    );

    event EntryRefunded(
        uint256 indexed entryId,
        uint256 indexed poolId,
        address indexed user,
        uint96 refundedStakeAmount
    );

    event PoolSettled(
        uint256 indexed poolId,
        uint256 firstEntryId,
        uint256 secondEntryId,
        uint256 thirdEntryId,
        uint96 totalStakeCollected,
        uint96 prizePoolAmount,
        uint96 platformFeeAmount
    );

    event CapturedComradeTransferredToWorker(
        uint256 indexed entryId,
        uint256 indexed poolId,
        address indexed worker,
        uint256 tokenId
    );

    // =============================================================
    //                         CONSTRUCTOR
    // =============================================================

    constructor(address owner_, address config_) {
        if (owner_ == address(0) || config_ == address(0)) revert InvalidAddress();

        owner = owner_;
        config = IWarpoolConfig(config_);

        nextPoolId = 1;
        nextEntryId = 1;
        nextReservationId = 1;
    }

    // =============================================================
    //                        OWNERSHIP LOGIC
    // =============================================================

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert InvalidAddress();
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert Unauthorized();
        address old = owner;
        owner = pendingOwner;
        pendingOwner = address(0);
        emit OwnershipTransferred(old, owner);
    }

    // =============================================================
    //                         CORE ACTIONS
    // =============================================================

    function openPool(bytes32 qKey) public onlyOwnerOrWorker returns (uint256 poolId) {
        uint256 current = activePoolByQueue[qKey];
        if (current != 0) {
            uint8 st = pools[current].state;
            if (st != uint8(PoolState.CLOSED) && st != uint8(PoolState.EXPIRED_REFUNDED)) {
                revert InvalidState();
            }
        }

        IWarpoolConfig.QueueConfig memory qc = config.getQueueConfig(qKey);
        if (!qc.enabled) revert InvalidConfig();
        if (qc.tier == uint8(Tier.NONE) || qc.mode == uint8(Mode.NONE)) revert InvalidConfig();
        if (!_isPowerOfTwo(qc.targetSize) || !_isPowerOfTwo(qc.minStartSize)) revert InvalidConfig();
        if (qc.minStartSize > qc.targetSize || qc.stakeAmount == 0) revert InvalidConfig();

        if (
            config.comradesCollection() == address(0) ||
            config.relicsCollection() == address(0) ||
            config.dcntToken() == address(0) ||
            config.treasury() == address(0)
        ) revert InvalidAddress();

        IWarpoolConfig.RelicConfig memory rc = config.getRelicConfig();
        if (rc.discountSeatCap > qc.targetSize || rc.token11SeatCap > qc.targetSize) {
            revert InvalidConfig();
        }

        poolId = nextPoolId++;
        Pool storage p = pools[poolId];

        p.id = uint64(poolId);
        p.configVersion = config.configVersion();
        p.openedAt = uint32(block.timestamp);
        p.expiresAt = uint32(block.timestamp + qc.openDurationSeconds);

        p.targetSize = qc.targetSize;
        p.minStartSize = qc.minStartSize;

        p.tier = qc.tier;
        p.mode = qc.mode;
        p.state = uint8(PoolState.OPEN);

        p.singleEntryPerWallet = qc.singleEntryPerWallet;

        p.platformFeeBps = qc.platformFeeBps;
        p.firstPlaceBps = qc.firstPlaceBps;
        p.secondPlaceBps = qc.secondPlaceBps;
        p.thirdPlaceBps = qc.thirdPlaceBps;

        if (config.relicsEnabled()) {
            p.relicMinDiscountBps = rc.minDiscountBps;
            p.relicMaxDiscountBps = rc.maxDiscountBps;
            p.discountSeatCap = rc.discountSeatCap;
            p.token11SeatCap = rc.token11SeatCap;
        }

        if (config.token11FeeShareEnabled()) {
            p.token11FeeShareBps = config.token11FeeShareBps();
        }

        p.stakeAmount = qc.stakeAmount;

        p.comradesCollection = config.comradesCollection();
        p.relicsCollection = config.relicsCollection();
        p.dcntToken = config.dcntToken();
        p.treasury = config.treasury();

        p.queueKey = qKey;

        activePoolByQueue[qKey] = poolId;

        emit PoolOpened(
            poolId,
            qKey,
            qc.tier,
            qc.mode,
            qc.singleEntryPerWallet,
            qc.targetSize,
            qc.minStartSize,
            qc.stakeAmount,
            p.openedAt,
            p.expiresAt,
            p.configVersion
        );
    }

    function reserveRelicBonus(
        uint256 poolId,
        uint256 comradeTokenId,
        uint256 relicTokenId
    ) external nonReentrant returns (uint256 reservationId) {
        if (config.entriesPaused() || config.reservationsPaused()) revert InvalidState();
        if (!config.relicsEnabled()) revert InvalidState();

        Pool storage p = pools[poolId];
        if (p.state != uint8(PoolState.OPEN) || !_isCrownVaultbound(p)) revert InvalidState();
        if (relicTokenId < 1 || relicTokenId > 10) revert InvalidReservation();
        if (activeReservationByPoolAndUser[poolId][msg.sender] != 0) revert AlreadyProcessed();

        _assertOwns721(p.comradesCollection, msg.sender, comradeTokenId);
        _assertOwns721(p.relicsCollection, msg.sender, relicTokenId);
        _assertFighterEligible(p.comradesCollection, comradeTokenId);

        if (
            uint256(discountRelicSeatsUsedByPool[poolId]) + uint256(discountRelicSeatsReservedByPool[poolId])
                >= p.discountSeatCap
        ) revert PoolCapacityReached();

        IWarpoolConfig.RelicConfig memory rc = config.getRelicConfig();

        reservationId = nextReservationId++;
        uint64 nonce = uint64(reservationId);

        uint16 discountBps = _computeDiscountBps(
            poolId,
            msg.sender,
            comradeTokenId,
            relicTokenId,
            nonce,
            p.relicMinDiscountBps,
            p.relicMaxDiscountBps
        );

        Reservation storage r = reservations[reservationId];
        r.id = uint64(reservationId);
        r.poolId = uint64(poolId);
        r.createdAt = uint32(block.timestamp);
        r.expiresAt = uint32(block.timestamp + rc.reservationTtlSeconds);
        r.user = msg.sender;
        r.comradeTokenId = uint32(comradeTokenId);
        r.relicTokenId = uint32(relicTokenId);
        r.reservationType = uint8(RelicType.DISCOUNT);
        r.status = uint8(ReservationStatus.ACTIVE);
        r.discountBps = discountBps;
        r.nonce = nonce;

        activeReservationByPoolAndUser[poolId][msg.sender] = reservationId;
        discountRelicSeatsReservedByPool[poolId] += 1;

        emit RelicBonusReserved(
            reservationId,
            poolId,
            msg.sender,
            comradeTokenId,
            relicTokenId,
            discountBps,
            r.expiresAt
        );
    }

    function expireReservation(uint256 reservationId) external nonReentrant {
        Reservation storage r = reservations[reservationId];
        if (r.status != uint8(ReservationStatus.ACTIVE)) revert InvalidReservation();
        if (block.timestamp <= r.expiresAt) revert NotReady();

        r.status = uint8(ReservationStatus.EXPIRED);
        activeReservationByPoolAndUser[r.poolId][r.user] = 0;

        if (discountRelicSeatsReservedByPool[r.poolId] > 0) {
            discountRelicSeatsReservedByPool[r.poolId] -= 1;
        }

        emit ReservationExpired(reservationId, r.poolId, r.user);
    }

    function enterPool(
        uint256 poolId,
        uint256 comradeTokenId,
        uint256 relicTokenId,
        uint256 reservationId
    ) external nonReentrant returns (uint256 entryId) {
        if (config.entriesPaused()) revert InvalidState();

        Pool storage p = pools[poolId];
        if (p.state != uint8(PoolState.OPEN)) revert InvalidState();
        if (block.timestamp > p.expiresAt) revert InvalidState();

        if (p.singleEntryPerWallet && walletEntryCountByPool[poolId][msg.sender] != 0) {
            revert AlreadyProcessed();
        }

        _assertOwns721(p.comradesCollection, msg.sender, comradeTokenId);
        _assertFighterEligible(p.comradesCollection, comradeTokenId);

        uint96 paidStake = p.stakeAmount;
        uint16 discountBps = 0;
        RelicType relicType = RelicType.NONE;

        if (relicTokenId != 0) {
            if (!_isCrownVaultbound(p)) revert InvalidState();
            _assertOwns721(p.relicsCollection, msg.sender, relicTokenId);

            if (relicTokenId >= 1 && relicTokenId <= 10) {
                Reservation storage r = reservations[reservationId];
                if (r.status != uint8(ReservationStatus.ACTIVE)) revert InvalidReservation();
                if (
                    r.poolId != poolId ||
                    r.user != msg.sender ||
                    r.comradeTokenId != comradeTokenId ||
                    r.relicTokenId != relicTokenId
                ) revert InvalidReservation();
                if (block.timestamp > r.expiresAt) revert InvalidReservation();

                relicType = RelicType.DISCOUNT;
                discountBps = r.discountBps;
                paidStake = uint96((uint256(p.stakeAmount) * (10_000 - discountBps)) / 10_000);

                r.status = uint8(ReservationStatus.CONSUMED);
                activeReservationByPoolAndUser[poolId][msg.sender] = 0;

                if (discountRelicSeatsReservedByPool[poolId] > 0) {
                    discountRelicSeatsReservedByPool[poolId] -= 1;
                }
                discountRelicSeatsUsedByPool[poolId] += 1;

                emit ReservationConsumed(reservationId, poolId, msg.sender);
            } else if (relicTokenId == 11) {
                if (token11SeatsUsedByPool[poolId] >= p.token11SeatCap) revert PoolCapacityReached();
                relicType = RelicType.GOD;
                paidStake = 0;
                token11SeatsUsedByPool[poolId] += 1;
            } else {
                revert InvalidReservation();
            }
        } else {
            if (reservationId != 0) revert InvalidReservation();
        }

        _lockToken(p.comradesCollection, comradeTokenId);
        IERC721(p.comradesCollection).safeTransferFrom(msg.sender, address(this), comradeTokenId);

        if (relicTokenId != 0) {
            _lockToken(p.relicsCollection, relicTokenId);
            IERC721(p.relicsCollection).safeTransferFrom(msg.sender, address(this), relicTokenId);
        }

        if (paidStake > 0) {
            if (!IERC20(p.dcntToken).transferFrom(msg.sender, address(this), paidStake)) {
                revert TransferFailed();
            }
        }

        entryId = nextEntryId++;
        Entry storage e = entries[entryId];
        e.id = uint64(entryId);
        e.poolId = uint64(poolId);
        e.joinedAt = uint32(block.timestamp);
        e.user = msg.sender;
        e.comradeTokenId = uint32(comradeTokenId);
        e.relicTokenId = uint32(relicTokenId);
        e.relicType = uint8(relicType);
        e.status = uint8(EntryStatus.JOINED);
        e.relicDiscountBps = discountBps;
        e.baseStakeAmount = p.stakeAmount;
        e.paidStakeAmount = paidStake;

        uint256 idx = poolEntryCount[poolId];
        poolEntryIdAtIndex[poolId][idx] = entryId;
        poolEntryCount[poolId] = idx + 1;
        p.entrantCount += 1;

        walletEntryCountByPool[poolId][msg.sender] += 1;

        emit EntryJoined(
            entryId,
            poolId,
            msg.sender,
            comradeTokenId,
            relicTokenId,
            uint8(relicType),
            discountBps,
            p.stakeAmount,
            paidStake
        );

        if (p.entrantCount == p.targetSize) {
            _lockFullPool(poolId);
        }
    }

    function processExpiredPool(uint256 poolId) external onlyWorker nonReentrant {
        Pool storage p = pools[poolId];
        if (p.state != uint8(PoolState.OPEN)) revert InvalidState();
        if (block.timestamp <= p.expiresAt) revert NotReady();

        uint256 count = poolEntryCount[poolId];

        if (count < p.minStartSize) {
            for (uint256 i = 0; i < count; i++) {
                uint256 entryId = poolEntryIdAtIndex[poolId][i];
                _refundEntry(p, entries[entryId], true);
            }

            p.state = uint8(PoolState.EXPIRED_REFUNDED);
            activePoolByQueue[p.queueKey] = 0;

            emit PoolExpiredRefunded(poolId, uint16(count));

            uint256 newPoolId = openPool(p.queueKey);
            emit PoolReopened(poolId, newPoolId, p.queueKey);
            return;
        }

        uint256 runnableSize = _largestPowerOfTwoLE(count);
        p.runnableSize = uint16(runnableSize);

        uint256[] memory protectedEntryIds = new uint256[](count);
        uint256 protectedCount = 0;

        for (uint256 i = 0; i < count; i++) {
            uint256 entryId = poolEntryIdAtIndex[poolId][i];
            if (entries[entryId].relicType != uint8(RelicType.NONE)) {
                protectedEntryIds[protectedCount++] = entryId;
            }
        }

        if (protectedCount > runnableSize) revert InvalidState();

        for (uint256 i = 0; i < protectedCount; i++) {
            uint256 entryId = protectedEntryIds[i];
            Entry storage e = entries[entryId];
            e.selectedForBattle = true;
            e.status = uint8(EntryStatus.SELECTED);
            emit EntrySelectedForBattle(entryId, poolId, true);
        }

        uint256 remainingSlots = runnableSize - protectedCount;

        if (remainingSlots > 0) {
            uint256 nonProtectedCount = count - protectedCount;
            uint256[] memory candidateIds = new uint256[](nonProtectedCount);
            uint256[] memory scores = new uint256[](nonProtectedCount);

            uint256 c = 0;
            for (uint256 i = 0; i < count; i++) {
                uint256 entryId = poolEntryIdAtIndex[poolId][i];
                Entry storage e = entries[entryId];
                if (e.relicType == uint8(RelicType.NONE)) {
                    candidateIds[c] = entryId;
                    scores[c] = uint256(
                        keccak256(
                            abi.encodePacked(
                                poolId,
                                p.expiresAt,
                                entryId,
                                e.user,
                                e.comradeTokenId
                            )
                        )
                    );
                    unchecked {
                        ++c;
                    }
                }
            }

            for (uint256 i = 0; i < c; i++) {
                uint256 maxIdx = i;
                for (uint256 j = i + 1; j < c; j++) {
                    if (scores[j] > scores[maxIdx]) maxIdx = j;
                }
                if (maxIdx != i) {
                    (scores[i], scores[maxIdx]) = (scores[maxIdx], scores[i]);
                    (candidateIds[i], candidateIds[maxIdx]) = (candidateIds[maxIdx], candidateIds[i]);
                }
            }

            for (uint256 i = 0; i < remainingSlots; i++) {
                Entry storage eSel = entries[candidateIds[i]];
                eSel.selectedForBattle = true;
                eSel.status = uint8(EntryStatus.SELECTED);
                emit EntrySelectedForBattle(candidateIds[i], poolId, true);
            }

            for (uint256 i = remainingSlots; i < c; i++) {
                _refundEntry(p, entries[candidateIds[i]], false);
            }
        }

        _lockSelectedPool(poolId);
    }

    function markPoolBattleReady(uint256 poolId) external onlyWorker {
        Pool storage p = pools[poolId];
        if (p.state != uint8(PoolState.LOCKED)) revert InvalidState();
        if (block.number <= p.seedBlockNumber) revert NotReady();

        p.state = uint8(PoolState.BATTLE_READY);

        bytes32 seed = keccak256(
            abi.encodePacked(
                blockhash(p.seedBlockNumber),
                poolId,
                p.entrantCount,
                p.runnableSize
            )
        );

        emit PoolBattleReady(poolId, seed);
    }

    function settlePool(uint256 poolId, SettlementData calldata data)
        external
        onlyWorker
        nonReentrant
    {
        if (config.settlementsPaused()) revert InvalidState();

        Pool storage p = pools[poolId];
        if (p.state != uint8(PoolState.BATTLE_READY)) revert InvalidState();
        if (poolSettled[poolId]) revert AlreadyProcessed();
        if (p.runnableSize < 3) revert InvalidState();

        if (data.firstEntryId == 0 || data.secondEntryId == 0 || data.thirdEntryId == 0) {
            revert InvalidWinner();
        }

        if (
            data.firstEntryId == data.secondEntryId ||
            data.firstEntryId == data.thirdEntryId ||
            data.secondEntryId == data.thirdEntryId
        ) revert InvalidWinner();

        Entry storage first = entries[data.firstEntryId];
        Entry storage second = entries[data.secondEntryId];
        Entry storage third = entries[data.thirdEntryId];

        if (first.poolId != poolId || second.poolId != poolId || third.poolId != poolId) {
            revert InvalidWinner();
        }

        if (!first.selectedForBattle || !second.selectedForBattle || !third.selectedForBattle) {
            revert InvalidWinner();
        }

        p.state = uint8(PoolState.SETTLING);
        poolSettled[poolId] = true;

        first.placement = 1;
        second.placement = 2;
        third.placement = 3;

        uint96 totalStakeCollected = _poolSelectedStakeTotal(poolId);
        uint96 platformFeeAmount = uint96((uint256(totalStakeCollected) * p.platformFeeBps) / 10_000);
        uint96 firstPrize = uint96((uint256(totalStakeCollected) * p.firstPlaceBps) / 10_000);
        uint96 secondPrize = uint96((uint256(totalStakeCollected) * p.secondPlaceBps) / 10_000);
        uint96 thirdPrize = uint96((uint256(totalStakeCollected) * p.thirdPlaceBps) / 10_000);

        uint96 prizePoolAmount = firstPrize + secondPrize + thirdPrize;
        uint96 treasuryFeeAmount = platformFeeAmount;

        uint256 token11EntryId = _findToken11SelectedEntry(poolId);
        if (token11EntryId != 0 && p.token11FeeShareBps > 0 && token11SeatsUsedByPool[poolId] > 0) {
            Entry storage god = entries[token11EntryId];
            uint96 godShare = uint96((uint256(platformFeeAmount) * p.token11FeeShareBps) / 10_000);
            treasuryFeeAmount = platformFeeAmount - godShare;

            if (godShare > 0) {
                if (!IERC20(p.dcntToken).transfer(god.user, godShare)) revert TransferFailed();
            }
        }

        if (treasuryFeeAmount > 0) {
            if (!IERC20(p.dcntToken).transfer(p.treasury, treasuryFeeAmount)) revert TransferFailed();
        }

        _payPrize(p, first, firstPrize);
        _payPrize(p, second, secondPrize);
        _payPrize(p, third, thirdPrize);

        emit PoolSettled(
            poolId,
            data.firstEntryId,
            data.secondEntryId,
            data.thirdEntryId,
            totalStakeCollected,
            prizePoolAmount,
            platformFeeAmount
        );

        uint256 count = poolEntryCount[poolId];
        for (uint256 i = 0; i < count; i++) {
            Entry storage e = entries[poolEntryIdAtIndex[poolId][i]];
            if (!e.selectedForBattle) continue;

            e.status = uint8(EntryStatus.SETTLED);
            bool isWinner = (e.placement == 1 || e.placement == 2 || e.placement == 3);

            _returnRelicIfAny(p, e);

            if (p.mode == uint8(Mode.SAFEGUARD) || isWinner) {
                _returnComrade(p, e);
            } else {
                _captureAndTransferComradeToWorker(p, e);
            }

            _updateFatigue(p, e);
        }

        p.state = uint8(PoolState.CLOSED);
        activePoolByQueue[p.queueKey] = 0;

        uint256 newPoolId = openPool(p.queueKey);
        emit PoolReopened(poolId, newPoolId, p.queueKey);
    }

    // =============================================================
    //                       INTERNAL LOGIC
    // =============================================================

    function _isPowerOfTwo(uint256 x) internal pure returns (bool) {
        return x != 0 && (x & (x - 1)) == 0;
    }

    function _largestPowerOfTwoLE(uint256 x) internal pure returns (uint256) {
        if (x == 0) revert InvalidConfig();
        uint256 p = 1;
        while ((p << 1) <= x) {
            p <<= 1;
        }
        return p;
    }

    function _tokenKey(address collection, uint256 tokenId) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(collection, tokenId));
    }

    function _isCrownVaultbound(Pool storage p) internal view returns (bool) {
        return p.tier == uint8(Tier.CROWN) && p.mode == uint8(Mode.VAULTBOUND);
    }

    function _assertOwns721(address collection, address user, uint256 tokenId) internal view {
        if (IERC721(collection).ownerOf(tokenId) != user) revert TokenUnavailable();
    }

    function _assertFighterEligible(address collection, uint256 comradeTokenId) internal view {
        bytes32 key = _tokenKey(collection, comradeTokenId);
        if (nftLocked[key]) revert TokenUnavailable();

        if (config.fatigueEnabled()) {
            FighterUsage memory fu = fighterUsageByKey[key];
            if (block.timestamp < fu.fatiguedUntil) revert TokenUnavailable();
        }
    }

    function _lockToken(address collection, uint256 tokenId) internal {
        bytes32 key = _tokenKey(collection, tokenId);
        if (nftLocked[key]) revert TokenUnavailable();
        nftLocked[key] = true;
    }

    function _unlockToken(address collection, uint256 tokenId) internal {
        nftLocked[_tokenKey(collection, tokenId)] = false;
    }

    function _computeDiscountBps(
        uint256 poolId,
        address user,
        uint256 comradeTokenId,
        uint256 relicTokenId,
        uint64 nonce,
        uint16 minBps,
        uint16 maxBps
    ) internal pure returns (uint16) {
        if (minBps == maxBps) return minBps;

        uint256 span = uint256(maxBps) - uint256(minBps) + 1;
        uint256 h = uint256(keccak256(abi.encodePacked(poolId, user, comradeTokenId, relicTokenId, nonce)));

        return uint16(uint256(minBps) + (h % span));
    }

    function _lockFullPool(uint256 poolId) internal {
        Pool storage p = pools[poolId];
        if (p.state != uint8(PoolState.OPEN)) revert InvalidState();
        if (p.entrantCount != p.targetSize) revert InvalidState();

        p.runnableSize = p.entrantCount;

        uint256 count = poolEntryCount[poolId];
        for (uint256 i = 0; i < count; i++) {
            uint256 entryId = poolEntryIdAtIndex[poolId][i];
            Entry storage e = entries[entryId];
            e.selectedForBattle = true;
            e.status = uint8(EntryStatus.SELECTED);
            emit EntrySelectedForBattle(entryId, poolId, true);
        }

        _lockSelectedPool(poolId);
    }

    function _lockSelectedPool(uint256 poolId) internal {
        Pool storage p = pools[poolId];
        if (p.state != uint8(PoolState.OPEN)) revert InvalidState();

        p.lockedAt = uint32(block.timestamp);
        p.seedBlockNumber = uint32(block.number + 1);
        p.state = uint8(PoolState.LOCKED);

        emit PoolLocked(
            poolId,
            p.entrantCount,
            p.runnableSize,
            p.lockedAt,
            p.seedBlockNumber
        );
    }

    function _refundEntry(Pool storage p, Entry storage e, bool expiredAll) internal {
        if (e.status == uint8(EntryStatus.REFUNDED)) return;

        e.status = uint8(EntryStatus.REFUNDED);
        e.refundedStakeAmount = e.paidStakeAmount;

        if (e.paidStakeAmount > 0) {
            if (!IERC20(p.dcntToken).transfer(e.user, e.paidStakeAmount)) revert TransferFailed();
        }

        IERC721(p.comradesCollection).safeTransferFrom(address(this), e.user, e.comradeTokenId);
        _unlockToken(p.comradesCollection, e.comradeTokenId);

        if (e.relicTokenId != 0) {
            IERC721(p.relicsCollection).safeTransferFrom(address(this), e.user, e.relicTokenId);
            _unlockToken(p.relicsCollection, e.relicTokenId);
        }

        emit EntryRefunded(e.id, p.id, e.user, e.refundedStakeAmount);

        if (!expiredAll) {
            emit EntrySelectedForBattle(e.id, p.id, false);
        }
    }

    function _poolSelectedStakeTotal(uint256 poolId) internal view returns (uint96 total) {
        uint256 count = poolEntryCount[poolId];
        for (uint256 i = 0; i < count; i++) {
            Entry storage e = entries[poolEntryIdAtIndex[poolId][i]];
            if (e.selectedForBattle) {
                total += e.paidStakeAmount;
            }
        }
    }

    function _findToken11SelectedEntry(uint256 poolId) internal view returns (uint256 entryId) {
        uint256 count = poolEntryCount[poolId];
        for (uint256 i = 0; i < count; i++) {
            uint256 eid = poolEntryIdAtIndex[poolId][i];
            Entry storage e = entries[eid];
            if (e.selectedForBattle && e.relicType == uint8(RelicType.GOD)) {
                return eid;
            }
        }
        return 0;
    }

    function _payPrize(Pool storage p, Entry storage e, uint96 amount) internal {
        e.prizeAmount = amount;
        if (amount > 0) {
            if (!IERC20(p.dcntToken).transfer(e.user, amount)) revert TransferFailed();
        }
    }

    function _returnRelicIfAny(Pool storage p, Entry storage e) internal {
        if (e.relicTokenId == 0) return;
        IERC721(p.relicsCollection).safeTransferFrom(address(this), e.user, e.relicTokenId);
        _unlockToken(p.relicsCollection, e.relicTokenId);
    }

    function _returnComrade(Pool storage p, Entry storage e) internal {
        e.status = uint8(EntryStatus.RETURNED);
        IERC721(p.comradesCollection).safeTransferFrom(address(this), e.user, e.comradeTokenId);
        _unlockToken(p.comradesCollection, e.comradeTokenId);
    }

    function _captureAndTransferComradeToWorker(Pool storage p, Entry storage e) internal {
        address worker = config.workerOperator();
        if (worker == address(0)) revert InvalidAddress();

        e.status = uint8(EntryStatus.CAPTURED);

        IERC721(p.comradesCollection).safeTransferFrom(address(this), worker, e.comradeTokenId);
        _unlockToken(p.comradesCollection, e.comradeTokenId);

        emit CapturedComradeTransferredToWorker(e.id, p.id, worker, e.comradeTokenId);
    }

    function _updateFatigue(Pool storage p, Entry storage e) internal {
        if (!config.fatigueEnabled()) return;

        bytes32 fighterKey = _tokenKey(p.comradesCollection, e.comradeTokenId);
        FighterUsage storage fu = fighterUsageByKey[fighterKey];
        IWarpoolConfig.FatigueConfig memory fc = config.getFatigueConfig();

        if (fu.consecutiveEntries + 1 >= fc.maxConsecutiveEntries) {
            fu.consecutiveEntries = 0;
            fu.fatiguedUntil = uint64(block.timestamp + fc.cooldownSeconds);
        } else {
            fu.consecutiveEntries += 1;
            fu.fatiguedUntil = 0;
        }

        fu.lastSettledPoolId = uint64(p.id);
    }

    // =============================================================
    //                        ADMIN RESCUE
    // =============================================================

    function rescueERC20(address token, address to, uint256 amount) external onlyOwner nonReentrant {
        if (token == config.dcntToken() || to == address(0)) revert InvalidAddress();
        if (!IERC20(token).transfer(to, amount)) revert TransferFailed();
    }

    function rescueERC721(address collection, address to, uint256 tokenId) external onlyOwner nonReentrant {
        if (
            collection == config.comradesCollection() ||
            collection == config.relicsCollection() ||
            to == address(0)
        ) revert InvalidAddress();

        IERC721(collection).safeTransferFrom(address(this), to, tokenId);
    }

    // =============================================================
    //                    ERC721 RECEIVER SUPPORT
    // =============================================================

    function onERC721Received(address, address, uint256, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        return IERC721Receiver.onERC721Received.selector;
    }
}
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract PanthartComradeWarpoolConfig {
    // =============================================================
    //                            ENUMS
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

    // =============================================================
    //                           STRUCTS
    // =============================================================

    /**
     * @notice Queue-specific rules.
     * Queue = tier + mode.
     */
    struct QueueConfig {
        bool enabled;
        bool singleEntryPerWallet;   // v1 default = true
        uint8 tier;                  // Tier enum
        uint8 mode;                  // Mode enum
        uint16 targetSize;           // must be power of 2
        uint16 minStartSize;         // must be power of 2
        uint32 openDurationSeconds;  // test: 300 / 600 ; prod: hours
        uint96 stakeAmount;          // test small, prod large
        uint16 platformFeeBps;       // fee basis points
        uint16 firstPlaceBps;        // payout bps
        uint16 secondPlaceBps;       // payout bps
        uint16 thirdPlaceBps;        // payout bps
    }

    struct RelicConfig {
        uint16 minDiscountBps;        // e.g. 1000 = 10%
        uint16 maxDiscountBps;        // e.g. 4000 = 40%
        uint8 discountSeatCap;        // normally 2
        uint8 token11SeatCap;         // normally 1
        uint32 reservationTtlSeconds; // e.g. 300
    }

    struct FatigueConfig {
        uint8 maxConsecutiveEntries;
        uint32 cooldownSeconds;
    }

    struct BattleConfig {
        uint8 roundsPerMatch;
        uint8 traitPowerMin;
        uint8 traitPowerMax;
        uint8 roundVarianceMax;
        uint8 microMomentumMax;
    }

    // =============================================================
    //                          OWNERSHIP
    // =============================================================

    address public owner;
    address public pendingOwner;

    modifier onlyOwner() {
        require(msg.sender == owner, "CFG: not owner");
        _;
    }

    // =============================================================
    //                         CORE ADDRESSES
    // =============================================================

    address public comradesCollection;
    address public relicsCollection;
    address public dcntToken;
    address public treasury;
    address public workerOperator;

    // =============================================================
    //                         GLOBAL FLAGS
    // =============================================================

    bool public entriesPaused;
    bool public reservationsPaused;
    bool public settlementsPaused;

    bool public relicsEnabled;
    bool public fatigueEnabled;
    bool public token11FeeShareEnabled;

    uint16 public token11FeeShareBps; // e.g. 5000 = 50%

    /**
     * @notice Incremented whenever a meaningful config update happens.
     * Pools snapshot this value when opened.
     */
    uint64 public configVersion;

    mapping(bytes32 => QueueConfig) private _queueConfigs;
    RelicConfig private _relicConfig;
    FatigueConfig private _fatigueConfig;
    BattleConfig private _battleConfig;

    // =============================================================
    //                            EVENTS
    // =============================================================

    event OwnershipTransferStarted(address indexed oldOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed oldOwner, address indexed newOwner);

    event ConfigAddressUpdated(bytes32 indexed field, address oldValue, address newValue, uint64 newVersion);
    event QueueConfigUpdated(bytes32 indexed queueKey, uint64 newVersion);
    event RelicConfigUpdated(uint64 newVersion);
    event FatigueConfigUpdated(uint64 newVersion);
    event BattleConfigUpdated(uint64 newVersion);

    event PauseFlagsUpdated(
        bool entriesPaused,
        bool reservationsPaused,
        bool settlementsPaused,
        uint64 newVersion
    );

    event GlobalFlagsUpdated(
        bool relicsEnabled,
        bool fatigueEnabled,
        bool token11FeeShareEnabled,
        uint16 token11FeeShareBps,
        uint64 newVersion
    );

    // =============================================================
    //                         CONSTRUCTOR
    // =============================================================

    constructor(
        address owner_,
        address comradesCollection_,
        address relicsCollection_,
        address dcntToken_,
        address treasury_,
        address workerOperator_
    ) {
        require(owner_ != address(0), "CFG: zero owner");
        require(comradesCollection_ != address(0), "CFG: zero comrades");
        require(relicsCollection_ != address(0), "CFG: zero relics");
        require(dcntToken_ != address(0), "CFG: zero dcnt");
        require(treasury_ != address(0), "CFG: zero treasury");
        require(workerOperator_ != address(0), "CFG: zero worker");

        owner = owner_;
        comradesCollection = comradesCollection_;
        relicsCollection = relicsCollection_;
        dcntToken = dcntToken_;
        treasury = treasury_;
        workerOperator = workerOperator_;

        relicsEnabled = true;
        fatigueEnabled = true;
        token11FeeShareEnabled = true;

        configVersion = 1;
    }

    // =============================================================
    //                         OWNERSHIP LOGIC
    // =============================================================

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "CFG: zero owner");
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    function acceptOwnership() external {
        require(msg.sender == pendingOwner, "CFG: not pending owner");
        address old = owner;
        owner = pendingOwner;
        pendingOwner = address(0);
        emit OwnershipTransferred(old, owner);
    }

    // =============================================================
    //                            HELPERS
    // =============================================================

    function queueKey(uint8 tier, uint8 mode) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(tier, mode));
    }

    function isValidPoolSize(uint16 size) public pure returns (bool) {
        if (size == 0) return false;
        return (size & (size - 1)) == 0;
    }

    // =============================================================
    //                           VIEW API
    // =============================================================

    function getQueueConfig(bytes32 key) external view returns (QueueConfig memory) {
        return _queueConfigs[key];
    }

    function getQueueConfigByTierMode(uint8 tier, uint8 mode) external view returns (QueueConfig memory) {
        return _queueConfigs[queueKey(tier, mode)];
    }

    function getRelicConfig() external view returns (RelicConfig memory) {
        return _relicConfig;
    }

    function getFatigueConfig() external view returns (FatigueConfig memory) {
        return _fatigueConfig;
    }

    function getBattleConfig() external view returns (BattleConfig memory) {
        return _battleConfig;
    }

    // =============================================================
    //                         ADMIN SETTERS
    // =============================================================

    function setAssetAddresses(
        address comradesCollection_,
        address relicsCollection_,
        address dcntToken_
    ) external onlyOwner {
        require(comradesCollection_ != address(0), "CFG: zero comrades");
        require(relicsCollection_ != address(0), "CFG: zero relics");
        require(dcntToken_ != address(0), "CFG: zero dcnt");

        if (comradesCollection != comradesCollection_) {
            emit ConfigAddressUpdated("COMRADES_COLLECTION", comradesCollection, comradesCollection_, ++configVersion);
            comradesCollection = comradesCollection_;
        }

        if (relicsCollection != relicsCollection_) {
            emit ConfigAddressUpdated("RELICS_COLLECTION", relicsCollection, relicsCollection_, ++configVersion);
            relicsCollection = relicsCollection_;
        }

        if (dcntToken != dcntToken_) {
            emit ConfigAddressUpdated("DCNT_TOKEN", dcntToken, dcntToken_, ++configVersion);
            dcntToken = dcntToken_;
        }
    }

    function setTreasury(address treasury_) external onlyOwner {
        require(treasury_ != address(0), "CFG: zero treasury");
        address old = treasury;
        treasury = treasury_;
        emit ConfigAddressUpdated("TREASURY", old, treasury_, ++configVersion);
    }

    function setWorkerOperator(address workerOperator_) external onlyOwner {
        require(workerOperator_ != address(0), "CFG: zero worker");
        address old = workerOperator;
        workerOperator = workerOperator_;
        emit ConfigAddressUpdated("WORKER_OPERATOR", old, workerOperator_, ++configVersion);
    }

    function setQueueConfig(bytes32 key, QueueConfig calldata cfg) external onlyOwner {
        require(cfg.tier != uint8(Tier.NONE), "CFG: bad tier");
        require(cfg.mode != uint8(Mode.NONE), "CFG: bad mode");
        require(isValidPoolSize(cfg.targetSize), "CFG: bad target");
        require(isValidPoolSize(cfg.minStartSize), "CFG: bad min start");
        require(cfg.minStartSize <= cfg.targetSize, "CFG: min > target");
        require(cfg.openDurationSeconds > 0, "CFG: zero duration");
        require(cfg.stakeAmount > 0, "CFG: zero stake");
        require(
            uint256(cfg.firstPlaceBps) +
                uint256(cfg.secondPlaceBps) +
                uint256(cfg.thirdPlaceBps) +
                uint256(cfg.platformFeeBps) == 10_000,
            "CFG: bad bps"
        );

        _queueConfigs[key] = cfg;
        emit QueueConfigUpdated(key, ++configVersion);
    }

    function setRelicConfig(RelicConfig calldata cfg) external onlyOwner {
        require(cfg.minDiscountBps <= cfg.maxDiscountBps, "CFG: min > max");
        require(cfg.maxDiscountBps <= 10_000, "CFG: max > 100%");
        require(cfg.reservationTtlSeconds > 0, "CFG: zero ttl");

        _relicConfig = cfg;
        emit RelicConfigUpdated(++configVersion);
    }

    function setFatigueConfig(FatigueConfig calldata cfg) external onlyOwner {
        require(cfg.maxConsecutiveEntries > 0, "CFG: zero max entries");
        _fatigueConfig = cfg;
        emit FatigueConfigUpdated(++configVersion);
    }

    function setBattleConfig(BattleConfig calldata cfg) external onlyOwner {
        require(cfg.roundsPerMatch > 0, "CFG: zero rounds");
        require(cfg.traitPowerMin <= cfg.traitPowerMax, "CFG: bad trait band");
        _battleConfig = cfg;
        emit BattleConfigUpdated(++configVersion);
    }

    function setGlobalFlags(
        bool relicsEnabled_,
        bool fatigueEnabled_,
        bool token11FeeShareEnabled_,
        uint16 token11FeeShareBps_
    ) external onlyOwner {
        require(token11FeeShareBps_ <= 10_000, "CFG: bad token11 share");

        relicsEnabled = relicsEnabled_;
        fatigueEnabled = fatigueEnabled_;
        token11FeeShareEnabled = token11FeeShareEnabled_;
        token11FeeShareBps = token11FeeShareBps_;

        emit GlobalFlagsUpdated(
            relicsEnabled_,
            fatigueEnabled_,
            token11FeeShareEnabled_,
            token11FeeShareBps_,
            ++configVersion
        );
    }

    function setPauseFlags(
        bool entriesPaused_,
        bool reservationsPaused_,
        bool settlementsPaused_
    ) external onlyOwner {
        entriesPaused = entriesPaused_;
        reservationsPaused = reservationsPaused_;
        settlementsPaused = settlementsPaused_;

        emit PauseFlagsUpdated(
            entriesPaused_,
            reservationsPaused_,
            settlementsPaused_,
            ++configVersion
        );
    }
}
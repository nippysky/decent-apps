// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IERC721Minimal {
    function ownerOf(uint256 tokenId) external view returns (address owner);
}

interface IWarpoolConfigLens {
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

    function entriesPaused() external view returns (bool);
    function reservationsPaused() external view returns (bool);
    function settlementsPaused() external view returns (bool);

    function relicsEnabled() external view returns (bool);
    function fatigueEnabled() external view returns (bool);
    function token11FeeShareEnabled() external view returns (bool);
    function token11FeeShareBps() external view returns (uint16);
    function configVersion() external view returns (uint64);

    function workerOperator() external view returns (address);

    function comradesCollection() external view returns (address);
    function relicsCollection() external view returns (address);
    function dcntToken() external view returns (address);
    function treasury() external view returns (address);

    function getQueueConfig(bytes32 key) external view returns (QueueConfig memory);
    function getRelicConfig() external view returns (RelicConfig memory);
}

interface ICWPTestCore {
    function config() external view returns (IWarpoolConfigLens);

    function activePoolByQueue(bytes32) external view returns (uint256);
    function poolEntryCount(uint256) external view returns (uint256);
    function poolEntryIdAtIndex(uint256, uint256) external view returns (uint256);
    function activeReservationByPoolAndUser(uint256, address) external view returns (uint256);
    function walletEntryCountByPool(uint256, address) external view returns (uint256);
    function nftLocked(bytes32) external view returns (bool);

    function discountRelicSeatsUsedByPool(uint256) external view returns (uint8);
    function discountRelicSeatsReservedByPool(uint256) external view returns (uint8);
    function token11SeatsUsedByPool(uint256) external view returns (uint8);

    function fighterUsageByKey(bytes32) external view returns (
        uint8 consecutiveEntries,
        uint64 fatiguedUntil,
        uint64 lastSettledPoolId
    );

    function pools(uint256) external view returns (
        uint64 id,
        uint64 configVersion,
        uint32 openedAt,
        uint32 expiresAt,
        uint32 lockedAt,
        uint32 seedBlockNumber,
        uint16 targetSize,
        uint16 minStartSize,
        uint16 entrantCount,
        uint16 runnableSize,
        uint8 tier,
        uint8 mode,
        uint8 state,
        bool singleEntryPerWallet,
        uint16 platformFeeBps,
        uint16 firstPlaceBps,
        uint16 secondPlaceBps,
        uint16 thirdPlaceBps,
        uint16 relicMinDiscountBps,
        uint16 relicMaxDiscountBps,
        uint8 discountSeatCap,
        uint8 token11SeatCap,
        uint16 token11FeeShareBps,
        uint96 stakeAmount,
        address comradesCollection,
        address relicsCollection,
        address dcntToken,
        address treasury,
        bytes32 queueKey
    );

    function entries(uint256) external view returns (
        uint64 id,
        uint64 poolId,
        uint32 joinedAt,
        address user,
        uint32 comradeTokenId,
        uint32 relicTokenId,
        uint8 relicType,
        uint8 status,
        uint8 placement,
        bool selectedForBattle,
        uint16 relicDiscountBps,
        uint96 baseStakeAmount,
        uint96 paidStakeAmount,
        uint96 refundedStakeAmount,
        uint96 prizeAmount
    );

    function reservations(uint256) external view returns (
        uint64 id,
        uint64 poolId,
        uint32 createdAt,
        uint32 expiresAt,
        address user,
        uint32 comradeTokenId,
        uint32 relicTokenId,
        uint8 reservationType,
        uint8 status,
        uint16 discountBps,
        uint64 nonce
    );
}

contract PanthartComradeWarpoolLens {
    uint8 internal constant TIER_CROWN = 3;
    uint8 internal constant MODE_VAULTBOUND = 2;
    uint8 internal constant STATE_OPEN = 1;
    uint8 internal constant RESERVATION_ACTIVE = 1;

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

    struct PoolSummary {
        uint256 poolId;
        bytes32 queueKey;
        uint8 tier;
        uint8 mode;
        uint8 state;
        bool singleEntryPerWallet;
        uint16 entrantCount;
        uint16 runnableSize;
        uint16 targetSize;
        uint16 minStartSize;
        uint96 stakeAmount;
        uint32 openedAt;
        uint32 expiresAt;
        uint32 lockedAt;
        uint32 seedBlockNumber;
        uint8 discountSeatsUsed;
        uint8 discountSeatsReserved;
        uint8 token11SeatsUsed;
    }

    ICWPTestCore public immutable warpool;

    constructor(address warpool_) {
        require(warpool_ != address(0), "zero warpool");
        warpool = ICWPTestCore(warpool_);
    }

    function tokenKey(address collection, uint256 tokenId) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(collection, tokenId));
    }

    function largestPowerOfTwoLE(uint256 x) public pure returns (uint256) {
        require(x > 0, "zero");
        uint256 p = 1;
        while ((p << 1) <= x) {
            p <<= 1;
        }
        return p;
    }

    function getPool(uint256 poolId) public view returns (Pool memory p) {
        (
            p.id,
            p.configVersion,
            p.openedAt,
            p.expiresAt,
            p.lockedAt,
            p.seedBlockNumber,
            p.targetSize,
            p.minStartSize,
            p.entrantCount,
            p.runnableSize,
            p.tier,
            p.mode,
            p.state,
            p.singleEntryPerWallet,
            p.platformFeeBps,
            p.firstPlaceBps,
            p.secondPlaceBps,
            p.thirdPlaceBps,
            p.relicMinDiscountBps,
            p.relicMaxDiscountBps,
            p.discountSeatCap,
            p.token11SeatCap,
            p.token11FeeShareBps,
            p.stakeAmount,
            p.comradesCollection,
            p.relicsCollection,
            p.dcntToken,
            p.treasury,
            p.queueKey
        ) = warpool.pools(poolId);
    }

    function getEntry(uint256 entryId) external view returns (Entry memory e) {
        (
            e.id,
            e.poolId,
            e.joinedAt,
            e.user,
            e.comradeTokenId,
            e.relicTokenId,
            e.relicType,
            e.status,
            e.placement,
            e.selectedForBattle,
            e.relicDiscountBps,
            e.baseStakeAmount,
            e.paidStakeAmount,
            e.refundedStakeAmount,
            e.prizeAmount
        ) = warpool.entries(entryId);
    }

    function getReservation(uint256 reservationId) external view returns (Reservation memory r) {
        (
            r.id,
            r.poolId,
            r.createdAt,
            r.expiresAt,
            r.user,
            r.comradeTokenId,
            r.relicTokenId,
            r.reservationType,
            r.status,
            r.discountBps,
            r.nonce
        ) = warpool.reservations(reservationId);
    }

    function getPoolEntryIds(uint256 poolId) external view returns (uint256[] memory ids) {
        uint256 count = warpool.poolEntryCount(poolId);
        ids = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            ids[i] = warpool.poolEntryIdAtIndex(poolId, i);
        }
    }

    function getPoolEntryIdsPaginated(
        uint256 poolId,
        uint256 start,
        uint256 limit
    ) external view returns (uint256[] memory ids) {
        require(limit > 0, "zero limit");
        uint256 count = warpool.poolEntryCount(poolId);
        if (start >= count)  return new uint256[](0);

        uint256 end = start + limit;
        if (end > count) end = count;

        ids = new uint256[](end - start);
        uint256 k = 0;
        for (uint256 i = start; i < end; i++) {
            ids[k++] = warpool.poolEntryIdAtIndex(poolId, i);
        }
    }

    function getPoolSummary(uint256 poolId) public view returns (PoolSummary memory s) {
        Pool memory p = getPool(poolId);
        s = PoolSummary({
            poolId: poolId,
            queueKey: p.queueKey,
            tier: p.tier,
            mode: p.mode,
            state: p.state,
            singleEntryPerWallet: p.singleEntryPerWallet,
            entrantCount: p.entrantCount,
            runnableSize: p.runnableSize,
            targetSize: p.targetSize,
            minStartSize: p.minStartSize,
            stakeAmount: p.stakeAmount,
            openedAt: p.openedAt,
            expiresAt: p.expiresAt,
            lockedAt: p.lockedAt,
            seedBlockNumber: p.seedBlockNumber,
            discountSeatsUsed: warpool.discountRelicSeatsUsedByPool(poolId),
            discountSeatsReserved: warpool.discountRelicSeatsReservedByPool(poolId),
            token11SeatsUsed: warpool.token11SeatsUsedByPool(poolId)
        });
    }

    function getQueueStatus(bytes32 qKey) external view returns (PoolSummary memory s) {
        uint256 poolId = warpool.activePoolByQueue(qKey);
        if (poolId == 0) return s;
        return getPoolSummary(poolId);
    }

    function getSeatUsage(uint256 poolId)
        external
        view
        returns (
            uint8 discountUsed,
            uint8 discountReserved,
            uint8 token11Used,
            uint8 discountRemaining,
            uint8 token11Remaining
        )
    {
        Pool memory p = getPool(poolId);

        discountUsed = warpool.discountRelicSeatsUsedByPool(poolId);
        discountReserved = warpool.discountRelicSeatsReservedByPool(poolId);
        token11Used = warpool.token11SeatsUsedByPool(poolId);

        uint256 discountTaken = uint256(discountUsed) + uint256(discountReserved);
        if (discountTaken >= p.discountSeatCap) {
            discountRemaining = 0;
        } else {
            discountRemaining = uint8(uint256(p.discountSeatCap) - discountTaken);
        }

        if (token11Used >= p.token11SeatCap) {
            token11Remaining = 0;
        } else {
            token11Remaining = uint8(uint256(p.token11SeatCap) - uint256(token11Used));
        }
    }

    function getActiveReservationForUser(uint256 poolId, address user) external view returns (uint256) {
        return warpool.activeReservationByPoolAndUser(poolId, user);
    }

    function isTokenLocked(address collection, uint256 tokenId) external view returns (bool) {
        return warpool.nftLocked(tokenKey(collection, tokenId));
    }

    function getFighterUsage(address collection, uint256 tokenId) external view returns (FighterUsage memory f) {
        (f.consecutiveEntries, f.fatiguedUntil, f.lastSettledPoolId) =
            warpool.fighterUsageByKey(tokenKey(collection, tokenId));
    }

    function previewRunnableSize(uint256 poolId) external view returns (uint256) {
        Pool memory p = getPool(poolId);
        uint256 count = warpool.poolEntryCount(poolId);
        if (count < p.minStartSize) return 0;
        return largestPowerOfTwoLE(count);
    }

    function canReserveRelic(
        uint256 poolId,
        address user,
        uint256 comradeTokenId,
        uint256 relicTokenId
    ) external view returns (bool ok, string memory reason) {
        IWarpoolConfigLens cfg = warpool.config();
        if (cfg.reservationsPaused()) return (false, "Reservations paused");
        if (cfg.entriesPaused()) return (false, "Entries paused");

        Pool memory p = getPool(poolId);
        if (p.state != STATE_OPEN) return (false, "Pool not open");
        if (!(p.tier == TIER_CROWN && p.mode == MODE_VAULTBOUND)) return (false, "Relics only in Crown Vaultbound");
        if (!cfg.relicsEnabled()) return (false, "Relics disabled");
        if (relicTokenId < 1 || relicTokenId > 10) return (false, "Invalid discount relic");
        if (warpool.activeReservationByPoolAndUser(poolId, user) != 0) return (false, "Active reservation exists");

        if (IERC721Minimal(p.comradesCollection).ownerOf(comradeTokenId) != user) return (false, "Not owner of Comrade");
        if (IERC721Minimal(p.relicsCollection).ownerOf(relicTokenId) != user) return (false, "Not owner of Relic");
        if (warpool.nftLocked(tokenKey(p.comradesCollection, comradeTokenId))) return (false, "Comrade locked");
        if (warpool.nftLocked(tokenKey(p.relicsCollection, relicTokenId))) return (false, "Relic locked");

        if (cfg.fatigueEnabled()) {
            (, uint64 fatiguedUntil, ) = warpool.fighterUsageByKey(tokenKey(p.comradesCollection, comradeTokenId));
            if (block.timestamp < fatiguedUntil) return (false, "Comrade fatigued");
        }

        uint256 discountTaken =
            uint256(warpool.discountRelicSeatsUsedByPool(poolId)) +
            uint256(warpool.discountRelicSeatsReservedByPool(poolId));
        if (discountTaken >= p.discountSeatCap) return (false, "Discount seats full");

        return (true, "");
    }

    function canEnterPool(
        uint256 poolId,
        address user,
        uint256 comradeTokenId,
        uint256 relicTokenId,
        uint256 reservationId
    ) external view returns (bool ok, string memory reason) {
        IWarpoolConfigLens cfg = warpool.config();
        if (cfg.entriesPaused()) return (false, "Entries paused");

        Pool memory p = getPool(poolId);
        if (p.state != STATE_OPEN) return (false, "Pool not open");
        if (block.timestamp > p.expiresAt) return (false, "Pool expired");

        if (p.singleEntryPerWallet && warpool.walletEntryCountByPool(poolId, user) > 0) {
            return (false, "Wallet already entered pool");
        }

        if (IERC721Minimal(p.comradesCollection).ownerOf(comradeTokenId) != user) return (false, "Not owner of Comrade");
        if (warpool.nftLocked(tokenKey(p.comradesCollection, comradeTokenId))) return (false, "Comrade locked");

        if (cfg.fatigueEnabled()) {
            (, uint64 fatiguedUntil, ) = warpool.fighterUsageByKey(tokenKey(p.comradesCollection, comradeTokenId));
            if (block.timestamp < fatiguedUntil) return (false, "Comrade fatigued");
        }

        if (relicTokenId == 0) {
            if (reservationId != 0) return (false, "Unexpected reservation");
            return (true, "");
        }

        if (!(p.tier == TIER_CROWN && p.mode == MODE_VAULTBOUND)) return (false, "Relics only in Crown Vaultbound");
        if (IERC721Minimal(p.relicsCollection).ownerOf(relicTokenId) != user) return (false, "Not owner of Relic");
        if (warpool.nftLocked(tokenKey(p.relicsCollection, relicTokenId))) return (false, "Relic locked");

        if (relicTokenId >= 1 && relicTokenId <= 10) {
            Reservation memory r = _reservation(reservationId);
            if (r.status != RESERVATION_ACTIVE) return (false, "Reservation not active");
            if (r.poolId != poolId) return (false, "Bad reservation pool");
            if (r.user != user) return (false, "Bad reservation user");
            if (r.comradeTokenId != comradeTokenId) return (false, "Bad reservation comrade");
            if (r.relicTokenId != relicTokenId) return (false, "Bad reservation relic");
            if (block.timestamp > r.expiresAt) return (false, "Reservation expired");
            return (true, "");
        }

        if (relicTokenId == 11) {
            if (warpool.token11SeatsUsedByPool(poolId) >= p.token11SeatCap) return (false, "Token11 seat full");
            return (true, "");
        }

        return (false, "Invalid relic");
    }

    function _reservation(uint256 reservationId) internal view returns (Reservation memory r) {
        (
            r.id,
            r.poolId,
            r.createdAt,
            r.expiresAt,
            r.user,
            r.comradeTokenId,
            r.relicTokenId,
            r.reservationType,
            r.status,
            r.discountBps,
            r.nonce
        ) = warpool.reservations(reservationId);
    }
}
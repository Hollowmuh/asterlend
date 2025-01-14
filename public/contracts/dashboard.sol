// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title GasOptimizedAnalytics
 * @notice Gas-efficient analytics tracking for lending protocol
 * @dev Uses packed storage, memory bundling, and optimized calculations
 */
contract GasOptimizedAnalytics is Ownable {
    // Packed struct for protocol metrics (1 slot)
    struct ProtocolMetrics {
        uint128 totalValueLocked;    // 16 bytes
        uint64 lastUpdateTimestamp;  // 8 bytes
        uint32 activeUsers;          // 4 bytes
        uint32 totalTransactions;    // 4 bytes
    }

    // Packed struct for asset metrics (1 slot)
    struct AssetMetrics {
        uint128 totalSupply;         // 16 bytes
        uint64 utilizationRate;      // 8 bytes
        uint64 interestRate;         // 8 bytes
    }

    // Packed struct for user metrics (1 slot)
    struct UserMetrics {
        uint128 totalBorrowed;       // 16 bytes
        uint64 healthFactor;         // 8 bytes
        uint32 lastActivity;         // 4 bytes
        uint16 transactionCount;     // 2 bytes
        bool isActive;               // 1 byte
    }

    // Storage
    mapping(uint256 => ProtocolMetrics) private dailyMetrics;
    mapping(address => mapping(uint256 => AssetMetrics)) private assetDailyMetrics;
    mapping(address => UserMetrics) private userMetrics;
    
    // Constants
    uint256 private constant UTILIZATION_PRECISION = 1e6;
    uint256 private constant SECONDS_PER_DAY = 86400;
    
    // Cached values for gas optimization
    uint256 private immutable deploymentDay;
    
    // Events with indexed parameters for efficient filtering
    event MetricsUpdated(uint256 indexed day, uint256 tvl, uint32 activeUsers);
    event UserMetricsUpdated(address indexed user, uint128 borrowed, uint64 health);

    constructor() {
        deploymentDay = block.timestamp / SECONDS_PER_DAY;
    }

    /**
     * @notice Get current day number for metrics tracking
     * @dev Gas-efficient day calculation
     */
    function getCurrentDay() public view returns (uint256) {
        return block.timestamp / SECONDS_PER_DAY - deploymentDay;
    }

    /**
     * @notice Batch update multiple metrics in a single transaction
     * @dev Uses memory bundling for gas optimization
     */
    function batchUpdateMetrics(
        uint128 newTVL,
        uint32 activeUsersCount,
        address[] calldata assets,
        uint128[] calldata supplies,
        uint64[] calldata rates
    ) external onlyOwner {
        uint256 currentDay = getCurrentDay();
        uint256 length = assets.length;
        
        // Update protocol metrics (single SSTORE)
        dailyMetrics[currentDay] = ProtocolMetrics({
            totalValueLocked: newTVL,
            lastUpdateTimestamp: uint64(block.timestamp),
            activeUsers: activeUsersCount,
            totalTransactions: dailyMetrics[currentDay].totalTransactions + 1
        });

        // Batch update asset metrics
        unchecked {
            for (uint256 i = 0; i < length; ++i) {
                AssetMetrics memory metrics = AssetMetrics({
                    totalSupply: supplies[i],
                    utilizationRate: rates[i],
                    interestRate: _calculateOptimizedInterestRate(rates[i])
                });
                assetDailyMetrics[assets[i]][currentDay] = metrics;
            }
        }

        emit MetricsUpdated(currentDay, newTVL, activeUsersCount);
    }

    /**
     * @notice Update user metrics with gas optimization
     * @dev Packs multiple updates into a single SSTORE
     */
    function updateUserMetrics(
        address user,
        uint128 borrowed,
        uint64 healthFactor
    ) external onlyOwner {
        UserMetrics storage metrics = userMetrics[user];
        
        // Pack updates into a single storage slot
        metrics.totalBorrowed = borrowed;
        metrics.healthFactor = healthFactor;
        metrics.lastActivity = uint32(block.timestamp);
        metrics.transactionCount++;
        metrics.isActive = borrowed > 0;

        emit UserMetricsUpdated(user, borrowed, healthFactor);
    }

    /**
     * @notice Get protocol metrics for a date range
     * @dev Optimized for reading multiple days
     */
    function getMetricsRange(
        uint256 fromDay,
        uint256 toDay
    ) external view returns (
        ProtocolMetrics[] memory metrics
    ) {
        require(fromDay <= toDay, "Invalid range");
        
        unchecked {
            uint256 daysCount = toDay - fromDay + 1;
            metrics = new ProtocolMetrics[](daysCount);
            
            for (uint256 i = 0; i < daysCount; ++i) {
                metrics[i] = dailyMetrics[fromDay + i];
            }
        }
    }

    /**
     * @notice Calculate optimized interest rate
     * @dev Uses bit shifts and cached values for gas efficiency
     */
    function _calculateOptimizedInterestRate(
        uint64 utilization
    ) private pure returns (uint64) {
        // Gas-efficient interest calculation using bit shifts
        if (utilization < UTILIZATION_PRECISION / 2) {
            return uint64((utilization << 1) / 100);
        }
        return uint64(((utilization * 3) >> 1) / 100);
    }

    /**
     * @notice Get user's current position health
     * @dev Cached calculation to save gas
     */
    function getUserHealth(
        address user
    ) external view returns (
        UserMetrics memory metrics,
        bool isHealthy
    ) {
        metrics = userMetrics[user];
        isHealthy = metrics.healthFactor >= 1e6;
    }

    /**
     * @notice Clean up old metrics to save storage
     * @dev Batch delete old records for gas optimization
     */
    function cleanOldMetrics(
        uint256 beforeDay,
        address[] calldata assets
    ) external onlyOwner {
        require(beforeDay < getCurrentDay(), "Cannot delete current metrics");
        
        unchecked {
            for (uint256 day = 0; day < beforeDay; ++day) {
                delete dailyMetrics[day];
                
                for (uint256 i = 0; i < assets.length; ++i) {
                    delete assetDailyMetrics[assets[i]][day];
                }
            }
        }
    }
}
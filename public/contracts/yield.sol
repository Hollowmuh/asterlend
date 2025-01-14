// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title YieldFarmingIntegration
 * @notice Manages yield farming strategies with gas optimizations
 * @dev Integrates with major yield protocols efficiently
 */
contract YieldFarmingIntegration is ReentrancyGuard, Ownable {
    // Packed storage for strategy configuration
    struct YieldStrategy {
        address yieldToken;          // Yield-bearing token address
        uint96 totalDeposited;       // Total assets in strategy
        uint96 harvestedYield;       // Total harvested yield
        uint32 lastHarvestTime;      // Last harvest timestamp
        uint16 performanceFee;       // Fee in basis points
        uint8 protocolId;            // Identifier for yield protocol
        bool active;                 // Strategy status
    }

    // Packed user position tracking
    struct UserPosition {
        uint128 depositedAmount;     // User's deposit in strategy
        uint128 accumulatedYield;    // Unclaimed yield
        uint32 lastUpdateTime;       // Last position update
        uint16 strategyCount;        // Number of active strategies
    }

    // Constants using type(uint256).max for gas optimization
    uint256 private constant BASIS_POINTS = 10000;
    uint256 private constant MAX_STRATEGIES = 10;
    uint256 private constant HARVEST_DELAY = 6 hours;

    // Storage with gas optimization in mind
    mapping(uint8 => YieldStrategy) public strategies;
    mapping(address => mapping(uint8 => UserPosition)) public userPositions;
    uint8 public activeStrategyCount;

    // Events
    event StrategyAdded(uint8 indexed strategyId, address yieldToken);
    event Deposited(address indexed user, uint8 indexed strategyId, uint256 amount);
    event YieldHarvested(uint8 indexed strategyId, uint256 amount);

    /**
     * @notice Add new yield farming strategy
     * @dev Gas-optimized strategy initialization
     */
    function addStrategy(
        address yieldToken,
        uint8 protocolId,
        uint16 performanceFee
    ) external onlyOwner {
        require(activeStrategyCount < MAX_STRATEGIES, "Too many strategies");
        require(performanceFee <= 3000, "Fee too high"); // Max 30%
        
        uint8 strategyId = activeStrategyCount++;
        
        strategies[strategyId] = YieldStrategy({
            yieldToken: yieldToken,
            totalDeposited: 0,
            harvestedYield: 0,
            lastHarvestTime: uint32(block.timestamp),
            performanceFee: performanceFee,
            protocolId: protocolId,
            active: true
        });

        emit StrategyAdded(strategyId, yieldToken);
    }

    /**
     * @notice Deposit assets into yield strategy
     * @dev Uses unchecked blocks and efficient storage updates
     */
    function deposit(
        uint8 strategyId,
        uint256 amount
    ) external nonReentrant {
        YieldStrategy storage strategy = strategies[strategyId];
        require(strategy.active, "Strategy inactive");
        
        UserPosition storage position = userPositions[msg.sender][strategyId];
        
        // Update position with unchecked math for gas savings
        unchecked {
            position.depositedAmount += uint128(amount);
            position.lastUpdateTime = uint32(block.timestamp);
            if (position.strategyCount == 0) {
                position.strategyCount = 1;
            }
            
            strategy.totalDeposited += uint96(amount);
        }

        // Transfer tokens using low-level call for gas optimization
        (bool success,) = strategy.yieldToken.call(
            abi.encodeWithSelector(
                IERC20.transferFrom.selector,
                msg.sender,
                address(this),
                amount
            )
        );
        require(success, "Transfer failed");

        emit Deposited(msg.sender, strategyId, amount);
    }

    /**
     * @notice Harvest yield from strategy
     * @dev Optimized batch processing of yields
     */
    function harvestYield(
        uint8 strategyId
    ) external nonReentrant returns (uint256 harvestedAmount) {
        YieldStrategy storage strategy = strategies[strategyId];
        require(strategy.active, "Strategy inactive");
        require(
            block.timestamp >= strategy.lastHarvestTime + HARVEST_DELAY,
            "Too soon"
        );

        // Calculate yield using protocol-specific logic
        harvestedAmount = _calculateYield(strategyId);
        
        unchecked {
            strategy.harvestedYield += uint96(harvestedAmount);
            strategy.lastHarvestTime = uint32(block.timestamp);
        }

        // Process fees
        uint256 fee = (harvestedAmount * strategy.performanceFee) / BASIS_POINTS;
        uint256 netYield = harvestedAmount - fee;

        emit YieldHarvested(strategyId, harvestedAmount);
        
        // Distribute yield using low-level calls for gas optimization
        _distributeYield(strategyId, netYield);
    }

    /**
     * @notice Calculate yield for a strategy
     * @dev Protocol-specific yield calculation
     */
    function _calculateYield(
        uint8 strategyId
    ) private view returns (uint256) {
        YieldStrategy storage strategy = strategies[strategyId];
        
        // Protocol-specific yield calculation logic
        if (strategy.protocolId == 1) { // Example: Compound
            return _calculateCompoundYield(strategy);
        } else if (strategy.protocolId == 2) { // Example: Aave
            return _calculateAaveYield(strategy);
        }
        
        return 0;
    }

    /**
     * @notice Distribute yield to users
     * @dev Gas-optimized batch distribution
     */
    function _distributeYield(
        uint8 strategyId,
        uint256 netYield
    ) private {
        YieldStrategy storage strategy = strategies[strategyId];
        
        // Calculate yield per token
        uint256 yieldPerToken = (netYield * 1e18) / strategy.totalDeposited;
        
        // Update user positions in batch
        address[] memory users = _getActiveUsers(strategyId);
        
        unchecked {
            for (uint256 i = 0; i < users.length; ++i) {
                UserPosition storage position = userPositions[users[i]][strategyId];
                uint256 userYield = (position.depositedAmount * yieldPerToken) / 1e18;
                position.accumulatedYield += uint128(userYield);
            }
        }
    }

    /**
     * @notice Get active users for a strategy
     * @dev Cached reading for gas optimization
     */
    function _getActiveUsers(
        uint8 strategyId
    ) private view returns (address[] memory) {
        // Implementation depends on how user tracking is done
        // This is a placeholder for the actual implementation
        return new address[](0);
    }

    /**
     * @notice Calculate Compound protocol yield
     * @dev Protocol-specific yield calculation
     */
    function _calculateCompoundYield(
        YieldStrategy storage strategy
    ) private view returns (uint256) {
        // Compound-specific yield calculation
        // This is a placeholder for the actual implementation
        return 0;
    }

    /**
     * @notice Calculate Aave protocol yield
     * @dev Protocol-specific yield calculation
     */
    function _calculateAaveYield(
        YieldStrategy storage strategy
    ) private view returns (uint256) {
        // Aave-specific yield calculation
        // This is a placeholder for the actual implementation
        return 0;
    }
}
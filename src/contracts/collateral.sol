// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "@chainlink/contracts/src/v0.8/automation/AutomationCompatible.sol";

// Custom errors for gas optimization
error InvalidToken();
error InvalidAmount();
error UnauthorizedAccess();
error StalePrice();
error PriceFeedNotFound();
error InvalidLiquidation();
error InsufficientCollateral();
error NoLiquidatableLoans();
error AlreadyInitialized();
error InvalidHealthFactor();

/**
 * @title CollateralManager
 * @notice Gas-optimized collateral management system
 */
contract CollateralManager is ReentrancyGuard, Ownable, AutomationCompatibleInterface {
    using Math for uint256;

    // Constants using immutable for gas savings
    uint256 private immutable BASIS_POINTS = 10000;
    uint256 private immutable LIQUIDATION_THRESHOLD = 125; // 125%
    uint256 private immutable LIQUIDATION_BONUS = 500; // 5%
    uint256 private immutable MAX_LIQUIDATION_DISCOUNT = 1000; // 10%
    uint256 private immutable PRICE_PRECISION = 8;
    uint256 private immutable STALENESS_PERIOD = 1 hours;
    uint256 private immutable MIN_HEALTH_FACTOR = 125; // 1.25
    uint256 private immutable MAX_LIQUIDATIONS_PER_TX = 5;

    // Packed structs for gas optimization
    struct CollateralInfo {
        uint128 amount;          // Pack these together in one slot
        uint128 lastUpdate;
        address token;           // New slot
        address borrower;
        bool isActive;           // Pack with extra space from above
        uint8 healthFactor;      // Pack with isActive
    }

    struct PriceFeed {
        uint128 price;           // Pack these together
        uint128 lastUpdate;
        bool isActive;           // New slot
        AggregatorV3Interface feed;
    }

    struct LiquidationCandidate {
        uint256 loanId;
        uint256 debtToCover;
        uint128 collateralAmount;
        uint8 healthFactor;
        address borrower;
        bool processed;
    }

    // State variables
    address public marketplace;
    mapping(uint256 => CollateralInfo) public collaterals;
    mapping(address => PriceFeed) private priceFeeds;
    mapping(uint256 => bool) private liquidatedLoans;
    
    // Cache for gas optimization
    LiquidationCandidate[] private liquidationQueue;
    uint256 private lastProcessedIndex;

    // Events
    event CollateralDeposited(uint256 indexed loanId, address token, uint256 amount);
    event CollateralReleased(uint256 indexed loanId, address borrower, uint256 amount);
    event PriceUpdated(address indexed token, uint256 price, uint256 timestamp);
    event LiquidationQueued(uint256 indexed loanId, uint256 timestamp);
    event LiquidationProcessed(
        uint256 indexed loanId, 
        address liquidator, 
        uint256 debtCovered, 
        uint256 collateralReceived
    );

    constructor() Ownable(msg.sender) {}

    // Setup functions
    function setMarketplace(address _marketplace) external onlyOwner {
        if (_marketplace == address(0)) revert InvalidToken();
        if (marketplace != address(0)) revert AlreadyInitialized();
        marketplace = _marketplace;
    }

    function setPriceFeed(address token, address feed) external onlyOwner {
        if (token == address(0) || feed == address(0)) revert InvalidToken();
        
        priceFeeds[token] = PriceFeed({
            price: 0,
            lastUpdate: uint128(block.timestamp),
            isActive: true,
            feed: AggregatorV3Interface(feed)
        });
    }

    // Core functions with gas optimizations
    function initializeLoan(
        uint256 loanId,
        address borrower,
        address token,
        uint256 amount
    ) external {
        if (msg.sender != marketplace) revert UnauthorizedAccess();
        if (amount == 0) revert InvalidAmount();
        
        collaterals[loanId] = CollateralInfo({
            amount: uint128(amount),
            lastUpdate: uint128(block.timestamp),
            token: token,
            borrower: borrower,
            isActive: true,
            healthFactor: uint8(MIN_HEALTH_FACTOR)
        });

        emit CollateralDeposited(loanId, token, amount);
    }

    function releaseLoanCollateral(uint256 loanId, address borrower) external nonReentrant {
        if (msg.sender != marketplace) revert UnauthorizedAccess();
        
        CollateralInfo storage collateral = collaterals[loanId];
        if (!collateral.isActive || collateral.borrower != borrower) revert UnauthorizedAccess();

        uint256 amount = collateral.amount;
        collateral.isActive = false;
        collateral.amount = 0;

        IERC20(collateral.token).transfer(borrower, amount);
        emit CollateralReleased(loanId, borrower, amount);
    }

    // Price update optimization using batch processing
    function updatePrices(address[] calldata tokens) external returns (bool[] memory) {
        bool[] memory updated = new bool[](tokens.length);
        
        for (uint256 i = 0; i < tokens.length;) {
            updated[i] = _updateSinglePrice(tokens[i]);
            // Gas optimization using unchecked
            unchecked { ++i; }
        }
        
        return updated;
    }

    // Internal price update with minimal gas usage
    function _updateSinglePrice(address token) internal returns (bool) {
        PriceFeed storage priceFeed = priceFeeds[token];
        if (!priceFeed.isActive) return false;

        try priceFeed.feed.latestRoundData() returns (
            uint80 roundId,
            int256 price,
            uint256,
            uint256 updatedAt,
            uint80 answeredInRound
        ) {
            if (price <= 0 || updatedAt == 0 || answeredInRound < roundId) return false;
            
            priceFeed.price = uint128(uint256(price));
            priceFeed.lastUpdate = uint128(block.timestamp);
            
            emit PriceUpdated(token, uint256(price), block.timestamp);
            return true;
        } catch {
            return false;
        }
    }

    // Chainlink Automation with gas optimization
    function checkUpkeep(bytes calldata)
        external
        view
        override
        returns (bool upkeepNeeded, bytes memory performData)
    {
        uint256 queueLength = liquidationQueue.length;
        if (queueLength == 0 || lastProcessedIndex >= queueLength) {
            return (false, "");
        }

        uint256 batchSize = _calculateBatchSize(queueLength);
        return (true, abi.encode(batchSize));
    }

    function performUpkeep(bytes calldata performData) external override {
        uint256 batchSize = abi.decode(performData, (uint256));
        _processBatchLiquidations(batchSize);
    }

    // Liquidation processing with batch optimization
    function _processBatchLiquidations(uint256 batchSize) internal {
        uint256 endIndex = Math.min(
            lastProcessedIndex + batchSize,
            liquidationQueue.length
        );

        for (uint256 i = lastProcessedIndex; i < endIndex;) {
            LiquidationCandidate storage candidate = liquidationQueue[i];
            
            if (!candidate.processed && _isLiquidatable(candidate)) {
                _executeLiquidation(candidate);
                candidate.processed = true;
            }

            unchecked { ++i; }
        }

        lastProcessedIndex = endIndex;
    }

    // Optimized liquidation check
    function _isLiquidatable(LiquidationCandidate memory candidate) internal view returns (bool) {
        CollateralInfo storage collateral = collaterals[candidate.loanId];
        if (!collateral.isActive) return false;

        uint256 currentPrice = priceFeeds[collateral.token].price;
        uint256 collateralValue = uint256(collateral.amount)*(currentPrice)/(10**PRICE_PRECISION);
        
        return collateralValue*(100) < candidate.debtToCover*(uint256(collateral.healthFactor));
    }

    // Gas-efficient liquidation execution
    function _executeLiquidation(LiquidationCandidate memory candidate) internal {
        CollateralInfo storage collateral = collaterals[candidate.loanId];
        
        uint256 collateralPrice = priceFeeds[collateral.token].price;
        uint256 collateralValue = uint256(collateral.amount)*(collateralPrice)/(10**PRICE_PRECISION);
        
        //uint256 bonusAmount = candidate.debtToCover*(LIQUIDATION_BONUS)/(BASIS_POINTS);
        uint256 totalCollateralToLiquidator = collateralValue*(
            Math.min(BASIS_POINTS + LIQUIDATION_BONUS, BASIS_POINTS + MAX_LIQUIDATION_DISCOUNT)
        )/(BASIS_POINTS);

        collateral.isActive = false;
        liquidatedLoans[candidate.loanId] = true;

        IERC20(collateral.token).transfer(msg.sender, totalCollateralToLiquidator);

        emit LiquidationProcessed(
            candidate.loanId,
            msg.sender,
            candidate.debtToCover,
            totalCollateralToLiquidator
        );
    }

    // Utility functions
    function _calculateBatchSize(uint256 queueLength) internal view returns (uint256) {
        return Math.min(
            MAX_LIQUIDATIONS_PER_TX,
            queueLength - lastProcessedIndex
        );
    }

    // View functions with minimal gas usage
    function getCollateralValue(
        address token,
        uint256 amount
    ) external view returns (uint256) {
        PriceFeed storage priceFeed = priceFeeds[token];
        if (!priceFeed.isActive) revert PriceFeedNotFound();
        
        return uint256(priceFeed.price)
            *(amount)
            /(10 ** PRICE_PRECISION);
    }

    function getLiquidationQueue() external view returns (
        uint256[] memory loanIds,
        address[] memory borrowers,
        uint256[] memory amounts
    ) {
        uint256 length = liquidationQueue.length;
        loanIds = new uint256[](length);
        borrowers = new address[](length);
        amounts = new uint256[](length);

        for (uint256 i = 0; i < length;) {
            LiquidationCandidate memory candidate = liquidationQueue[i];
            loanIds[i] = candidate.loanId;
            borrowers[i] = candidate.borrower;
            amounts[i] = candidate.collateralAmount;
            unchecked { ++i; }
        }
    }
}
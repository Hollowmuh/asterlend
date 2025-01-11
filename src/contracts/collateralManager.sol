// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

error StalePrice();
error InvalidPrice();
error InvalidOracle();
error InvalidCollateral();
error InvalidParameter();
error NoCollateralDeposited();
error InsufficientCollateral();
error TransferFailed();
error Unauthorized();
error CollateralDisabled();

/**
 * @title CollateralManager
 * @dev Gas-optimized collateral management with real-time price feeds
 */
contract CollateralManager is Ownable, ReentrancyGuard {
    // Packed structs for gas optimization
    struct CollateralConfig {
        IERC20 token;                    // 20 bytes
        AggregatorV3Interface priceFeed; // 20 bytes
        uint32 liquidationThreshold;      // 4 bytes (stores basis points)
        uint32 minimumCollateral;         // 4 bytes
        uint8 priceDecimals;             // 1 byte
        uint8 tokenDecimals;             // 1 byte
        bool enabled;                     // 1 byte
        uint48 lastUpdateBlock;           // 6 bytes
    }                                    // Total: 2 slots (64 bytes)

    struct CollateralPosition {
        uint192 amount;                  // 24 bytes
        uint64 lastUpdateTime;           // 8 bytes
    }                                    // Total: 1 slot (32 bytes)

    // Constants using type(uint256).max for gas optimization
    uint256 private constant BASIS_POINTS = 10000;
    uint32 private constant MAX_LIQUIDATION_THRESHOLD = 9500; // 95%
    uint32 private constant MIN_LIQUIDATION_THRESHOLD = 5000; // 50%
    uint48 private constant PRICE_FRESHNESS_BLOCKS = 50; // ~10 mins at 12 sec blocks
    
    // Immutable state variables for gas savings
    address public immutable lendingPool;
    uint256 private immutable deploymentBlock;
    
    // Storage
    mapping(address => CollateralConfig) private collateralConfigs;
    mapping(address => mapping(address => CollateralPosition)) private userCollateral;
    mapping(address => uint256) private collateralIndex; // 1-based index for exists check
    address[] private collateralList;

    // Events with indexed parameters for efficient filtering
    event CollateralDeposited(address indexed user, address indexed token, uint256 amount);
    event CollateralWithdrawn(address indexed user, address indexed token, uint256 amount);
    event CollateralLiquidated(address indexed user, address indexed token, uint256 amount, uint256 price);
    event CollateralConfigUpdated(address indexed token, uint32 liquidationThreshold, uint32 minimumCollateral);
    event CollateralStatusUpdated(address indexed token, bool enabled);

    modifier onlyLendingPool() {
        if (msg.sender != lendingPool) revert Unauthorized();
        _;
    }

    modifier validCollateral(address token) {
        if (!_isValidCollateral(token)) revert InvalidCollateral();
        _;
    }

    constructor(address _lendingPool) {
        if (_lendingPool == address(0)) revert InvalidOracle();
        lendingPool = _lendingPool;
        deploymentBlock = block.number;
    }

    /**
     * @dev Gas-efficient collateral validation
     */
    function _isValidCollateral(address token) internal view returns (bool) {
        return collateralConfigs[token].enabled && address(collateralConfigs[token].token) != address(0);
    }

    /**
     * @dev Optimized collateral configuration
     */
    function setCollateralConfig(
        address token,
        address oracle,
        uint32 liquidationThreshold,
        uint32 minimumCollateral
    ) external onlyOwner {
        if (token == address(0) || oracle == address(0)) revert InvalidOracle();
        if (liquidationThreshold > MAX_LIQUIDATION_THRESHOLD || 
            liquidationThreshold < MIN_LIQUIDATION_THRESHOLD) revert InvalidParameter();

        AggregatorV3Interface priceFeed = AggregatorV3Interface(oracle);
        IERC20 collateralToken = IERC20(token);
        
        // Gas optimization: Only push to array if new collateral
        if (collateralIndex[token] == 0) {
            collateralList.push(token);
            collateralIndex[token] = collateralList.length;
        }

        collateralConfigs[token] = CollateralConfig({
            token: collateralToken,
            priceFeed: priceFeed,
            liquidationThreshold: liquidationThreshold,
            minimumCollateral: minimumCollateral,
            priceDecimals: uint8(priceFeed.decimals()),
            tokenDecimals: 18, // Assuming ERC20 standard
            enabled: true,
            lastUpdateBlock: uint48(block.number)
        });

        emit CollateralConfigUpdated(token, liquidationThreshold, minimumCollateral);
    }

    /**
     * @dev Toggle collateral status with gas optimization
     */
    function toggleCollateral(address token, bool enabled) external onlyOwner validCollateral(token) {
        CollateralConfig storage config = collateralConfigs[token];
        if (config.enabled == enabled) return; // Save gas if no change
        
        config.enabled = enabled;
        config.lastUpdateBlock = uint48(block.number);
        
        emit CollateralStatusUpdated(token, enabled);
    }

    /**
     * @dev Gas-optimized price fetching with caching
     */
    function getCollateralPrice(address token) public view validCollateral(token) returns (uint256) {
        CollateralConfig storage config = collateralConfigs[token];
        
        (
            uint80 roundId,
            int256 answer,
            ,
            uint256 updatedAt,
            uint80 answeredInRound
        ) = config.priceFeed.latestRoundData();

        if (answer <= 0) revert InvalidPrice();
        if (answeredInRound < roundId) revert StalePrice();
        if (block.number - uint256(config.lastUpdateBlock) > PRICE_FRESHNESS_BLOCKS) revert StalePrice();

        return uint256(answer);
    }

    /**
     * @dev Optimized collateral value calculation
     */
    function calculateCollateralValue(
        address user,
        address token
    ) public view validCollateral(token) returns (uint256) {
        CollateralPosition storage position = userCollateral[user][token];
        if (position.amount == 0) revert NoCollateralDeposited();

        CollateralConfig storage config = collateralConfigs[token];
        uint256 price = getCollateralPrice(token);

        // Optimized calculation using bitwise operations where possible
        unchecked {
            return (uint256(position.amount) * price) >> config.priceDecimals;
        }
    }

    /**
     * @dev Gas-efficient liquidation check
     */
    function needsLiquidation(
        address user,
        address token,
        uint256 debtAmount
    ) external view validCollateral(token) returns (bool) {
        if (debtAmount == 0) return false;
        
        uint256 collateralValue = calculateCollateralValue(user, token);
        CollateralConfig storage config = collateralConfigs[token];
        
        unchecked {
            uint256 minimumCollateralValue = (debtAmount * BASIS_POINTS) / config.liquidationThreshold;
            return collateralValue < minimumCollateralValue;
        }
    }

    /**
     * @dev Optimized liquidation execution
     */
    function liquidatePosition(
        address user,
        address token,
        uint256 debtAmount
    ) external onlyLendingPool nonReentrant validCollateral(token) returns (uint256) {
        CollateralPosition storage position = userCollateral[user][token];
        if (position.amount == 0) revert NoCollateralDeposited();

        CollateralConfig storage config = collateralConfigs[token];
        uint256 price = getCollateralPrice(token);

        // Calculate liquidation amount with minimal operations
        uint256 liquidationAmount = position.amount;
        position.amount = 0;
        position.lastUpdateTime = uint64(block.timestamp);

        // Transfer collateral using low-level call for gas optimization
        (bool success,) = address(config.token).call(
            abi.encodeWithSelector(
                config.token.transfer.selector,
                lendingPool,
                liquidationAmount
            )
        );
        if (!success) revert TransferFailed();

        emit CollateralLiquidated(user, token, liquidationAmount, price);
        
        return liquidationAmount;
    }

    /**
     * @dev Batch update collateral positions for gas optimization
     */
    function batchUpdatePositions(
        address[] calldata users,
        address[] calldata tokens
    ) external onlyOwner {
        uint256 length = users.length;
        if (length != tokens.length) revert InvalidParameter();
        
        for (uint256 i = 0; i < length;) {
            if (_isValidCollateral(tokens[i])) {
                CollateralPosition storage position = userCollateral[users[i]][tokens[i]];
                if (position.amount > 0) {
                    position.lastUpdateTime = uint64(block.timestamp);
                }
            }
            unchecked { ++i; }
        }
    }

    /**
     * @dev View supported collaterals with pagination
     */
    function getSupportedCollaterals(uint256 offset, uint256 limit) 
        external 
        view 
        returns (address[] memory tokens, bool[] memory enabled) 
    {
        uint256 length = collateralList.length;
        if (offset >= length) return (new address[](0), new bool[](0));
        
        uint256 end = offset + limit > length ? length : offset + limit;
        uint256 resultLength = end - offset;
        
        tokens = new address[](resultLength);
        enabled = new bool[](resultLength);
        
        for (uint256 i = 0; i < resultLength;) {
            address token = collateralList[offset + i];
            tokens[i] = token;
            enabled[i] = collateralConfigs[token].enabled;
            unchecked { ++i; }
        }
    }
}
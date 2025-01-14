// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

error InvalidAddress();
error InvalidAmount();
error InvalidLockTier();
error InsufficientBalance();
error InsufficientPoolLiquidity();
error InsufficientCollateral();
error FundsLocked();
error NoBalance();
error BorrowCapExceeded();
error RepayAmountExceeded();

interface ICollateralManager {
    function calculateCollateralValue(address user, address token) external view returns (uint256);
    function needsLiquidation(address user, address token, uint256 debtAmount) external view returns (bool);
    function liquidatePosition(address user, address token, uint256 debtAmount) external returns (uint256);
    function getCollateralPrice(address token) external view returns (uint256);
}

/**
 * @title EnhancedLendingPool
 * @dev Integrated lending pool with collateral management and liquidations
 */
contract EnhancedLendingPool is ReentrancyGuard, Pausable, Ownable {
    IERC20 public immutable stablecoin;
    
    // Pool state variables - packed for gas optimization
    struct PoolState {
        uint128 totalPoolFunds;
        uint128 availableFunds;
        uint128 totalBorrowed;
        uint128 lastUpdateTimestamp;
    }
    PoolState public poolState;
    
    // Constants
    uint256 private constant BASIS_POINTS = 10000;
    uint256 private constant OPTIMAL_UTILIZATION = 8000;
    uint256 private constant MAX_UTILIZATION = 9500;
    uint256 private constant SECONDS_PER_YEAR = 365 days;
    uint256 private constant LIQUIDATION_BONUS = 1000; // 10% bonus for liquidators
    
    // Interest rate configuration
    struct InterestRates {
        uint64 baseRate;
        uint64 utilizationMultiplier;
        uint64 excessUtilizationMultiplier;
        uint64 emergencyWithdrawalPenalty;
    }
    InterestRates public rates;
    
    // Lock tier structure
    struct LockTier {
        uint32 duration;
        uint32 bonus;
    }
    LockTier[] public lockTiers;
    
    // Lender position tracking
    struct LenderPosition {
        uint128 balance;
        uint64 lockedUntil;
        uint32 lockTier;
        uint128 earnedInterest;
        uint64 lastUpdateTime;
    }
    
    // Borrower position tracking
    struct BorrowerPosition {
        uint128 borrowed;
        uint128 accumulatedInterest;
        uint64 lastUpdateTime;
        address collateralToken;
    }
    
    mapping(address => LenderPosition) public lenderPositions;
    mapping(address => BorrowerPosition) public borrowerPositions;
    
    ICollateralManager public immutable collateralManager;
    
    // Events
    event Deposit(address indexed lender, uint256 amount, uint256 lockPeriod);
    event Withdrawal(address indexed lender, uint256 amount, bool emergency);
    event InterestEarned(address indexed lender, uint256 amount);
    event Borrow(address indexed borrower, uint256 amount, address collateralToken);
    event Repay(address indexed borrower, uint256 amount);
    event Liquidation(address indexed borrower, address indexed liquidator, uint256 amount, address collateralToken);
    
    modifier validAmount(uint256 amount) {
        if (amount == 0) revert InvalidAmount();
        _;
    }

    constructor(address _stablecoin, address _collateralManager) {
        if (_stablecoin == address(0) || _collateralManager == address(0)) revert InvalidAddress();
        
        stablecoin = IERC20(_stablecoin);
        collateralManager = ICollateralManager(_collateralManager);

        // Initialize rates
        rates = InterestRates({
            baseRate: 200,
            utilizationMultiplier: 1000,
            excessUtilizationMultiplier: 2000,
            emergencyWithdrawalPenalty: 1000
        });

        // Initialize lock tiers
        lockTiers.push(LockTier({duration: uint32(30 days), bonus: 100}));
        lockTiers.push(LockTier({duration: uint32(90 days), bonus: 300}));
        lockTiers.push(LockTier({duration: uint32(180 days), bonus: 600}));
    }

    function getUtilizationRate() public view returns (uint256) {
        uint256 totalFunds = poolState.totalPoolFunds;
        if (totalFunds == 0) return 0;
        return (uint256(poolState.totalBorrowed) * BASIS_POINTS) / totalFunds;
    }

    function getCurrentInterestRate() public view returns (uint256) {
        uint256 utilization = getUtilizationRate();
        
        if (utilization <= OPTIMAL_UTILIZATION) {
            return rates.baseRate + (utilization * rates.utilizationMultiplier) / BASIS_POINTS;
        }
        
        uint256 normalRate = rates.baseRate + (OPTIMAL_UTILIZATION * rates.utilizationMultiplier) / BASIS_POINTS;
        uint256 excessUtilization = utilization - OPTIMAL_UTILIZATION;
        return normalRate + (excessUtilization * rates.excessUtilizationMultiplier) / BASIS_POINTS;
    }

    function deposit(uint256 amount, uint256 lockTierId) 
        external 
        nonReentrant 
        whenNotPaused 
        validAmount(amount) 
    {
        if (lockTierId >= lockTiers.length) revert InvalidLockTier();
        
        LenderPosition storage position = lenderPositions[msg.sender];
        
        if (position.balance > 0) {
            _updateEarnedInterest(msg.sender, position);
        }
        
        unchecked {
            position.balance += uint128(amount);
            poolState.totalPoolFunds += uint128(amount);
            poolState.availableFunds += uint128(amount);
        }
        
        if (lockTierId > 0) {
            position.lockedUntil = uint64(block.timestamp + lockTiers[lockTierId].duration);
            position.lockTier = uint32(lockTierId);
        }
        
        position.lastUpdateTime = uint64(block.timestamp);
        
        if (!stablecoin.transferFrom(msg.sender, address(this), amount)) revert();
        
        emit Deposit(msg.sender, amount, lockTierId);
    }

    function borrow(uint256 amount, address collateralToken) 
        external 
        nonReentrant 
        whenNotPaused 
        validAmount(amount) 
    {
        if (poolState.availableFunds < amount) revert InsufficientPoolLiquidity();
        
        BorrowerPosition storage position = borrowerPositions[msg.sender];
        uint256 collateralValue = collateralManager.calculateCollateralValue(msg.sender, collateralToken);
        
        // Update accumulated interest
        _updateBorrowerInterest(msg.sender, position);
        
        uint256 totalBorrowed = uint256(position.borrowed) + amount;
        if (collateralValue < totalBorrowed * 15000 / BASIS_POINTS) revert InsufficientCollateral(); // 150% collateral ratio
        
        unchecked {
            position.borrowed += uint128(amount);
            position.lastUpdateTime = uint64(block.timestamp);
            position.collateralToken = collateralToken;
            
            poolState.availableFunds -= uint128(amount);
            poolState.totalBorrowed += uint128(amount);
        }
        
        if (!stablecoin.transfer(msg.sender, amount)) revert();
        
        emit Borrow(msg.sender, amount, collateralToken);
    }

    function repay(uint256 amount) 
        external 
        nonReentrant 
        whenNotPaused 
        validAmount(amount) 
    {
        BorrowerPosition storage position = borrowerPositions[msg.sender];
        if (position.borrowed == 0) revert NoBalance();
        
        _updateBorrowerInterest(msg.sender, position);
        
        uint256 totalOwed = position.borrowed + position.accumulatedInterest;
        if (amount > totalOwed) revert RepayAmountExceeded();
        
        unchecked {
            if (amount >= totalOwed) {
                poolState.totalBorrowed -= position.borrowed;
                poolState.availableFunds += uint128(totalOwed);
                position.borrowed = 0;
                position.accumulatedInterest = 0;
            } else {
                uint256 interestPortion = (amount * position.accumulatedInterest) / totalOwed;
                uint256 principalPortion = amount - interestPortion;
                
                position.borrowed -= uint128(principalPortion);
                position.accumulatedInterest -= uint128(interestPortion);
                poolState.totalBorrowed -= uint128(principalPortion);
                poolState.availableFunds += uint128(amount);
            }
        }
        
        position.lastUpdateTime = uint64(block.timestamp);
        
        if (!stablecoin.transferFrom(msg.sender, address(this), amount)) revert();
        
        emit Repay(msg.sender, amount);
    }

    function liquidate(address borrower) 
        external 
        nonReentrant 
        whenNotPaused 
    {
        BorrowerPosition storage position = borrowerPositions[borrower];
        if (position.borrowed == 0) revert NoBalance();
        
        _updateBorrowerInterest(borrower, position);
        
        uint256 totalOwed = position.borrowed + position.accumulatedInterest;
        require(
            collateralManager.needsLiquidation(
                borrower, 
                position.collateralToken, 
                totalOwed
            ),
            "Position is healthy"
        );
        
        uint256 liquidatedAmount = collateralManager.liquidatePosition(
            borrower,
            position.collateralToken,
            totalOwed
        );
        
        // Calculate liquidator reward
        uint256 bonus = (liquidatedAmount * LIQUIDATION_BONUS) / BASIS_POINTS;
        uint256 liquidatorReward = liquidatedAmount + bonus;
        
        // Update state
        unchecked {
            poolState.totalBorrowed -= position.borrowed;
            poolState.availableFunds += uint128(totalOwed);
            position.borrowed = 0;
            position.accumulatedInterest = 0;
        }
        
        // Transfer reward to liquidator
        if (!stablecoin.transfer(msg.sender, liquidatorReward)) revert();
        
        emit Liquidation(borrower, msg.sender, liquidatedAmount, position.collateralToken);
    }

    // Internal functions
    function _updateEarnedInterest(address lender, LenderPosition storage position) internal {
        uint256 timeElapsed = block.timestamp - position.lastUpdateTime;
        if (timeElapsed == 0) return;
        
        uint256 rate = getCurrentInterestRate();
        if (position.lockedUntil > block.timestamp) {
            rate += lockTiers[position.lockTier].bonus;
        }
        
        unchecked {
            uint256 interest = (uint256(position.balance) * rate * timeElapsed) / (BASIS_POINTS * SECONDS_PER_YEAR);
            position.earnedInterest += uint128(interest);
            position.lastUpdateTime = uint64(block.timestamp);
        }
        
        emit InterestEarned(lender, interest);
    }

    function _updateBorrowerInterest(address borrower, BorrowerPosition storage position) internal {
        uint256 timeElapsed = block.timestamp - position.lastUpdateTime;
        if (timeElapsed == 0) return;
        
        uint256 rate = getCurrentInterestRate();
        
        unchecked {
            uint256 interest = (uint256(position.borrowed) * rate * timeElapsed) / (BASIS_POINTS * SECONDS_PER_YEAR);
            position.accumulatedInterest += uint128(interest);
            position.lastUpdateTime = uint64(block.timestamp);
        }
    }
}
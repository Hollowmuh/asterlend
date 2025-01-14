// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title ProtocolInterface
 * @notice Enhanced interface aggregating all protocol components
 * @dev Gas-optimized implementation with comprehensive error handling
 */
contract ProtocolInterface is ReentrancyGuard {
    // Custom errors for gas optimization
    error TransferFailed();
    error InvalidAmount();
    error OperationFailed();
    error ComponentNotInitialized();
    
    // Main protocol components
    address public immutable lendingPool;
    address public immutable nftManager;
    address public immutable yieldFarming;
    address public immutable token;
    
    // Struct for aggregated user position (packed for gas efficiency)
    struct UserPosition {
        uint128 depositedAmount;    // 16 bytes
        uint128 borrowedAmount;     // 16 bytes
        uint32 nftCollateralCount;  // 4 bytes
        uint96 yieldEarned;         // 12 bytes
        uint32 healthFactor;        // 4 bytes
        uint32 lastUpdateTime;      // 4 bytes
    }                              // Total: 2 slots (64 bytes)
    
    // Struct for protocol stats (packed for gas efficiency)
    struct ProtocolStats {
        uint128 totalValueLocked;   // 16 bytes
        uint128 totalBorrowed;      // 16 bytes
        uint96 nftCollateralValue;  // 12 bytes
        uint96 flashLoanVolume;     // 12 bytes
        uint32 averageAPY;          // 4 bytes
        uint32 lastUpdateBlock;     // 4 bytes
    }                              // Total: 2 slots (64 bytes)

    // Events
    event DepositWithYield(address indexed user, uint256 amount, uint256 timestamp);
    event NFTLoanCreated(address indexed user, address indexed nftContract, uint256 tokenId, uint256 amount);
    event PositionUpdated(address indexed user, uint256 depositedAmount, uint256 borrowedAmount);

    constructor(
        address _lendingPool,
        address _nftManager,
        address _yieldFarming,
        address _token
    ) {
        if (_lendingPool == address(0) || _nftManager == address(0) || 
            _yieldFarming == address(0) || _token == address(0)) revert ComponentNotInitialized();
            
        lendingPool = _lendingPool;
        nftManager = _nftManager;
        yieldFarming = _yieldFarming;
        token = _token;
    }

    /**
     * @notice One-click deposit with auto-yield farming
     * @dev Optimized for gas efficiency with proper error handling
     * @param amount Amount to deposit and stake
     * @return success Boolean indicating operation success
     */
    function depositWithYield(uint256 amount) external nonReentrant returns (bool) {
        if (amount == 0) revert InvalidAmount();
        
        // Transfer tokens from user
        if (!IERC20(token).transferFrom(msg.sender, address(this), amount)) {
            revert TransferFailed();
        }
        
        // Approve lending pool
        if (!IERC20(token).approve(lendingPool, amount)) {
            revert TransferFailed();
        }
        
        // Deposit to lending pool using low-level call for gas optimization
        (bool success,) = lendingPool.call(
            abi.encodeWithSignature("deposit(uint256)", amount)
        );
        if (!success) revert OperationFailed();
        
        // Approve yield farming
        if (!IERC20(token).approve(yieldFarming, amount)) {
            revert TransferFailed();
        }
        
        // Stake in yield farming
        (success,) = yieldFarming.call(
            abi.encodeWithSignature("stake(uint256)", amount)
        );
        if (!success) revert OperationFailed();
        
        emit DepositWithYield(msg.sender, amount, block.timestamp);
        return true;
    }

    /**
     * @notice One-click NFT-backed loan with optimized execution
     * @param nftAddress NFT contract address
     * @param tokenId NFT token ID
     * @param borrowAmount Amount to borrow
     * @return success Boolean indicating operation success
     */
    function getNFTBackedLoan(
        address nftAddress,
        uint256 tokenId,
        uint256 borrowAmount
    ) external nonReentrant returns (bool) {
        if (borrowAmount == 0) revert InvalidAmount();
        
        // Deposit NFT using low-level call
        (bool success,) = nftManager.call(
            abi.encodeWithSignature(
                "depositNFTCollateral(address,uint256)",
                nftAddress,
                tokenId
            )
        );
        if (!success) revert OperationFailed();
        
        // Borrow against NFT
        (success,) = lendingPool.call(
            abi.encodeWithSignature(
                "borrow(uint256,address)",
                borrowAmount,
                nftAddress
            )
        );
        if (!success) revert OperationFailed();
        
        emit NFTLoanCreated(msg.sender, nftAddress, tokenId, borrowAmount);
        return true;
    }

    /**
     * @notice Aggregate user position across all protocol components
     * @param user Address to query
     * @return position Aggregated user position
     */
    function getUserPosition(
        address user
    ) external view returns (UserPosition memory position) {
        // Get lending pool position
        (bool success, bytes memory data) = lendingPool.staticcall(
            abi.encodeWithSignature("getUserPosition(address)", user)
        );
        if (success) {
            (uint256 deposited, uint256 borrowed) = abi.decode(data, (uint256, uint256));
            position.depositedAmount = uint128(deposited);
            position.borrowedAmount = uint128(borrowed);
        }
        
        // Get NFT collateral count
        (success, data) = nftManager.staticcall(
            abi.encodeWithSignature("getUserCollateralCount(address)", user)
        );
        if (success) {
            position.nftCollateralCount = uint32(abi.decode(data, (uint256)));
        }
        
        // Get yield farming earnings
        (success, data) = yieldFarming.staticcall(
            abi.encodeWithSignature("getEarned(address)", user)
        );
        if (success) {
            position.yieldEarned = uint96(abi.decode(data, (uint256)));
        }
        
        // Calculate health factor
        if (position.borrowedAmount > 0) {
            position.healthFactor = uint32((position.depositedAmount * 100) / position.borrowedAmount);
        }
        
        position.lastUpdateTime = uint32(block.timestamp);
    }

    /**
     * @notice Get protocol-wide statistics
     * @return stats Aggregated protocol statistics
     */
    function getProtocolStats() external view returns (ProtocolStats memory stats) {
        // Get lending pool stats
        (bool success, bytes memory data) = lendingPool.staticcall(
            abi.encodeWithSignature("getPoolStats()")
        );
        if (success) {
            (uint256 tvl, uint256 borrowed) = abi.decode(data, (uint256, uint256));
            stats.totalValueLocked = uint128(tvl);
            stats.totalBorrowed = uint128(borrowed);
        }
        
        // Get NFT collateral value
        (success, data) = nftManager.staticcall(
            abi.encodeWithSignature("getTotalCollateralValue()")
        );
        if (success) {
            stats.nftCollateralValue = uint96(abi.decode(data, (uint256)));
        }
        
        // Get flash loan volume
        (success, data) = lendingPool.staticcall(
            abi.encodeWithSignature("getFlashLoanVolume()")
        );
        if (success) {
            stats.flashLoanVolume = uint96(abi.decode(data, (uint256)));
        }
        
        // Calculate average APY
        if (stats.totalValueLocked > 0) {
            stats.averageAPY = uint32((stats.totalBorrowed * 100) / stats.totalValueLocked);
        }
        
        stats.lastUpdateBlock = uint32(block.number);
    }
}
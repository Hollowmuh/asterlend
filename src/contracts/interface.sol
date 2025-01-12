// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

/**
 * @title ProtocolInterface
 * @notice Simplified interface for front-end interactions
 * @dev Aggregates key functions from all protocol components
 */
contract ProtocolInterface is ReentrancyGuard {
    // Main protocol components
    address public immutable lendingPool;
    address public immutable nftManager;
    address public immutable yieldFarming;
    address public immutable token;
    
    // Struct for aggregated user position
    struct UserPosition {
        uint256 depositedAmount;
        uint256 borrowedAmount;
        uint256 nftCollateralCount;
        uint256 yieldEarned;
        uint256 healthFactor;
    }
    
    // Struct for quick protocol stats
    struct ProtocolStats {
        uint256 totalValueLocked;
        uint256 totalBorrowed;
        uint256 nftCollateralValue;
        uint256 flashLoanVolume;
        uint256 averageAPY;
    }

    constructor(
        address _lendingPool,
        address _nftManager,
        address _yieldFarming,
        address _token
    ) {
        lendingPool = _lendingPool;
        nftManager = _nftManager;
        yieldFarming = _yieldFarming;
        token = _token;
    }

    /**
     * @notice One-click deposit with auto-yield farming
     * @dev Deposits tokens and enters yield farming in one transaction
     */
    function depositWithYield(
        uint256 amount
    ) external nonReentrant returns (bool) {
        // Deposit to lending pool
        (bool success, ) = lendingPool.call(
            abi.encodeWithSignature("deposit(uint256)", amount)
        );
        require(success, "Deposit failed");
        
        // Auto-stake in yield farming
        (success, ) = yieldFarming.call(
            abi.encodeWithSignature("stake(uint256)", amount)
        );
        require(success, "Stake failed");
        
        return true;
    }

    /**
     * @notice One-click NFT-backed loan
     * @dev Deposits NFT and borrows in one transaction
     */
    function getNFTBackedLoan(
        address nftAddress,
        uint256 tokenId,
        uint256 borrowAmount
    ) external nonReentrant returns (bool) {
        // Deposit NFT
        (bool success, ) = nftManager.call(
            abi.encodeWithSignature(
                "depositNFTCollateral(address,uint256)",
                nftAddress,
                tokenId
            )
        );
        require(success, "NFT deposit failed");
        
        // Borrow against NFT
        (success, ) = lendingPool.call(
            abi.encodeWithSignature(
                "borrow(uint256,address)",
                borrowAmount,
                nftAddress
            )
        );
        require(success, "Borrow failed");
        
        return true;
    }

    /**
     * @notice Get user's aggregated position
     * @dev Combines data from all protocol components
     */
    function getUserPosition(
        address user
    ) external view returns (UserPosition memory) {
        // Implementation would aggregate user data from all components
        // This is a simplified version for the example
        return UserPosition(0, 0, 0, 0, 0);
    }

    /**
     * @notice Get quick protocol statistics
     * @dev Aggregates key metrics for front-end display
     */
    function getProtocolStats(
    ) external view returns (ProtocolStats memory) {
        // Implementation would aggregate protocol stats
        // This is a simplified version for the example
        return ProtocolStats(0, 0, 0, 0, 0);
    }
}
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

/**
 * @title NFTCollateralManager
 * @notice Manages NFT collateral with floor price feeds and liquidity scoring
 * @dev Supports multiple NFT collections with different risk parameters
 */
contract NFTCollateralManager is ReentrancyGuard, Ownable {
    struct NFTCollection {
        address collection;           // NFT contract address
        address floorPriceOracle;    // Chainlink oracle for floor price
        uint256 liquidityScore;      // 0-100, indicating how liquid the collection is
        uint256 maxLTV;             // Maximum loan-to-value ratio in basis points
        bool enabled;                // Whether the collection is accepted
        uint256[] recentSales;       // Circular buffer of recent sale prices
        uint256 lastUpdateIndex;     // Index for circular buffer
    }

    // Storage
    mapping(address => NFTCollection) public nftCollections;
    mapping(address => mapping(uint256 => address)) public tokenOwners;
    mapping(address => uint256[]) public userCollateral;
    
    uint256 private constant MAX_RECENT_SALES = 10;
    uint256 private constant BASIS_POINTS = 10000;
    
    // Events
    event NFTCollateralDeposited(
        address indexed user,
        address indexed collection,
        uint256 tokenId
    );
    event NFTCollateralWithdrawn(
        address indexed user,
        address indexed collection,
        uint256 tokenId
    );
    event NFTCollectionAdded(
        address indexed collection,
        address indexed oracle,
        uint256 maxLTV
    );
    event NFTValueUpdated(
        address indexed collection,
        uint256 floorPrice,
        uint256 averagePrice
    );

    /**
     * @notice Add a new NFT collection as valid collateral
     * @param collection NFT contract address
     * @param oracle Floor price oracle address
     * @param maxLTV Maximum loan-to-value ratio
     * @param liquidityScore Initial liquidity score
     */
    function addNFTCollection(
        address collection,
        address oracle,
        uint256 maxLTV,
        uint256 liquidityScore
    ) external onlyOwner {
        require(collection != address(0), "Invalid collection");
        require(oracle != address(0), "Invalid oracle");
        require(maxLTV <= 5000, "LTV too high"); // Max 50%
        require(liquidityScore <= 100, "Invalid liquidity score");
        
        nftCollections[collection] = NFTCollection({
            collection: collection,
            floorPriceOracle: oracle,
            liquidityScore: liquidityScore,
            maxLTV: maxLTV,
            enabled: true,
            recentSales: new uint256[](MAX_RECENT_SALES),
            lastUpdateIndex: 0
        });
        
        emit NFTCollectionAdded(collection, oracle, maxLTV);
    }

    /**
     * @notice Calculate the collateral value of an NFT
     * @dev Uses a combination of floor price and recent sales data
     */
    function calculateNFTValue(
        address collection,
        uint256 tokenId
    ) public view returns (uint256) {
        NFTCollection storage nftCollection = nftCollections[collection];
        require(nftCollection.enabled, "Collection not enabled");
        
        // Get floor price from oracle
        (
            ,
            int256 floorPrice,
            ,
            ,
        ) = AggregatorV3Interface(nftCollection.floorPriceOracle)
            .latestRoundData();
        
        // Calculate average of recent sales
        uint256 totalSales = 0;
        uint256 salesCount = 0;
        
        for (uint256 i = 0; i < MAX_RECENT_SALES; i++) {
            uint256 salePrice = nftCollection.recentSales[i];
            if (salePrice > 0) {
                totalSales += salePrice;
                salesCount++;
            }
        }
        
        uint256 averagePrice = salesCount > 0 
            ? totalSales / salesCount 
            : uint256(floorPrice);
        
        // Weighted average of floor price and recent sales
        uint256 weightedValue = (
            (uint256(floorPrice) * 60) + (averagePrice * 40)
        ) / 100;
        
        // Apply liquidity discount
        uint256 liquidityDiscount = (
            (100 - nftCollection.liquidityScore) * weightedValue
        ) / 100;
        
        return weightedValue - liquidityDiscount;
    }

    /**
     * @notice Deposit an NFT as collateral
     * @param collection NFT collection address
     * @param tokenId Token ID to deposit
     */
    function depositNFTCollateral(
        address collection,
        uint256 tokenId
    ) external nonReentrant {
        NFTCollection storage nftCollection = nftCollections[collection];
        require(nftCollection.enabled, "Collection not enabled");
        
        IERC721 nft = IERC721(collection);
        require(
            nft.ownerOf(tokenId) == msg.sender,
            "Not token owner"
        );
        
        nft.transferFrom(msg.sender, address(this), tokenId);
        tokenOwners[collection][tokenId] = msg.sender;
        userCollateral[msg.sender].push(tokenId);
        
        emit NFTCollateralDeposited(msg.sender, collection, tokenId);
    }

    /**
     * @notice Update recent sale price for an NFT collection
     * @dev Called when a sale occurs to maintain price history
     */
    function updateRecentSale(
        address collection,
        uint256 salePrice
    ) external onlyOwner {
        NFTCollection storage nftCollection = nftCollections[collection];
        require(nftCollection.enabled, "Collection not enabled");
        
        uint256 index = nftCollection.lastUpdateIndex;
        nftCollection.recentSales[index] = salePrice;
        nftCollection.lastUpdateIndex = (index + 1) % MAX_RECENT_SALES;
        
        // Get floor price for event emission
        (
            ,
            int256 floorPrice,
            ,
            ,
        ) = AggregatorV3Interface(nftCollection.floorPriceOracle)
            .latestRoundData();
        
        emit NFTValueUpdated(
            collection,
            uint256(floorPrice),
            salePrice
        );
    }
}
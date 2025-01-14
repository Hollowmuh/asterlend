// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "./NGNIToken.sol";
import "./EnhancedLendingPoolV2.sol";
import "./NFTCollateralManager.sol";
import "./GasOptimizedAnalytics.sol";
import "./YieldFarmingIntegration.sol";
import "./ProtocolGovernance.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/proxy/Clones.sol";

/**
 * @title ProtocolFactory
 * @notice Factory for deploying and managing protocol components
 * @dev Uses minimal proxy pattern for gas-efficient deployment
 */
contract ProtocolFactory is Ownable {
    using Clones for address;

    // Protocol component templates
    address public immutable lendingPoolTemplate;
    address public immutable nftManagerTemplate;
    address public immutable analyticsTemplate;
    address public immutable yieldFarmingTemplate;
    
    // Deployed instances
    struct DeployedProtocol {
        address lendingPool;
        address nftManager;
        address analytics;
        address yieldFarming;
        address governance;
        address token;
        bool active;
    }
    
    // Storage
    mapping(bytes32 => DeployedProtocol) public deployedProtocols;
    mapping(address => bool) public authorizedDeployers;
    
    // Events
    event ProtocolDeployed(
        bytes32 indexed protocolId,
        address lendingPool,
        address token
    );
    event DeployerAuthorized(address indexed deployer, bool authorized);

    constructor(
        address _lendingPoolTemplate,
        address _nftManagerTemplate,
        address _analyticsTemplate,
        address _yieldFarmingTemplate
    ) {
        lendingPoolTemplate = _lendingPoolTemplate;
        nftManagerTemplate = _nftManagerTemplate;
        analyticsTemplate = _analyticsTemplate;
        yieldFarmingTemplate = _yieldFarmingTemplate;
        authorizedDeployers[msg.sender] = true;
    }

    /**
     * @notice Deploy a complete protocol instance
     * @dev Creates all components and sets up governance
     */
    function deployProtocol(
        string memory name,
        string memory symbol,
        uint256 initialSupply,
        uint256 maxSupply,
        uint256 votingDelay,
        uint256 votingPeriod,
        uint256 quorumPercentage
    ) external returns (bytes32 protocolId) {
        require(authorizedDeployers[msg.sender], "Not authorized");
        
        // Generate unique protocol ID
        protocolId = keccak256(
            abi.encodePacked(
                name,
                symbol,
                block.timestamp,
                msg.sender
            )
        );
        require(!deployedProtocols[protocolId].active, "Already exists");

        // Deploy NGNI token
        NGNIToken token = new NGNIToken(
            name,
            symbol,
            initialSupply,
            maxSupply
        );

        // Deploy timelock
        TimelockController timelock = new TimelockController(
            1 days, // Minimum delay
            new address[](0), // Proposers
            new address[](0), // Executors
            address(this) // Admin
        );

        // Deploy governance
        ProtocolGovernance governance = new ProtocolGovernance(
            IVotes(address(token)),
            timelock,
            votingDelay,
            votingPeriod,
            quorumPercentage
        );

        // Deploy protocol components using minimal proxies
        address lendingPool = lendingPoolTemplate.clone();
        address nftManager = nftManagerTemplate.clone();
        address analytics = analyticsTemplate.clone();
        address yieldFarming = yieldFarmingTemplate.clone();

        // Initialize components
        EnhancedLendingPoolV2(lendingPool).initialize(
            address(token),
            nftManager
        );
        
        NFTCollateralManager(nftManager).initialize(
            lendingPool,
            address(governance)
        );
        
        GasOptimizedAnalytics(analytics).initialize(
            lendingPool,
            address(token)
        );
        
        YieldFarmingIntegration(yieldFarming).initialize(
            address(token),
            lendingPool
        );

        // Store deployment
        deployedProtocols[protocolId] = DeployedProtocol({
            lendingPool: lendingPool,
            nftManager: nftManager,
            analytics: analytics,
            yieldFarming: yieldFarming,
            governance: address(governance),
            token: address(token),
            active: true
        });

        emit ProtocolDeployed(protocolId, lendingPool, address(token));
    }

    /**
     * @notice Authorize or revoke a deployer
     * @dev Only owner can manage deployers
     */
    function setDeployerAuthorization(
        address deployer,
        bool authorized
    ) external onlyOwner {
        authorizedDeployers[deployer] = authorized;
        emit DeployerAuthorized(deployer, authorized);
    }

    /**
     * @notice Get deployed protocol details
     * @dev Returns all component addresses for a protocol
     */
    function getProtocolDetails(
        bytes32 protocolId
    ) external view returns (DeployedProtocol memory) {
        return deployedProtocols[protocolId];
    }
}
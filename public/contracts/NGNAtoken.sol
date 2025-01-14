// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/math/SafeCast.sol";

/**
 * @title NGNIToken
 * @notice Governance token for the lending protocol with delegation and voting capabilities
 * @dev Implements ERC20 with permit, voting, and inflation mechanisms
 */
contract NGNIToken is ERC20, ERC20Permit, ERC20Votes, Ownable, Pausable {
    using SafeCast for uint256;

    // Packed inflation config struct (1 slot)
    struct InflationConfig {
        uint128 maxSupply;          // Maximum token supply
        uint64 inflationRate;       // Annual inflation rate in basis points
        uint32 lastInflationTime;   // Last inflation update timestamp
        uint32 inflationInterval;   // Time between inflation updates
    }

    // Packed reward config struct (1 slot)
    struct RewardConfig {
        uint128 rewardPool;         // Available rewards
        uint64 rewardRate;          // Reward rate in tokens per second
        uint32 lastUpdateTime;      // Last reward update timestamp
        uint32 lockupPeriod;        // Required lockup for rewards
    }

    // Storage
    InflationConfig public inflationConfig;
    RewardConfig public rewardConfig;
    
    mapping(address => uint256) public lastClaimTime;
    mapping(address => uint256) public lockedRewards;
    mapping(address => uint256) public unlockTime;

    // Constants
    uint256 private constant BASIS_POINTS = 10000;
    uint256 private constant SECONDS_PER_YEAR = 31536000;
    
    // Events
    event InflationUpdated(uint256 amount, uint256 newSupply);
    event RewardsClaimed(address indexed user, uint256 amount);
    event RewardsLocked(address indexed user, uint256 amount, uint256 unlockTime);

    constructor(
        string memory name,
        string memory symbol,
        uint256 initialSupply,
        uint256 _maxSupply
    ) ERC20(name, symbol) ERC20Permit(name) {
        require(_maxSupply >= initialSupply, "Max supply too low");
        
        inflationConfig = InflationConfig({
            maxSupply: uint128(_maxSupply),
            inflationRate: 500, // 5% annual inflation
            lastInflationTime: uint32(block.timestamp),
            inflationInterval: 90 days //every three months
        });

        rewardConfig = RewardConfig({
            rewardPool: 0,
            rewardRate: 1e20, // 0.01 token per second
            lastUpdateTime: uint32(block.timestamp),
            lockupPeriod: 30 days //minimum 1 month
        });

        _mint(msg.sender, initialSupply);
    }

    /**
     * @notice Update inflation based on configuration
     * @dev Called periodically to mint new tokens according to inflation schedule
     */
    function updateInflation() external {
        InflationConfig storage config = inflationConfig;
        require(
            block.timestamp >= config.lastInflationTime + config.inflationInterval,
            "Too soon"
        );

        uint256 timePassed = block.timestamp - config.lastInflationTime;
        uint256 currentSupply = totalSupply();
        
        // Calculate inflation amount
        uint256 inflationAmount = (currentSupply * config.inflationRate * timePassed)
            / (BASIS_POINTS * SECONDS_PER_YEAR);
            
        // Check max supply
        require(
            currentSupply + inflationAmount <= config.maxSupply,
            "Max supply exceeded"
        );

        // Update state
        config.lastInflationTime = uint32(block.timestamp);
        
        // Mint new tokens to reward pool
        _mint(address(this), inflationAmount);
        rewardConfig.rewardPool += uint128(inflationAmount);

        emit InflationUpdated(inflationAmount, currentSupply + inflationAmount);
    }

    /**
     * @notice Claim available rewards
     * @dev Rewards are locked for a period before being available
     */
    function claimRewards() external whenNotPaused {
        RewardConfig storage config = rewardConfig;
        uint256 lastClaim = lastClaimTime[msg.sender];
        
        // Calculate rewards
        uint256 timePassed = block.timestamp - lastClaim;
        uint256 reward = (timePassed * config.rewardRate).toUint128();
        
        require(reward <= config.rewardPool, "Insufficient reward pool");
        
        // Update state
        config.rewardPool -= uint128(reward);
        lastClaimTime[msg.sender] = block.timestamp;
        lockedRewards[msg.sender] += reward;
        unlockTime[msg.sender] = block.timestamp + config.lockupPeriod;

        emit RewardsLocked(msg.sender, reward, unlockTime[msg.sender]);
    }

    /**
     * @notice Withdraw unlocked rewards
     * @dev Only unlocked rewards can be withdrawn
     */
    function withdrawUnlockedRewards() external whenNotPaused {
        require(block.timestamp >= unlockTime[msg.sender], "Still locked");
        
        uint256 amount = lockedRewards[msg.sender];
        require(amount > 0, "No rewards");
        
        // Clear state before transfer
        lockedRewards[msg.sender] = 0;
        
        // Transfer rewards
        _transfer(address(this), msg.sender, amount);
        
        emit RewardsClaimed(msg.sender, amount);
    }

    /**
     * @notice Update reward configuration
     * @dev Only owner can update rewards
     */
    function updateRewardConfig(
        uint64 newRate,
        uint32 newLockup
    ) external onlyOwner {
        require(newLockup >= 1 days, "Lockup too short");
        
        rewardConfig.rewardRate = newRate;
        rewardConfig.lockupPeriod = newLockup;
    }

    // Required overrides for ERC20Votes
    function _afterTokenTransfer(
        address from,
        address to,
        uint256 amount
    ) internal override(ERC20, ERC20Votes) {
        super._afterTokenTransfer(from, to, amount);
    }

    function _mint(
        address to,
        uint256 amount
    ) internal override(ERC20, ERC20Votes) {
        super._mint(to, amount);
    }

    function _burn(
        address account,
        uint256 amount
    ) internal override(ERC20, ERC20Votes) {
        super._burn(account, amount);
    }

    /**
     * @notice Pause token transfers and operations
     * @dev Only owner can pause
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Unpause token transfers and operations
     * @dev Only owner can unpause
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @notice Override transfer to check pause status
     */
    function transfer(
        address to,
        uint256 amount
    ) public override whenNotPaused returns (bool) {
        return super.transfer(to, amount);
    }

    /**
     * @notice Override transferFrom to check pause status
     */
    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) public override whenNotPaused returns (bool) {
        return super.transferFrom(from, to, amount);
    }
}
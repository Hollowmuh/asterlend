// Import required libraries
const ethers = require('ethers');
const axios = require('axios');
require('dotenv').config();

// Contract ABIs - Import your compiled contract ABIs
const NGNIToken = require('./artifacts/contracts/NGNIToken.sol/NGNIToken.json');
const ProtocolFactory = require('./artifacts/contracts/ProtocolFactory.sol/ProtocolFactory.json');
const ProtocolInterface = require('./artifacts/contracts/ProtocolInterface.sol/ProtocolInterface.json');

// Configuration
const config = {
    INFURA_URL: process.env.INFURA_URL,
    PRIVATE_KEY: process.env.PRIVATE_KEY,
    COINGECKO_API: 'https://api.coingecko.com/api/v3',
    FACTORY_ADDRESS: process.env.FACTORY_ADDRESS,
    INTERFACE_ADDRESS: process.env.INTERFACE_ADDRESS
};

// Initialize provider and signer
const provider = new ethers.providers.JsonRpcProvider(config.INFURA_URL);
const signer = new ethers.Wallet(config.PRIVATE_KEY, provider);

/**
 * Deploy complete protocol instance
 * @param {string} name Token name
 * @param {string} symbol Token symbol
 * @param {ethers.BigNumber} initialSupply Initial token supply
 * @returns {Promise<Object>} Deployed contract addresses
 */
async function deployProtocol(name, symbol, initialSupply) {
    try {
        console.log('Deploying protocol...');
        
        // Connect to factory
        const factory = new ethers.Contract(
            config.FACTORY_ADDRESS,
            ProtocolFactory.abi,
            signer
        );

        // Deploy protocol instance
        const tx = await factory.deployProtocol(
            name,
            symbol,
            initialSupply,
            initialSupply.mul(2), // maxSupply = 2x initial
            5760, // 1 day voting delay (blocks)
            40320, // 1 week voting period (blocks)
            1000 // 10% quorum
        );

        const receipt = await tx.wait();
        
        // Get deployment event
        const event = receipt.events.find(e => e.event === 'ProtocolDeployed');
        const { protocolId, lendingPool, token } = event.args;

        console.log('Protocol deployed:', {
            protocolId,
            lendingPool,
            token
        });

        return { protocolId, lendingPool, token };
    } catch (error) {
        console.error('Deployment failed:', error);
        throw error;
    }
}

/**
 * Get current asset prices from CoinGecko
 * @param {string[]} tokens Token IDs to fetch
 * @returns {Promise<Object>} Price data
 */
async function getPriceFeeds(tokens) {
    try {
        const response = await axios.get(
            `${config.COINGECKO_API}/simple/price`,
            {
                params: {
                    ids: tokens.join(','),
                    vs_currencies: 'usd'
                }
            }
        );
        return response.data;
    } catch (error) {
        console.error('Price fetch failed:', error);
        throw error;
    }
}

/**
 * Deposit assets with auto-yield farming
 * @param {string} amount Amount to deposit
 * @returns {Promise<ethers.ContractTransaction>}
 */
async function depositWithYield(amount) {
    try {
        // Get interface contract
        const interface = new ethers.Contract(
            config.INTERFACE_ADDRESS,
            ProtocolInterface.abi,
            signer
        );

        // Get token price for amount calculation
        const prices = await getPriceFeeds(['ethereum']);
        const ethPrice = prices.ethereum.usd;
        
        // Calculate optimal amount based on current prices
        const optimizedAmount = calculateOptimalDeposit(amount, ethPrice);

        // Execute deposit
        const tx = await interface.depositWithYield(
            ethers.utils.parseEther(optimizedAmount.toString())
        );
        
        console.log('Deposit transaction:', tx.hash);
        return tx;
    } catch (error) {
        console.error('Deposit failed:', error);
        throw error;
    }
}

/**
 * Execute a flash loan arbitrage
 * @param {string} token Token to arbitrage
 * @param {string} amount Loan amount
 * @returns {Promise<ethers.ContractTransaction>}
 */
async function executeFlashLoanArbitrage(token, amount) {
    try {
        // Get price data
        const prices = await getPriceFeeds([token]);
        const tokenPrice = prices[token].usd;

        // Get lending pool contract
        const lendingPool = new ethers.Contract(
            config.LENDING_POOL_ADDRESS,
            LendingPool.abi,
            signer
        );

        // Calculate profitable arbitrage parameters
        const { targetAmount, expectedProfit } = calculateArbitrageParams(
            amount,
            tokenPrice
        );

        // Execute flash loan if profitable
        if (expectedProfit > 0) {
            const tx = await lendingPool.executeFlashLoan(
                signer.address,
                ethers.utils.parseEther(targetAmount.toString()),
                ethers.utils.defaultAbiCoder.encode(
                    ['string', 'uint256'],
                    ['arbitrage', expectedProfit]
                )
            );
            
            console.log('Flash loan transaction:', tx.hash);
            return tx;
        }

        console.log('No profitable arbitrage opportunity found');
        return null;
    } catch (error) {
        console.error('Flash loan failed:', error);
        throw error;
    }
}

/**
 * Get user's protocol position
 * @param {string} address User address
 * @returns {Promise<Object>} Position details
 */
async function getUserPosition(address) {
    try {
        const interface = new ethers.Contract(
            config.INTERFACE_ADDRESS,
            ProtocolInterface.abi,
            provider
        );

        const position = await interface.getUserPosition(address);
        
        // Format position data
        return {
            depositedAmount: ethers.utils.formatEther(position.depositedAmount),
            borrowedAmount: ethers.utils.formatEther(position.borrowedAmount),
            nftCollateralCount: position.nftCollateralCount.toString(),
            yieldEarned: ethers.utils.formatEther(position.yieldEarned),
            healthFactor: position.healthFactor.toString()
        };
    } catch (error) {
        console.error('Position fetch failed:', error);
        throw error;
    }
}

/**
 * Calculate optimal deposit amount
 * @param {number} amount Base amount
 * @param {number} price Current price
 * @returns {number} Optimized amount
 */
function calculateOptimalDeposit(amount, price) {
    // Add gas cost consideration
    const estimatedGasCost = 0.005; // ETH
    const targetValue = amount * price;
    
    // Adjust for gas costs
    return (targetValue - (estimatedGasCost * price)) / price;
}

/**
 * Calculate arbitrage parameters
 * @param {number} amount Loan amount
 * @param {number} price Current price
 * @returns {Object} Arbitrage parameters
 */
function calculateArbitrageParams(amount, price) {
    // Minimum profit threshold (0.5%)
    const minProfitThreshold = 0.005;
    
    // Calculate fees and potential profit
    const flashLoanFee = amount * 0.0009; // 0.09% fee
    const expectedSlippage = amount * 0.001; // 0.1% estimated slippage
    
    const potentialProfit = (amount * price * 0.02) - flashLoanFee - expectedSlippage;
    
    if (potentialProfit / amount > minProfitThreshold) {
        return {
            targetAmount: amount,
            expectedProfit: potentialProfit
        };
    }
    
    return {
        targetAmount: 0,
        expectedProfit: 0
    };
}

module.exports = {
    deployProtocol,
    depositWithYield,
    executeFlashLoanArbitrage,
    getUserPosition,
    getPriceFeeds
};
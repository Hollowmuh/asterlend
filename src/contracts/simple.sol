// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

// Custom errors for gas optimization
error InvalidParameters();
error UnauthorizedAccess();
error InsufficientAmount();
error ListingNotFound();
error InvalidCollateral();
error LoanNotActive();
error RepaymentFailed();

/**
 * @title LendingMarketplace
 * @notice Main contract for P2P lending marketplace functionality
 */
contract LendingMarketplace is ReentrancyGuard, Ownable {
    using SafeMath for uint256;

    // Constants
    uint256 private constant BASIS_POINTS = 10000;
    uint256 private constant MIN_LOAN_DURATION = 1 days;
    uint256 private constant MAX_LOAN_DURATION = 365 days;

    struct Listing {
        address lender;
        uint256 amount;
        uint256 interestRate;
        uint256 duration;
        bool isActive;
    }

    struct Loan {
        address lender;
        address borrower;
        uint256 amount;
        uint256 interestRate;
        uint256 duration;
        uint256 startTime;
        uint256 collateralAmount;
        address collateralToken;
        bool isActive;
    }

    // State variables
    CollateralManager public collateralManager;
    IERC20 public lendingToken;
    
    mapping(uint256 => Listing) public listings;
    mapping(uint256 => Loan) public loans;
    uint256 public nextListingId;
    uint256 public nextLoanId;

    // Events
    event ListingCreated(uint256 indexed listingId, address indexed lender, uint256 amount, uint256 interestRate);
    event LoanCreated(uint256 indexed loanId, address indexed lender, address indexed borrower, uint256 amount);
    event LoanRepaid(uint256 indexed loanId, uint256 amount);
    event ListingCancelled(uint256 indexed listingId);

    constructor(address _lendingToken) Ownable(msg.sender) {
        if (_lendingToken == address(0)) revert InvalidParameters();
        lendingToken = IERC20(_lendingToken);
    }

    function setCollateralManager(address _collateralManager) external onlyOwner {
        if (_collateralManager == address(0)) revert InvalidParameters();
        collateralManager = CollateralManager(_collateralManager);
    }

    function createListing(
        uint256 amount,
        uint256 interestRate,
        uint256 duration
    ) external nonReentrant returns (uint256) {
        if (amount == 0) revert InsufficientAmount();
        if (duration < MIN_LOAN_DURATION || duration > MAX_LOAN_DURATION) revert InvalidParameters();
        
        uint256 listingId = nextListingId++;
        
        listings[listingId] = Listing({
            lender: msg.sender,
            amount: amount,
            interestRate: interestRate,
            duration: duration,
            isActive: true
        });

        if (!lendingToken.transferFrom(msg.sender, address(this), amount)) revert();

        emit ListingCreated(listingId, msg.sender, amount, interestRate);
        return listingId;
    }

    function acceptLoan(
        uint256 listingId,
        address collateralToken,
        uint256 collateralAmount
    ) external nonReentrant returns (uint256) {
        Listing storage listing = listings[listingId];
        if (!listing.isActive) revert ListingNotFound();
        
        if (!collateralManager.validateCollateral(collateralToken, collateralAmount, listing.amount)) {
            revert InvalidCollateral();
        }

        uint256 loanId = nextLoanId++;
        loans[loanId] = Loan({
            lender: listing.lender,
            borrower: msg.sender,
            amount: listing.amount,
            interestRate: listing.interestRate,
            duration: listing.duration,
            startTime: block.timestamp,
            collateralAmount: collateralAmount,
            collateralToken: collateralToken,
            isActive: true
        });

        listing.isActive = false;

        // Transfer collateral to manager
        if (!IERC20(collateralToken).transferFrom(msg.sender, address(collateralManager), collateralAmount)) revert();
        
        // Transfer loan amount to borrower
        if (!lendingToken.transfer(msg.sender, listing.amount)) revert();

        collateralManager.initializeLoan(loanId, msg.sender, collateralToken, collateralAmount);

        emit LoanCreated(loanId, listing.lender, msg.sender, listing.amount);
        return loanId;
    }

    function repayLoan(uint256 loanId) external nonReentrant {
        Loan storage loan = loans[loanId];
        if (!loan.isActive) revert LoanNotActive();
        if (msg.sender != loan.borrower) revert UnauthorizedAccess();

        uint256 interest = calculateInterest(loan);
        uint256 totalRepayment = loan.amount.add(interest);

        if (!lendingToken.transferFrom(msg.sender, loan.lender, totalRepayment)) revert RepaymentFailed();
        
        loan.isActive = false;
        collateralManager.releaseLoanCollateral(loanId, msg.sender);

        emit LoanRepaid(loanId, totalRepayment);
    }

    function cancelListing(uint256 listingId) external nonReentrant {
        Listing storage listing = listings[listingId];
        if (msg.sender != listing.lender) revert UnauthorizedAccess();
        if (!listing.isActive) revert ListingNotFound();

        listing.isActive = false;
        if (!lendingToken.transfer(listing.lender, listing.amount)) revert();

        emit ListingCancelled(listingId);
    }

    function calculateInterest(Loan memory loan) public view returns (uint256) {
        uint256 timeElapsed = block.timestamp.sub(loan.startTime);
        return loan.amount
            .mul(loan.interestRate)
            .mul(timeElapsed)
            .div(365 days)
            .div(BASIS_POINTS);
    }
}

/**
 * @title CollateralManager
 * @notice Manages collateral for the lending marketplace
 */
contract CollateralManager is ReentrancyGuard, Ownable {
    using SafeMath for uint256;

    // Constants
    uint256 private constant MIN_COLLATERAL_RATIO = 150; // 150%
    uint256 private constant LIQUIDATION_THRESHOLD = 125; // 125%
    uint256 private constant PRICE_PRECISION = 8;

    struct CollateralInfo {
        address token;
        uint256 amount;
        address borrower;
        bool isActive;
    }

    // State variables
    LendingMarketplace public marketplace;
    mapping(address => AggregatorV3Interface) public priceFeeds;
    mapping(uint256 => CollateralInfo) public collaterals;

    // Events
    event CollateralDeposited(uint256 indexed loanId, address token, uint256 amount);
    event CollateralReleased(uint256 indexed loanId, address borrower, uint256 amount);
    event PriceFeedUpdated(address token, address feed);

    constructor() Ownable(msg.sender) {}

    function setMarketplace(address _marketplace) external onlyOwner {
        if (_marketplace == address(0)) revert InvalidParameters();
        marketplace = LendingMarketplace(_marketplace);
    }

    function setPriceFeed(address token, address feed) external onlyOwner {
        if (token == address(0) || feed == address(0)) revert InvalidParameters();
        priceFeeds[token] = AggregatorV3Interface(feed);
        emit PriceFeedUpdated(token, feed);
    }

    function validateCollateral(
        address token,
        uint256 collateralAmount,
        uint256 loanAmount
    ) external view returns (bool) {
        if (priceFeeds[token] == AggregatorV3Interface(address(0))) return false;
        
        uint256 collateralValue = getCollateralValue(token, collateralAmount);
        uint256 minCollateral = loanAmount.mul(MIN_COLLATERAL_RATIO).div(100);
        
        return collateralValue >= minCollateral;
    }

    function initializeLoan(
        uint256 loanId,
        address borrower,
        address token,
        uint256 amount
    ) external {
        if (msg.sender != address(marketplace)) revert UnauthorizedAccess();
        
        collaterals[loanId] = CollateralInfo({
            token: token,
            amount: amount,
            borrower: borrower,
            isActive: true
        });

        emit CollateralDeposited(loanId, token, amount);
    }

    function releaseLoanCollateral(uint256 loanId, address borrower) external {
        if (msg.sender != address(marketplace)) revert UnauthorizedAccess();
        
        CollateralInfo storage collateral = collaterals[loanId];
        if (!collateral.isActive || collateral.borrower != borrower) revert InvalidParameters();

        collateral.isActive = false;
        if (!IERC20(collateral.token).transfer(borrower, collateral.amount)) revert();

        emit CollateralReleased(loanId, borrower, collateral.amount);
    }

    function getCollateralValue(address token, uint256 amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = priceFeeds[token];
        (, int256 price,,,) = priceFeed.latestRoundData();
        
        return uint256(price)
            .mul(amount)
            .div(10 ** uint256(PRICE_PRECISION));
    }
}
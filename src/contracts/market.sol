// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "@chainlink/contracts/src/v0.8/automation/AutomationCompatible.sol";

// Custom errors
error InvalidParameters();
error UnauthorizedAccess();
error InvalidAmount();
error ListingNotFound();
error InvalidCollateral();
error LoanNotActive();
error InsufficientCollateral();
error InvalidDuration();
error InvalidInterestRate();
error GracePeriodNotExpired();
error LoanNotDefaulted();
interface ICollateralManager {
    function calculateCollateralValue(address user, address token) external view returns (uint256);
    function needsLiquidation(address user, address token, uint256 debtAmount) external view returns (bool);
    function liquidatePosition(address user, address token, uint256 debtAmount) external returns (uint256);
    function getCollateralPrice(address token) external view returns (uint256);
    function validateCollateralToken(address token) external view returns (bool);
    function initializeLoan(uint256 loanId,address borrower,address token,uint256 amount) external;
    function releaseLoanCollateral(uint256 loanId, address borrower) external;
}
/**
 * @title LendingMarketplace
 * @notice Advanced P2P lending marketplace with comprehensive features
 */
contract LendingMarketplace is ReentrancyGuard, Pausable, Ownable, AutomationCompatibleInterface {
    using Math for uint256;

    // Constants
    uint256 private  BASIS_POINTS = 10000;
    uint256 private  MIN_LOAN_DURATION = 1 days;
    uint256 private  MAX_LOAN_DURATION = 365 days;
    uint256 private  MAX_INTEREST_RATE = 3000; // 30%
    uint256 private  MIN_COLLATERAL_RATIO = 12000; // 120%

    // Enums
    enum ListingType { LENDER, BORROWER }
    enum LoanStatus { ACTIVE, REPAID, DEFAULTED, LIQUIDATED }

    // Structs
    struct LenderListing {
        address lender;
        uint256 amount;
        uint256 minInterestRate;
        uint256 maxDuration;
        address[] acceptedCollateralTokens;
        uint256 minCollateralRatio;
        bool isActive;
    }

    struct BorrowerListing {
        address borrower;
        uint256 amount;
        uint256 maxInterestRate;
        uint256 duration;
        address collateralToken;
        uint256 collateralAmount;
        bool isActive;
    }

    struct MatchedLoan {
        address lender;
        address borrower;
        uint256 amount;
        uint256 interestRate;
        uint256 duration;
        uint256 startTime;
        uint256 dueDate;
        uint256 gracePeriodEnd;
        uint256 lastInterestUpdate;
        uint256 accumulatedInterest;
        address collateralToken;
        uint256 collateralAmount;
        LoanStatus status;
    }

    struct UserMetrics {
        uint256 totalLent;
        uint256 totalBorrowed;
        uint256 activeLoans;
        uint256 successfulRepayments;
        uint256 defaults;
        uint256 averageInterestRate;
    }

    // State variables
    ICollateralManager public collateralManager;
    IERC20 public immutable stablecoin;
    
    mapping(uint256 => LenderListing) public lenderListings;
    mapping(uint256 => BorrowerListing) public borrowerListings;
    mapping(uint256 => MatchedLoan) public matchedLoans;
    mapping(address => UserMetrics) public userMetrics;
    mapping(address => uint256[]) public userLenderListings;
    mapping(address => uint256[]) public userBorrowerListings;
    mapping(address => uint256[]) public userActiveLoans;

    uint256 public nextLenderListingId;
    uint256 public nextBorrowerListingId;
    uint256 public nextLoanId;
    uint256 public totalLentAmount;
    uint256 public totalBorrowedAmount;

    // Events
    event LenderListingCreated(uint256 indexed listingId, address indexed lender, uint256 amount);
    event BorrowerListingCreated(uint256 indexed listingId, address indexed borrower, uint256 amount);
    event LoanMatched(uint256 indexed loanId, uint256 lenderListingId, uint256 borrowerListingId);
    event LoanRepaid(uint256 indexed loanId, uint256 amount);
    event ListingCancelled(uint256 indexed listingId, ListingType listingType);
    event GracePeriodSet(uint256 indexed loanId, uint256 endTime);
    event LoanDefaulted(uint256 indexed loanId);
    event MetricsUpdated(address indexed user, uint256 totalLent, uint256 totalBorrowed);

    constructor(address _stablecoin, address _collateralManager) Ownable(msg.sender) {
        if (_stablecoin == address(0)) revert InvalidParameters();
        stablecoin = IERC20(_stablecoin);
        collateralManager = ICollateralManager(_collateralManager); 
    }

    function setCollateralManager(address _collateralManager) external onlyOwner {
        if (_collateralManager == address(0)) revert InvalidParameters();
        collateralManager = ICollateralManager(_collateralManager);
    }

    function createLenderListing(
        uint256 amount,
        uint256 minInterestRate,
        uint256 maxDuration,
        address[] calldata acceptedCollateralTokens,
        uint256 minCollateralRatio
    ) external nonReentrant whenNotPaused returns (uint256) {
        if (amount == 0) revert InvalidAmount();
        if (minInterestRate > MAX_INTEREST_RATE) revert InvalidInterestRate();
        if (maxDuration < MIN_LOAN_DURATION || maxDuration > MAX_LOAN_DURATION) revert InvalidDuration();
        if (minCollateralRatio < MIN_COLLATERAL_RATIO) revert InsufficientCollateral();
        
        uint256 listingId = nextLenderListingId++;
        
        lenderListings[listingId] = LenderListing({
            lender: msg.sender,
            amount: amount,
            minInterestRate: minInterestRate,
            maxDuration: maxDuration,
            acceptedCollateralTokens: acceptedCollateralTokens,
            minCollateralRatio: minCollateralRatio,
            isActive: true
        });

        userLenderListings[msg.sender].push(listingId);
        
        if (!stablecoin.transferFrom(msg.sender, address(this), amount)) revert();

        emit LenderListingCreated(listingId, msg.sender, amount);
        return listingId;
    }

    function createBorrowerListing(
        uint256 amount,
        uint256 maxInterestRate,
        uint256 duration,
        address collateralToken,
        uint256 collateralAmount
    ) external nonReentrant whenNotPaused returns (uint256) {
        if (amount == 0) revert InvalidAmount();
        if (maxInterestRate > MAX_INTEREST_RATE) revert InvalidInterestRate();
        if (duration < MIN_LOAN_DURATION || duration > MAX_LOAN_DURATION) revert InvalidDuration();
        
        uint256 listingId = nextBorrowerListingId++;
        
        borrowerListings[listingId] = BorrowerListing({
            borrower: msg.sender,
            amount: amount,
            maxInterestRate: maxInterestRate,
            duration: duration,
            collateralToken: collateralToken,
            collateralAmount: collateralAmount,
            isActive: true
        });

        userBorrowerListings[msg.sender].push(listingId);

        emit BorrowerListingCreated(listingId, msg.sender, amount);
        return listingId;
    }

    function matchLoan(uint256 lenderListingId, uint256 borrowerListingId) 
        external 
        nonReentrant 
        whenNotPaused 
    {
        LenderListing storage lenderListing = lenderListings[lenderListingId];
        BorrowerListing storage borrowerListing = borrowerListings[borrowerListingId];

        if (!lenderListing.isActive || !borrowerListing.isActive) revert ListingNotFound();
        if (!_validateMatch(lenderListing, borrowerListing)) revert InvalidParameters();

        uint256 loanId = nextLoanId++;
        
        matchedLoans[loanId] = MatchedLoan({
            lender: lenderListing.lender,
            borrower: borrowerListing.borrower,
            amount: borrowerListing.amount,
            interestRate: lenderListing.minInterestRate,
            duration: borrowerListing.duration,
            startTime: block.timestamp,
            dueDate: block.timestamp + borrowerListing.duration,
            gracePeriodEnd: block.timestamp + borrowerListing.duration,
            lastInterestUpdate: block.timestamp,
            accumulatedInterest: 0,
            collateralToken: borrowerListing.collateralToken,
            collateralAmount: borrowerListing.collateralAmount,
            status: LoanStatus.ACTIVE
        });

        lenderListing.isActive = false;
        borrowerListing.isActive = false;

        userActiveLoans[borrowerListing.borrower].push(loanId);
        userActiveLoans[lenderListing.lender].push(loanId);

        // Initialize collateral with CollateralManager
        if (!IERC20(borrowerListing.collateralToken).transferFrom(
            borrowerListing.borrower,
            address(collateralManager),
            borrowerListing.collateralAmount
        )) revert();

        collateralManager.initializeLoan(
            loanId,
            borrowerListing.borrower,
            borrowerListing.collateralToken,
            borrowerListing.collateralAmount
        );

        // Transfer loan amount to borrower
        if (!stablecoin.transfer(borrowerListing.borrower, borrowerListing.amount)) revert();

        _updateMetrics(lenderListing.lender, borrowerListing.borrower, borrowerListing.amount);

        emit LoanMatched(loanId, lenderListingId, borrowerListingId);
    }

    function repayLoan(uint256 loanId) external nonReentrant whenNotPaused {
        MatchedLoan storage loan = matchedLoans[loanId];
        if (loan.status != LoanStatus.ACTIVE) revert LoanNotActive();
        if (msg.sender != loan.borrower) revert UnauthorizedAccess();

        uint256 interest = _calculateInterest(loan);
        uint256 totalRepayment = loan.amount+(interest);

        if (!stablecoin.transferFrom(msg.sender, loan.lender, totalRepayment)) revert();

        loan.status = LoanStatus.REPAID;
        collateralManager.releaseLoanCollateral(loanId, msg.sender);

        _updateUserMetricsOnRepayment(loan);

        emit LoanRepaid(loanId, totalRepayment);
    }

    function setGracePeriod(uint256 loanId, uint256 gracePeriod) external {
        MatchedLoan storage loan = matchedLoans[loanId];
        if (msg.sender != loan.lender) revert UnauthorizedAccess();
        if (loan.status != LoanStatus.ACTIVE) revert LoanNotActive();

        loan.gracePeriodEnd = loan.dueDate + gracePeriod;
        emit GracePeriodSet(loanId, loan.gracePeriodEnd);
    }

    // Chainlink Automation Functions
    function checkUpkeep(bytes calldata) 
        external 
        view 
        override 
        returns (bool upkeepNeeded, bytes memory performData) 
    {
        uint256[] memory defaultedLoans = _getDefaultedLoans();
        upkeepNeeded = defaultedLoans.length > 0;
        performData = abi.encode(defaultedLoans);
        return (upkeepNeeded, performData);
    }

    function performUpkeep(bytes calldata performData) external override {
        uint256[] memory defaultedLoans = abi.decode(performData, (uint256[]));
        for (uint256 i = 0; i < defaultedLoans.length; i++) {
            _handleDefault(defaultedLoans[i]);
        }
    }

    // Internal functions
    function _validateMatch(
        LenderListing memory lender,
        BorrowerListing memory borrower
    ) internal pure returns (bool) {
        return borrower.maxInterestRate >= lender.minInterestRate &&
               borrower.duration <= lender.maxDuration &&
               borrower.amount <= lender.amount;
    }

    function _calculateInterest(MatchedLoan memory loan) internal view returns (uint256) {
        uint256 timeElapsed = block.timestamp-(loan.lastInterestUpdate);
        return loan.amount
            *(loan.interestRate)
            *(timeElapsed)
            /(365 days)
            /(BASIS_POINTS);
    }

    function _updateMetrics(address lender, address borrower, uint256 amount) internal {
        totalLentAmount = totalLentAmount+(amount);
        totalBorrowedAmount = totalBorrowedAmount+(amount);

        UserMetrics storage lenderMetrics = userMetrics[lender];
        UserMetrics storage borrowerMetrics = userMetrics[borrower];

        lenderMetrics.totalLent = lenderMetrics.totalLent+(amount);
        borrowerMetrics.totalBorrowed = borrowerMetrics.totalBorrowed+(amount);
        lenderMetrics.activeLoans = lenderMetrics.activeLoans+(1);
        borrowerMetrics.activeLoans = borrowerMetrics.activeLoans+(1);

        emit MetricsUpdated(lender, lenderMetrics.totalLent, lenderMetrics.totalBorrowed);
        emit MetricsUpdated(borrower, borrowerMetrics.totalLent, borrowerMetrics.totalBorrowed);
    }

    function _updateUserMetricsOnRepayment(MatchedLoan memory loan) internal {
        UserMetrics storage lenderMetrics = userMetrics[loan.lender];
        UserMetrics storage borrowerMetrics = userMetrics[loan.borrower];

        lenderMetrics.activeLoans = lenderMetrics.activeLoans-(1);
        lenderMetrics.successfulRepayments = lenderMetrics.successfulRepayments+(1);
        borrowerMetrics.activeLoans = borrowerMetrics.activeLoans-(1);
        borrowerMetrics.successfulRepayments = borrowerMetrics.successfulRepayments+(1);
    } 

    function _getDefaultedLoans() internal view returns (uint256[] memory) {
        uint256[] memory defaultedLoans = new uint256[](nextLoanId);
        uint256 count = 0;

        for (uint256 i = 0; i < nextLoanId; i++) {
            MatchedLoan memory loan = matchedLoans[i];
            if (loan.status == LoanStatus.ACTIVE && 
                block.timestamp > loan.gracePeriodEnd) {
                defaultedLoans[count] = i;
                count++;
            }
        }

        // Resize array to actual count
        uint256[] memory result = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            result[i] = defaultedLoans[i];
        }

        return result;
    }

    function _handleDefault(uint256 loanId) internal {
        MatchedLoan storage loan = matchedLoans[loanId];
        if (loan.status != LoanStatus.ACTIVE) revert LoanNotActive();
        if (block.timestamp <= loan.gracePeriodEnd) revert GracePeriodNotExpired();

        loan.status = LoanStatus.DEFAULTED;

        // Update user metrics
        UserMetrics storage lenderMetrics = userMetrics[loan.lender];
        UserMetrics storage borrowerMetrics = userMetrics[loan.borrower];

        lenderMetrics.activeLoans = lenderMetrics.activeLoans-(1);
        lenderMetrics.defaults = lenderMetrics.defaults+(1);
        borrowerMetrics.activeLoans = borrowerMetrics.activeLoans-(1);
        borrowerMetrics.defaults = borrowerMetrics.defaults+(1);

        emit LoanDefaulted(loanId);
    }

    // Cancel listings
    function cancelLenderListing(uint256 listingId) external nonReentrant {
        LenderListing storage listing = lenderListings[listingId];
        if (msg.sender != listing.lender) revert UnauthorizedAccess();
        if (!listing.isActive) revert ListingNotFound();

        listing.isActive = false;
        if (!stablecoin.transfer(msg.sender, listing.amount)) revert();

        emit ListingCancelled(listingId, ListingType.LENDER);
    }

    function cancelBorrowerListing(uint256 listingId) external nonReentrant {
        BorrowerListing storage listing = borrowerListings[listingId];
        if (msg.sender != listing.borrower) revert UnauthorizedAccess();
        if (!listing.isActive) revert ListingNotFound();

        listing.isActive = false;
        emit ListingCancelled(listingId, ListingType.BORROWER);
    }

    // View functions
    function getLenderListing(uint256 listingId) external view returns (
        address lender,
        uint256 amount,
        uint256 minInterestRate,
        uint256 maxDuration,
        address[] memory acceptedCollateralTokens,
        uint256 minCollateralRatio,
        bool isActive
    ) {
        LenderListing storage listing = lenderListings[listingId];
        return (
            listing.lender,
            listing.amount,
            listing.minInterestRate,
            listing.maxDuration,
            listing.acceptedCollateralTokens,
            listing.minCollateralRatio,
            listing.isActive
        );
    }

    function getBorrowerListing(uint256 listingId) external view returns (
        address borrower,
        uint256 amount,
        uint256 maxInterestRate,
        uint256 duration,
        address collateralToken,
        uint256 collateralAmount,
        bool isActive
    ) {
        BorrowerListing storage listing = borrowerListings[listingId];
        return (
            listing.borrower,
            listing.amount,
            listing.maxInterestRate,
            listing.duration,
            listing.collateralToken,
            listing.collateralAmount,
            listing.isActive
        );
    }

    function getLoanDetails(uint256 loanId) external view returns (
        address lender,
        address borrower,
        uint256 amount,
        uint256 interestRate,
        uint256 duration,
        uint256 startTime,
        uint256 dueDate,
        uint256 gracePeriodEnd,
        uint256 accumulatedInterest,
        address collateralToken,
        uint256 collateralAmount,
        LoanStatus status
    ) {
        MatchedLoan storage loan = matchedLoans[loanId];
        return (
            loan.lender,
            loan.borrower,
            loan.amount,
            loan.interestRate,
            loan.duration,
            loan.startTime,
            loan.dueDate,
            loan.gracePeriodEnd,
            loan.accumulatedInterest,
            loan.collateralToken,
            loan.collateralAmount,
            loan.status
        );
    }

    function getUserMetrics(address user) external view returns (
        uint256 totalLent,
        uint256 totalBorrowed,
        uint256 activeLoans,
        uint256 successfulRepayments,
        uint256 defaults,
        uint256 averageInterestRate
    ) {
        UserMetrics storage metrics = userMetrics[user];
        return (
            metrics.totalLent,
            metrics.totalBorrowed,
            metrics.activeLoans,
            metrics.successfulRepayments,
            metrics.defaults,
            metrics.averageInterestRate
        );
    }

    function getUserListings(address user) external view returns (
        uint256[] memory lenderListingIds,
        uint256[] memory borrowerListingIds
    ) {
        return (
            userLenderListings[user],
            userBorrowerListings[user]
        );
    }

    function getUserActiveLoans(address user) external view returns (uint256[] memory) {
        return userActiveLoans[user];
    }

    // Emergency functions
    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // Update minimum requirements
    function updateMinimumRequirements(
        uint256 newMinLoanDuration,
        uint256 newMaxLoanDuration,
        uint256 newMaxInterestRate,
        uint256 newMinCollateralRatio
    ) external onlyOwner {
        if (newMinLoanDuration >= newMaxLoanDuration) revert InvalidParameters();
        if (newMaxInterestRate == 0) revert InvalidParameters();
        if (newMinCollateralRatio < 10000) revert InvalidParameters(); // Must be at least 100%

        // Update constants through a state update
        MIN_LOAN_DURATION = newMinLoanDuration;
        MAX_LOAN_DURATION = newMaxLoanDuration;
        MAX_INTEREST_RATE = newMaxInterestRate;
        MIN_COLLATERAL_RATIO = newMinCollateralRatio;
    }

    // Rescue functions for stuck tokens (should only be used in emergencies)
    function rescueTokens(
        address token,
        address to,
        uint256 amount
    ) external onlyOwner {
        if (token == address(stablecoin)) revert UnauthorizedAccess();
        IERC20(token).transfer(to, amount);
    }

    receive() external payable {
        revert();
    }
}
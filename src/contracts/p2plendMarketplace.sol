// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0 <0.9.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

error InvalidAddress();
error InvalidAmount();
error InvalidDuration();
error InvalidInterestRate();
error InsufficientBalance();
error InsufficientCollateral();
error ListingNotFound();
error UnauthorizedAccess();
error ListingAlreadyMatched();
error LoanNotActive();
error InvalidCollateralToken();
error GracePeriodNotExpired();
error InvalidGracePeriod();
error LoanNotDue();

interface ICollateralManager {
    function calculateCollateralValue(address user, address token) external view returns (uint256);
    function needsLiquidation(address user, address token, uint256 debtAmount) external view returns (bool);
    function liquidatePosition(address user, address token, uint256 debtAmount) external returns (uint256);
    function getCollateralPrice(address token) external view returns (uint256);
    function validateCollateralToken(address token) external view returns (bool);
}

contract P2PLendingMarketplace is ReentrancyGuard, Pausable, Ownable {
    IERC20 public immutable stablecoin;
    ICollateralManager public immutable collateralManager;
    
    uint256 private constant BASIS_POINTS = 10000;
    uint256 private constant MIN_COLLATERAL_RATIO = 12000;
    uint256 private constant MAX_INTEREST_RATE = 3000;
    uint256 private constant MAX_DURATION = 365 days;
    uint256 private constant MIN_DURATION = 1 days;
    uint256 private constant MAX_GRACE_PERIOD = 30 days;
}

enum ListingType{ LENDER, BORROWER}
enum LoanStatus { ACTIVE, REPAID, DEFAULTED, LIQUIDATED}

struct LenderListing {
    address lender;
    uint256 amount;
    uint256 minInterestRate;
    uint256 maxDuration;
    address[] acceptedCollateralTokens;
    uint256 minCollateralRation;
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
    address collateralToken;
    uint256 collateralAmount;
    uint256 startTime;
    uint256 dueDate;
    uint256 gracePeriodEnd;
    uint256 lastInterestUpdate;
    uint256 accumulatedInterest;
    LoanStatus status;
}
struct ListingSearchParams {
    uint256 minAmount;
    uint256 maxAmount;
    uint256 minDuration;
    uint256 maxDuration;
    uint256 minInterestRate;
    uint256 maxInterestRate;
    address[] collateralTokens;
    }
struct ListingDetails {
    uint256 listingId;
    address creator;
    uint256 amount;
    uint256 interestRate;
    uint256 duration;
    address[] collateralTokens;
    uint256 collateralAmount;
    uint256 timestamp;
    bool isActive;
    }
struct ListingMetadata {
    uint64 timestamp;
    uint32 matchQuality; // 0-10000 basis points
    bool isActive;
    }
struct UserDashboard {
    uint256 activeLentAmount;
    uint256 activeBorrowedAmount;
    uint256 earnedInterest;
    uint256 paidInterest;
    uint256 successfulLoans;
    uint256 averageInterestRate;
    uint256 reputation;
    }
struct MarketSnapshot {
    uint256 totalLentAmount;
    uint256 totalBorrowedAmount;
    uint256 activeListings;
    uint256 loansCompleted;
    uint256 averageMatchTime;
    uint256 bestLenderRate;
    uint256 bestBorrowerRate;
    uint256[] trendingCollateralTokens;
    }
struct UserNotificationSettings {
    bool matchAlert;
    bool repaymentReminder;
    bool rateAlert;
    uint256 minMatchQuality;
    uint256 collateralLiquidation;
    uint256 maxInterestRate;
    }

    // State variables
    mapping(address => UserDashboard) public userDashboards;
    mapping(address => UserNotificationSettings) public userNotificationSettings;
    mapping(address => uint256) public userReputation;
    mapping(address => uint256[]) public userLenderListings;
    mapping(address => uint256[]) public userBorrowerListings;
    mapping(address => uint256[]) public userActiveLoansBorrower;
    mapping(address => uint256[]) public userActiveLoansLender;
    mapping(uint256 => ListingMetadata) public lenderListingMetadata;
    mapping(uint256 => ListingMetadata) public borrowerListingMetadata;
    mapping(uint256 => LenderListing) public lenderListings;
    mapping(uint256 => BorrowerListing) public borrowerListings;
    mapping(uint256 => MatchedLoan) public matchedLoans;
    mapping(address => uint256[]) private userFavorites;    

    uint256 public nextLenderListingId;
    uint256 public nextBorrowerListingId;
    uint256 public nextLoanId;
    uint256 public totalLentAmount;
    uint256 public totalBorrowedAmount;
    uint256 public activeListings;
    uint256 public loansCompleted;

    // Events
    event LenderListingCreated(uint256 indexed listingId, address indexed lender, uint256 amount);
    event BorrowerListingCreated(uint256 indexed listingId, address indexed borrower, uint256 amount);
    event LoanMatched(uint256 indexed loanId, uint256 lenderListingId, uint256 borrowerListingId);
    event LoanRepaid(uint256 indexed loanId, uint256 amount);
    event GracePeriodSet(uint256 indexed loanId, uint256 endTime);
    event LoanLiquidated(uint256 indexed loanId, address indexed liquidator);
    event ListingCancelled(uint256 indexed listingId, ListingType listingType);

    // Events for frontend integration
    event ListingMatched(uint256 indexed listingId, uint256 indexed matchedListingId, uint256 matchQuality);
    event ListingUpdated(uint256 indexed listingId, bool isLenderListing, bool isActive);
    event MarketMetricsUpdated(
        uint256 totalActiveLenderListings,
        uint256 totalActiveBorrowerListings,
        uint256 averageInterestRate
    );

    // Events for frontend updates
    event MatchAlert(address indexed user, uint256 indexed listingId, uint256 matchQuality);
    event RepaymentReminder(address indexed borrower, uint256 indexed loanId, uint256 dueIn);
    event RateAlert(address indexed user, uint256 indexed listingId, uint256 newRate);
    event ReputationUpdated(address indexed user, uint256 newScore);
    event LiquidationWarning(address indexed borrower, uint256 indexed loanId, uint256 collateralPercentage);

constructor(address _stablecoin, address _collateralManager) Ownable(msg.sender) {
    if (_stablecoin == address(0) || _collaterManager == address(0)) revert InvalidAddress();
    stablecoin = IERC20(_stablecoin);
    collateralManager = ICollateralManager(_collateralManager);   
}
function createLenderListing(uint256 amount, uint256 minInterestRate, uint256 maxDuration, address[] calldata acceptedCollateralTokens, uint256 minCollateralRatio) external nonReentrant whenNotPaused returns(uint256) {
    if (amount == 0) revert InvalidAmount;
    if (minInterestRate > MAX_INTEREST_RATE) revert InvalidInterestRate();
    if (maxDuration > MAX_DURATION) revert InvalidDuration();
    if (minCollateralRatio < MIN_COLLATERAL_RATIO) revert InsufficientCollateral();
    for (uint256 i = 0; i < acceptedCollateralTokens.length; ++i) {
        if (!collateralManager.validateCollateralToken(acceptedCollateralTokens[i])) {
            revert InvalidCollateralToken();
        }
    }
    uint256 listingId = ++nextLenderListingId;
    LenderListing storage listing = lenderListings[listingId];
    listing.lender = msg.sender;
    listing.amount = amount;
    listing.minInterestRate = minInterestRate;
    listing.maxDuration = maxDuration;
    listing.acceptedCollateralTokens = acceptedCollateralTokens;
    listing.minCollateralRatio = minCollateralRatio;
    listing.isActive = true;
    UserLenderListings[msg.sender].push(listingId);
    ++activeListings;

    // Transfer funds to contract
    if (!stablecoin.transferFrom(msg.sender, address(this), amount)) revert();

    emit LenderListingCreated(listingId, msg.sender, amount);
    return listingId;
}
function createBorrowerListing(uint256 amount, uint256 maxInterestRate, uint256 duration, address collateralToken, uint256 collateralAmount) external nonReentrant whenNotPaused returns (uint256) {
    if (amount == 0) revert InvalidAmount;
    if (maxInterestRate > MAX_INTEREST_RATE) revert InvalidInterestRate();
    if (duration > MAX_DURATION) revert InvalidDuration();
    if (!collateralManager.validateCollateralToken(collateralToken)) {
        revert InvalidCollateralToken();
        }
    uint256 listingId = nextBorrowerListingId++;
    BorrowerListing storage listing = borrowerListings[listingId];
    listing.borrower = msg.sender;
    listing.amount = amount;
    listing.maxInterestRate = maxInterestRate;
    listing.duration = duration;
    listing.collateralToken = collateralToken;
    listing.collateralAmount = collateralAmount;
    listing.isActive = true;

    userBorrowerListings[msg.sender].push(listingId);
    ++activeListings;

    emit BorrowerListingCreated(listingId, msg.sender, amount);
    return listingId;
} 
function matchLoan(uint256 lenderListingId, uint256 borrowerListingId)external nonReentrant whenNotPaused{
        LenderListing storage lenderListing = lenderListings[lenderListingId];
        BorrowerListing storage borrowerListing = borrowerListings[borrowerListingId];
        if (!lenderListing.isActive || !borrowerListing.isActive) revert ListingNotFound();
        require(borrowerListing.maxInterestRate >= lenderListing.minInterestRate, "Interest rate mismatch");
        require(borrowerListing.duration <= lenderListing.maxDuration, "Duration too long");
        require(borrowerListing.amount <= lenderListing.amount, "Amount too high");
        bool validCollateral = false;
        for (uint i = 0; i < lenderListing.acceptedCollateralTokens.length; i++) {
            if (lenderListing.acceptedCollateralTokens[i] == borrowerListing.collateralToken) {
                validCollateral = true;
                break;
            }
        }
        require(validCollateral, "Collateral token not accepted");
        uint256 loanId = nextLoanId++;
        MatchedLoan storage loan = matchedLoans[loanId];
        loan.lender = lenderListing.lender;
        loan.borrower = borrowerListing.borrower;
        loan.amount = borrowerListing.amount;
        loan.interestRate = lenderListing.minInterestRate;
        loan.duration = borrowerListing.duration;
        loan.collateralToken = borrowerListing.collateralToken;
        loan.collateralAmount = borrowerListing.collateralAmount;
        loan.startTime = block.timestamp;
        loan.dueDate = block.timestamp + borrowerListing.duration;
        loan.gracePeriodEnd = block.timestamp + borrowerListing.duration;
        loan.lastInterestUpdate = block.timestamp;
        loan.status = LoanStatus.ACTIVE;

        // Update listings
        lenderListing.isActive = false;
        --activeListings;
        borrowerListing.isActive = false;
        --activeListings;

        // Track active loans
        userActiveLoansBorrower[borrowerListing.borrower].push(loanId);
        userActiveLoansLender[lenderListing.lender].push(loanId);

        // Transfer funds
        if (!stablecoin.transfer(borrowerListing.borrower, borrowerListing.amount)) revert();
        totalBorrowedAmount += amount;
        totalLentAmount += amount;

        emit LoanMatched(loanId, lenderListingId, borrowerListingId);
    }
function repayLoan(uint256 loanId, uint256 amount) external nonReentrant whenNotPaused {
        MatchedLoan storage loan = matchedLoans[loanId];
        if (loan.status != LoanStatus.ACTIVE) revert LoanNotActive();
        if (msg.sender != loan.borrower) revert UnauthorizedAccess();

        _updateInterest(loanId);
        uint256 totalOwed = loan.amount + loan.accumulatedInterest;
        require(amount <= totalOwed, "Amount exceeds debt");

        if (amount == totalOwed) {
            loan.status = LoanStatus.REPAID;
        }

        // Transfer repayment
        if (!stablecoin.transferFrom(msg.sender, loan.lender, amount)) revert();
        ++loansCompleted;

        emit loansCompleted(loanId, amount);
    }
function setGracePeriod(uint256 loanId, uint256 gracePeriod) external {
        MatchedLoan storage loan = matchedLoans[loanId];
        if (msg.sender != loan.lender) revert UnauthorizedAccess();
        if (loan.status != LoanStatus.ACTIVE) revert LoanNotActive();
        if (gracePeriod > MAX_GRACE_PERIOD) revert InvalidGracePeriod();
        if (loan.dueDate <= block.timestamp) revert LoanNotDue();

        loan.gracePeriodEnd = block.timestamp + gracePeriod;
        emit GracePeriodSet(loanId, loan.gracePeriodEnd); //want to add update checker for how many graces have been given by a lender and how many a borrower has recieved
    }
function liquidateLoan(uint256 loanId) external nonReentrant whenNotPaused {
        MatchedLoan storage loan = matchedLoans[loanId];
        if (loan.status != LoanStatus.ACTIVE) revert LoanNotActive();
        
        // Check if grace period has expired
        if (loan.gracePeriodEnd > block.timestamp) revert GracePeriodNotExpired();

        _updateInterest(loanId);
        uint256 totalOwed = loan.amount + loan.accumulatedInterest;

        require(
            block.timestamp > loan.gracePeriodEnd || 
            collateralManager.needsLiquidation(
                loan.borrower,
                loan.collateralToken,
                totalOwed
            ),
            "Cannot liquidate"
        );

        uint256 liquidatedAmount = collateralManager.liquidatePosition(
            loan.borrower,
            loan.collateralToken,
            totalOwed
        );

        loan.status = LoanStatus.LIQUIDATED;

        // Transfer liquidated funds
        if (!stablecoin.transfer(msg.sender, liquidatedAmount)) revert();

        emit LoanLiquidated(loanId, msg.sender);
    }
function _updateInterest(uint256 loanId) internal {
        MatchedLoan storage loan = matchedLoans[loanId];
        uint256 timeElapsed = block.timestamp - loan.lastInterestUpdate;
        if (timeElapsed == 0) return;

        uint256 interest = (loan.amount * loan.interestRate * timeElapsed) /
            (BASIS_POINTS * 365 days);
        
        loan.accumulatedInterest += interest;
        loan.lastInterestUpdate = block.timestamp;
    }
function _requireCollateralTopUp(uint256 loanId,uint256 currentDebt,uint256 collateralValue) internal {
        MatchedLoan storage loan = matchedLoans[loanId];
        if (collateral.token != collateralToken) revert InvalidParameters();
        if collateralValue == currentDebt {
            collateral.requiresTopUp;
        }

    }

function handleCollateralTopUp(uint256 loanId,address collateralToken,uint256 collateralAmount) external nonReentrant {
        CollateralInfo storage collateral = collateralData[loanId];
        if (collateral.token != collateralToken) revert InvalidParameters();
        if (!collateral.requiresTopUp) revert InvalidParameters();

        // Transfer additional collateral
        IERC20(collateralToken).transferFrom(msg.sender, address(this), collateralAmount);
        
        collateral.amount = collateral.amount.add(collateralAmount);
        collateral.requiresTopUp = false;

        emit CollateralAdded(loanId, collateralAmount);
    }
function _processPartialRepayment(uint256 loanId,uint256 amount) private returns (uint256) {
        // Implementation details for partial repayment processing
        // Returns remaining balance

        return 0; // Placeholder return
    }
function partialRepayment(uint256 loanId,uint256 amount) external nonReentrant {
        if (amount == 0) revert InvalidAmount();
        
        // Update loan balance and interest calculations
        uint256 remainingBalance = _processPartialRepayment(loanId, amount);
        
        emit PartialRepayment(loanId, amount, remainingBalance);
    }
function calculateMatchQuality(LenderListing memory lenderListing,BorrowerListing memory borrowerListing internal pure returns (uint256) {
        // Base requirements
        if (borrowerListing.amount > lenderListing.amount) return 0;
        if (borrowerListing.maxInterestRate < lenderListing.minInterestRate) return 0;
        if (borrowerListing.duration > lenderListing.maxDuration) return 0;

        // Calculate match quality (10000 = perfect match)
        uint256 quality = 10000;

        // Amount match (3333 points max)
        uint256 amountRatio = (borrowerListing.amount * 10000) / lenderListing.amount;
        quality = (quality * amountRatio) / 10000;

        // Interest rate match (3333 points max)
        uint256 rateOverlap = 10000 - (
            (borrowerListing.maxInterestRate - lenderListing.minInterestRate) * 10000 / MAX_INTEREST_RATE
        );
        quality = (quality * rateOverlap) / 10000;

        // Duration match (3334 points max)
        uint256 durationRatio = (borrowerListing.duration * 10000) / lenderListing.maxDuration;
        quality = (quality * durationRatio) / 10000;

        return quality;
    }

function findMatchingListings(uint256 listingId, bool isLenderListing, uint256 startIndex,uint256 limit) external view returns (ListingDetails[] memory matches,uint256[] memory matchQualities,uint256 totalMatches) {
        // Initialize return arrays
        matches = new ListingDetails[](limit);
        matchQualities = new uint256[](limit);
        uint256 matchCount = 0;
        uint256 total = 0;

        if (isLenderListing) {
            LenderListing memory lenderListing = lenderListings[listingId];
            require(lenderListing.isActive, "Listing not active");

            // Iterate through borrower listings
            for (uint256 i = startIndex; i < nextBorrowerListingId && matchCount < limit; ++i) {
                BorrowerListing memory borrowerListing = borrowerListings[i];
                if (!borrowerListing.isActive) continue;

                uint256 quality = calculateMatchQuality(lenderListing, borrowerListing);
                if (quality > 0) {
                    matches[matchCount] = createListingDetails(false, i, borrowerListing);
                    matchQualities[matchCount] = quality;
                    ++matchCount;
                    ++total;
                }
            }
        } else {
            BorrowerListing memory borrowerListing = borrowerListings[listingId];
            require(borrowerListing.isActive, "Listing not active");

            // Iterate through lender listings
            for (uint256 i = startIndex; i < nextLenderListingId && matchCount < limit; i++) {
                LenderListing memory lenderListing = lenderListings[i];
                if (!lenderListing.isActive) continue;

                uint256 quality = calculateMatchQuality(lenderListing, borrowerListing);
                if (quality > 0) {
                    matches[matchCount] = createListingDetails(true, i, lenderListing);
                    matchQualities[matchCount] = quality;
                    ++matchCount;
                    ++total;
                }
            }
        }
        assembly {
            mstore(matches, matchCount)
            mstore(matchQualities, matchCount)
        }

        return (matches, matchQualities, total);
    }
function createListingDetails(bool isLender,uint256 id,LenderListing memory listing) internal pure returns (ListingDetails memory) {
        return ListingDetails({
            listingId: id,
            creator: listing.lender,
            amount: listing.amount,
            interestRate: listing.minInterestRate,
            duration: listing.maxDuration,
            collateralToken: address(0), // Not applicable for lender
            collateralAmount: 0, // Not applicable for lender
            timestamp: 0, // Filled from metadata
            isActive: listing.isActive
        });
    }
function getMarketMetrics() external view returns (uint256 totalActiveLenderListings,uint256 totalActiveBorrowerListings,uint256 averageInterestRate) {
        uint256 totalInterestRate = 0;
        uint256 interestRateCount = 0;

        // Count active listings and calculate average interest rate
        for (uint256 i = 0; i < nextLenderListingId; i++) {
            if (lenderListings[i].isActive) {
                totalActiveLenderListings++;
                totalInterestRate += lenderListings[i].minInterestRate;
                interestRateCount++;
            }
        }

        for (uint256 i = 0; i < nextBorrowerListingId; i++) {
            if (borrowerListings[i].isActive) {
                totalActiveBorrowerListings++;
                totalInterestRate += borrowerListings[i].maxInterestRate;
                interestRateCount++;
            }
        }

        averageInterestRate = interestRateCount > 0 ? totalInterestRate / interestRateCount : 0;
    }
    // View functions
function getLenderListing(uint256 listingId) external view returns (LenderListing memory) {
        return lenderListings[listingId];
    }
function getBorrowerListing(uint256 listingId) external view returns (BorrowerListing memory) {
        return borrowerListings[listingId];
    }
function getMatchedLoan(uint256 loanId) external view returns (MatchedLoan memory) {
        return matchedLoans[loanId];
    }
function getUserLenderListings(address user) external view returns (uint256[] memory) {
        return userLenderListings[user];
    }
function getUserBorrowerListings(address user) external view returns (uint256[] memory) {
        return userBorrowerListings[user];
    }
function getUserActiveLoans(address user, bool isBorrower) external view returns (uint256[] memory) {
        return isBorrower ? userActiveLoansBorrower[user] : userActiveLoansLender[user];
    }
function getUserDashboard(address user) external view returns (UserDashboard memory) {
        return userDashboards[user];
    }
function updateNotificationSettings(UserNotificationSettings calldata settings) external {
        userNotificationSettings[msg.sender] = settings;
    }
function addToFavorites(uint256 listingId) external {
        userFavorites[msg.sender].push(listingId);
    }
function getFavorites() external view returns (uint256[] memory) {
        return userFavorites[msg.sender];
    }
// Quick match suggestions
function getQuickMatches(uint256 listingId, bool isLender)external view returns (uint256[] memory matchingListings,uint256[] memory matchQualities,uint256[] memory estimatedROI) {
        // Implementation details...
    }
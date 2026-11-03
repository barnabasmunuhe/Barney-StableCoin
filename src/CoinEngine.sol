// // Layout of Contract:
// // version
// // imports
// // interfaces, libraries, contracts
// // errors
// // Type declarations
// // State variables
// // Events
// // Modifiers
// // Functions

// // Layout of Functions:
// // constructor
// // receive function (if exists)
// // fallback function (if exists)
// // external & public
// // internal & private
// // internal & private view & pure functions
// // external & public view & pure functions

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BarneyStableCoin} from "./BarneyStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol"; //EXECUTION SECURITY
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol"; //TOKEN INTERACTION SAFETY
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {OracleLib} from "./libraries/OracleLib.sol";

/// @title  CoinEngine
/// @author Barnabas Munuhe
/// @notice System should maintain 1 token == $1 peg
/// @notice Holds the properties:
///  1. Exogenous Collateral (ETH and BTC)
///  2. Algorithmically stable
///  3. Dollar Pegged
/// @dev    It's similar to DAI if DAI has no governance, no fees, and was only backed by wETH & wBTC
/// @notice The system should ALWAYS be overcollateralized. At no point should the value of the collateral be less than the value of the BSC. This is to ensure that the system can always be solvent, even in the face of extreme market volatility.
/// @dev    This contract is the core of the BSC system. It will handle all the logic for minting and redeeming the BSC, as well as maintaining the collateralization ratio of the system.
/// @notice This contract is VERY loosely based on the MakerDAO DSS (DAI) system.
contract CoinEngine is ReentrancyGuard {
    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/
    error CoinEngine__Must_Be_More_Than_Zero();
    error CoinEngine__Token_Addresses_And_PriceFeeds_Length_Mismatch();
    error CoinEngine__Not_Allowed_Token();
    error CoinEngine__Health_Factor_Below_Minimum(uint256 user_Health_Factor);
    error CoinEngine__Mint_Failed();
    error CoinEngine__Health_Factor_Is_OK();
    error CoinEngine__health_Factor_Not_Improved();
    error CoinEngine__InsufficientCollateral();
    error CoinEngine__No_CollateralTokens();
    error CoinEngine__Zero_Address();
    error CoinEngine__DuplicateCollateralToken();

    /*//////////////////////////////////////////////////////////////
                           TYPE DECLARATIONS
    //////////////////////////////////////////////////////////////*/
    using SafeERC20 for IERC20;
    using OracleLib for AggregatorV3Interface;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/
    event CollateralDeposited(
        address indexed user, address indexed tokenCollateralAddress, uint256 indexed amountCollateral
    );
    event CollateralRedeemed(
        address indexed redeemFrom, address indexed redeemTo, address indexed token, uint256 amount
    );
    event BadDebtRecognized(address indexed user, uint256 amount);
    event ReserveAccrued(address indexed token, uint256 fee);

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/
    uint256 private constant FEE_PRECISION = 1e10; //decimal scaling factor between Chainlink's 8-decimal price & protocol's 18-decimal accounting
    uint256 private constant PRECISION = 1e18; // precision for price feeds and calculations
    uint256 private constant LIQUIDATION_THRESHOLD = 50; //200% overcollateralization means 50% liquidation threshold(RISK PARAMETER)
    uint256 private constant LIQUIDATION_PRECISION = 100; // precision for liquidation threshold calculations
    uint256 private constant LIQUIDATION_BONUS = 10; // This is 10% bonus for liquidators
    uint256 private constant MIN_HEALTH_FACTOR = 1e18; // health factor must be above 1(SOLVENCY INVARIANT)

    BarneyStableCoin private immutable i_bsc;
    mapping(address token => address priceFeed) private s_priceFeeds; // collateralToken To Chainlink priceFeed mapping
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited; // userCollateralBalance mapping
    mapping(address token => uint256 total) private s_totalCollateralDeposited;
    mapping(address user => uint256 amountBscMinted) private s_bscMinted;
    mapping(address token => uint256 amount) private s_reserve;
    address[] private s_collateralTokens; // array to keep track of the collateral tokens used in the system
    uint256 private s_totalBadDebt; //Tracks bad debt

    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant REDEEM_FEE_BPS = 10; // 0.10%

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/
    modifier moreThanZero(uint256 amount) {
        if (amount <= 0) {
            revert CoinEngine__Must_Be_More_Than_Zero();
        }
        _;
    }

    modifier isAllowedToken(address token) {
        if (s_priceFeeds[token] == address(0)) {
            revert CoinEngine__Not_Allowed_Token();
        }
        _;
    }

    // modifier onlyEthAndBtcAllowed(address token){
    //     if (s_priceFeeds[token] != (EthAddress).blockchainid || (BtcAddress).blockchainid){
    //         revert CoinEngine__NotAllowedToken();
    //     }
    //     _;
    // }

    /*//////////////////////////////////////////////////////////////
                               FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    /// @dev Feeds are NOT validated at construction. A broken feed is caught on first
    ///      use via the OracleLib staleness + positivity checks. This avoids
    ///      expensive constructor calls and matches how Uniswap V3 pools defer
    ///      oracle setup to first observation.
    constructor(address[] memory tokenCollateralAddresses, address[] memory priceFeedAddresses, address bscAddress) {
        if (tokenCollateralAddresses.length != priceFeedAddresses.length) {
            revert CoinEngine__Token_Addresses_And_PriceFeeds_Length_Mismatch();
        }

        if (tokenCollateralAddresses.length == 0) {
            revert CoinEngine__No_CollateralTokens();
        }

        if (bscAddress == address(0)) {
            revert CoinEngine__Zero_Address();
        }

        for (uint256 i = 0; i < tokenCollateralAddresses.length; i++) {
            if (tokenCollateralAddresses[i] == address(0)) revert CoinEngine__Zero_Address();
            if (priceFeedAddresses[i] == address(0)) revert CoinEngine__Zero_Address();

            // Duplicate check — O(n²) but n is tiny
            for (uint256 j = 0; j < i; j++) {
                if (tokenCollateralAddresses[j] == tokenCollateralAddresses[i]) {
                    revert CoinEngine__DuplicateCollateralToken();
                }
            }
            s_priceFeeds[tokenCollateralAddresses[i]] = priceFeedAddresses[i]; //setting the tokenAddresses against corresponding pricefeed address
            s_collateralTokens.push(tokenCollateralAddresses[i]); //pushing the tokenAddress of i to the collateralTokens array
        }

        i_bsc = BarneyStableCoin(bscAddress); //The Constructor receives the BSC token address & stores it
    }

    /*//////////////////////////////////////////////////////////////
                               PUBLIC & EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    /// @dev Deliberately not nonReentrant — inner calls guard individually.
    /// @dev  This function allows users to deposit collateral and mint DSC in a single transaction.
    function depositCollateralAndMintBSC(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountToMint)
        external
    {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintBSC(amountToMint);
    }

    /// @notice Follows the Checks-Effects-Interactions pattern
    /// @param tokenCollateralAddress The address of the collateral token (e.g. wETH or wBTC)
    /// @param amountCollateral The amount of collateral to deposit
    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
    {
        //update the user's collateral balance(updating the state)
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        s_totalCollateralDeposited[tokenCollateralAddress] += amountCollateral;
        //transfer the collateral from the user to the contract (interacting with an external contract)
        IERC20(tokenCollateralAddress).safeTransferFrom(msg.sender, address(this), amountCollateral);
        // safeTransferFrom will revert if the transfer fails, so we don't need to check for a failed transfer here.
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);
    }

    /// @param tokenCollateralAddress The address of the token to redeem as collateral
    ///@param amountCollateral The amount of collateral to redeem
    /// @param amountBSCToBurn The amount of BSC to burn
    /// @notice This function burns & redeems collateral in a single transaction
    /// @dev Deliberately not nonReentrant — inner calls guard individually.
    function redeemBSCForCollateral(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountBSCToBurn)
        external
    {
        burnBSC(amountBSCToBurn);
        redeemCollateral(tokenCollateralAddress, amountCollateral);
        // redeem collateral already checks health factor
    }

    // @notice inorder to redeem collateral:
    // 1. user health factor must be above the minimum threshold after redeeming collateral. If not, revert the transaction.
    function redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        nonReentrant
        isAllowedToken(tokenCollateralAddress)
    {
        if (amountCollateral > s_collateralDeposited[msg.sender][tokenCollateralAddress]) {
            revert CoinEngine__InsufficientCollateral();
        }
        uint256 fee = amountCollateral * REDEEM_FEE_BPS / BPS_DENOMINATOR;
        uint256 userReceives = amountCollateral - fee;
        // State updates
        s_collateralDeposited[msg.sender][tokenCollateralAddress] -= amountCollateral;
        s_totalCollateralDeposited[tokenCollateralAddress] -= amountCollateral;
        if (fee > 0) {
            s_reserve[tokenCollateralAddress] += fee;
            emit ReserveAccrued(tokenCollateralAddress, fee);
        }
        // Interaction
        IERC20(tokenCollateralAddress).safeTransfer(msg.sender, userReceives);
        emit CollateralRedeemed(msg.sender, msg.sender, tokenCollateralAddress, userReceives);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    // get BSC minted & stores it
    // get the value of the collateral deposited > minted BSC
    function mintBSC(uint256 amountToMint) public moreThanZero(amountToMint) nonReentrant {
        s_bscMinted[msg.sender] += amountToMint; //update the user's BSC minted balance(updating the state)
        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_bsc.mint(msg.sender, amountToMint); //interacting with the BSC contract to mint the BSC to the user
        if (!minted) {
            revert CoinEngine__Mint_Failed();
        }
    }
    //

    function burnBSC(uint256 amountToBurn) public nonReentrant moreThanZero(amountToBurn) {
        _burnBSC(msg.sender, msg.sender, amountToBurn);
        //burning BSC won't break the health factor because we're removing the user's debt from the system but we will include a check just to be safe.
        _revertIfHealthFactorIsBroken(msg.sender); // Defensive: burning only reduces debt, so HF can only improve — kept as a guard.
    }

    // if we nearing undercollaterization, we need someone to liquidate positions
    /**
     * @param collateral The erc20 collateral address to liquidate from the user
     * @param user The user who's health factor is broken.(should be below MIN_HEALTH_FACTOR)
     * @param debtToCover The amount of BSC you want to burn to improve the user's health factor
     * @notice You can partially liquidate a user
     * @notice You will get a liquidation bonus for taking the users funds.
     * @notice The system will always be overcollaterized roughly 200% in order for the liquidation to work
     * @dev We won't be able to incentivice the users if the protocol were 100% or less collaterized
     * eg.if the price of the collateral plumeted before anyone would be liquidated
     *  /// @dev Bad debt is only recognized when ALL collateral is exhausted. Partial-coverage
     * ///      positions (some collateral, insufficient to cover debt) are not flagged here —
     * ///      they remain liquidatable and only become bad debt once fully drained.
     * follows CEI
     */
    function liquidate(address collateral, address user, uint256 debtToCover)
        external
        nonReentrant
        moreThanZero(debtToCover)
    {
        uint256 userStartingHealthFactor = _healthFactor(user);
        if (userStartingHealthFactor >= MIN_HEALTH_FACTOR) {
            revert CoinEngine__Health_Factor_Is_OK();
        }

        // never try to burn more debt than the user has
        uint256 userDebt = s_bscMinted[user];
        if (debtToCover > userDebt) {
            debtToCover = userDebt;
        }
        // Fetching user collateral balance
        uint256 userCollateralBalance = s_collateralDeposited[user][collateral];

        // Converting the debt into a collateral-token amount
        uint256 collateralAmountFromDebtCovered = getCollateralAmountFromUsd(collateral, debtToCover);

        // Incetivising users by 10% of the debt to be covered
        // liqudator receives $110 of  wETH for 100 BSC
        // We should implement a feature to liquidate in the event the protocol is insolvent
        uint256 liquidationBonus = collateralAmountFromDebtCovered * LIQUIDATION_BONUS / LIQUIDATION_PRECISION;
        uint256 totalCollateralToEarn = collateralAmountFromDebtCovered + liquidationBonus;

        // Cap: never redeem more collateral than the user actually has.
        // If the liquidator's request exceeds the user's balance, give them everything
        // and shrink debtToCover to preserve the 1.1x bonus ratio on the capped amount.
        if (totalCollateralToEarn > userCollateralBalance) {
            totalCollateralToEarn = userCollateralBalance;
            uint256 cappedCollateralForDebt =
                userCollateralBalance * LIQUIDATION_PRECISION / (LIQUIDATION_PRECISION + LIQUIDATION_BONUS);
            debtToCover = getUsdValue(collateral, cappedCollateralForDebt);
        }
        // Burn user's BSC
        _burnBSC(user, msg.sender, debtToCover);
        // check health_factor
        _redeemCollateral(user, msg.sender, collateral, totalCollateralToEarn);
        uint256 endingHealthFactor = _healthFactor(user);
        // Only enforce "must improve" when the position was above the 0.55 threshold.
        // Below 0.55, liquidation *cannot* mathematically improve HF (see writeup),
        // so demanding improvement would make the position permanently unliquidatable.
        if (userStartingHealthFactor >= (MIN_HEALTH_FACTOR * 55) / 100) {
            if (endingHealthFactor <= userStartingHealthFactor) {
                revert CoinEngine__health_Factor_Not_Improved();
            }
        }

        // Track residual bad debt (debt with no collateral back)
        uint256 remainingDebt = s_bscMinted[user];
        if (remainingDebt > 0 && getTotalAccountCollateralValueInUsd(user) == 0) {
            s_totalBadDebt += remainingDebt;
            emit BadDebtRecognized(user, remainingDebt);
        }
        // checking if the liquidator's health factor aint broken in the process of liquidation
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function getHealthFactor(address user) external view returns (uint256) {
        return _healthFactor(user);
    }

    // ASSET WITHDRAWAL: The user is redeeming their collateral from the system. This will reduce their collateral in the system
    function _redeemCollateral(address from, address to, address tokenCollateralAddress, uint256 amountCollateral)
        private
    {
        s_collateralDeposited[from][tokenCollateralAddress] -= amountCollateral; //(Internal Accounting) pulling their debt out of the system
        s_totalCollateralDeposited[tokenCollateralAddress] -= amountCollateral;
        emit CollateralRedeemed(from, to, tokenCollateralAddress, amountCollateral);
        IERC20(address(tokenCollateralAddress)).safeTransfer(to, amountCollateral); //transfer the token from the smart contract to the user
    }

    /*//////////////////////////////////////////////////////////////
                  PRIVATE AND INTERNAL VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    /**
     * @dev CAVEAT: low-level internal function here! Do not call unless function calling it
     * is checking for health factor state
     */
    //  DEBT REDUCTION: The user is burning their BSC to reduce their debt in the system. This will improve their health factor and make them less likely to be liquidated.
    function _burnBSC(address onBehalfOf, address bscFrom, uint256 amountBscToBurn) private {
        s_bscMinted[onBehalfOf] -= amountBscToBurn; // removing their stableCoin debt from the system
        IERC20(address(i_bsc)).safeTransferFrom(bscFrom, address(this), amountBscToBurn); // transfer the BSC from the user to the smart contract
        i_bsc.burn(amountBscToBurn);
    }

    function _getAccountInformation(address user)
        private
        view
        returns (uint256 totalBscMinted, uint256 collateralValueInUsd)
    {
        totalBscMinted = s_bscMinted[user];
        collateralValueInUsd = getTotalAccountCollateralValueInUsd(user); //total collateral value in USD the user has deposited in the system
    }

    /**
     * @notice Returns the health factor of a user, which is a measure of how close they are to being undercollateralized/liquidation.
     *  A health factor above 1 means the user is safe, while a health factor below 1 means the user is at risk of liquidation.
     * @param user The address of the user to calculate the health factor for
     * @notice ADJUSTEDCOLLATERALVALUEINUSD > TOTALBSCMINTED(debt)
     */
    function _healthFactor(address user) private view returns (uint256) {
        //total BSC tokens minted && // total collateral value in usd
        (uint256 totalBscMinted, uint256 TotalCollateralValueInUsd) = _getAccountInformation(user); //totalBscMinted & TotalCollateralValue are a tuple of the user's account information

        // PREVENTS division by zero error
        if (totalBscMinted == 0) {
            return type(uint256).max; //the function will immediately exit by preventing "division by zero error"
        }
        // $100  * 50 = 5000 / 100 = 50
        uint256 TotalCollateralInUsdAdjustedForThreshold =
            TotalCollateralValueInUsd * LIQUIDATION_THRESHOLD / LIQUIDATION_PRECISION;
        // $1000 ETH  100 BSCtoMint
        // COMPARING THE ADJUSTED COLLATERAL VALUE AGAINST DEBT.
        // $1000(TotalCollateralValue) * 50(liquidation_threshold) = 50000 / 100(liquidation_precision) = 500 / 100(BSCMinted) = 5 health factor > 1 means safe, < 1 means at risk of liquidation
        return (TotalCollateralInUsdAdjustedForThreshold * PRECISION) / totalBscMinted; // return health factor with precision
    }

    /**
     * @notice Reverts if the user's health factor is below the minimum threshold
     * @param user The address of the user to check the health factor for
     */
    function _revertIfHealthFactorIsBroken(address user) internal view {
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert CoinEngine__Health_Factor_Below_Minimum(userHealthFactor);
        }
    }

    /*//////////////////////////////////////////////////////////////
                          EXTERNAL & PUBLIC  GETTER FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    function getAccountInformation(address user)
        external
        view
        returns (uint256 totalBscMinted, uint256 collateralValueInUsd)
    {
        (totalBscMinted, collateralValueInUsd) = _getAccountInformation(user);
    }

    function getTotalAccountCollateralValueInUsd(address user)
        public
        view
        returns (uint256 totalCollateralValueInUsd)
    {
        // loop through the collateral addresses and get total collateral value in usd
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i]; //address of the token we're working with
            uint256 amountCollateral = s_collateralDeposited[user][token];
            totalCollateralValueInUsd += getUsdValue(token, amountCollateral);
        }
        return totalCollateralValueInUsd;
    }

    //Coverting token amount into it's usd value while handling different decimal formats used by ERC20 token formats & Chainlink Pricefeeds
    function getUsdValue(address token, uint256 amount) public view isAllowedToken(token) returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.stalePriceCheckLatestRoundData();
        uint256 tokenDecimals = IERC20Metadata(token).decimals();
        //(amount * price) scaled by 10^18(FEE_PRECISION compensates for oracle's 8 decimals) / (10^tokenDecimals * 10^8)-removes token's own decimal scaling
        return amount * uint256(price) * FEE_PRECISION / (10 ** tokenDecimals);
    }

    function getCollateralAmountFromUsd(address token, uint256 amountBSC)
        public
        view
        isAllowedToken(token)
        returns (uint256)
    {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.stalePriceCheckLatestRoundData();
        uint256 tokenDecimals = IERC20Metadata(token).decimals();
        // Inverse: amountBSC(18 decimals USD) * 10^tokendecimals / uint256(price) * FEE_PRECISION
        return amountBSC * (10 ** tokenDecimals) / (uint256(price) * FEE_PRECISION);
    }

    function getCollateralBalanceOfUser(address token, address user) external view returns (uint256) {
        return s_collateralDeposited[user][token];
    }

    function getCollateralTokens() external view returns (address[] memory) {
        return s_collateralTokens;
    }

    function getBSCAddress() external view returns (address) {
        return address(i_bsc);
    }

    function getCollateralTokenPriceFeed(address token) external view returns (address) {
        return s_priceFeeds[token];
    }

    function getTotalBadDebt() external view returns (uint256) {
        return s_totalBadDebt;
    }

    function getTotalUserCollateral(address token) external view returns (uint256) {
        return s_totalCollateralDeposited[token];
    }

    function getReserveBalance(address token) external view returns (uint256) {
        return s_reserve[token];
    }
}

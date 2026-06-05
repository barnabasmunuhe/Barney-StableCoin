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
// // external
// // public
// // internal
// // private
// // internal & private view & pure functions
// // external & public view & pure functions

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BarneyStableCoin} from "./BarneyStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
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
    error DSCEngine__health_Factor_Not_Improved();

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

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/
    uint256 private constant FEE_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18; // precision for price feeds and calculations
    uint256 private constant LIQUIDATION_THRESHOLD = 50; //200% overcollateralization means 50% liquidation threshold
    uint256 private constant LIQUIDATION_PRECISION = 100; // precision for liquidation threshold calculations
    uint256 private constant LIQUIDATION_BONUS = 10; // This is 10% bonus for liquidators
    uint256 private constant MIN_HEALTH_FACTOR = 1e18; // health factor must be above 1

    mapping(address token => address priceFeed) private s_priceFeeds; // tokenToPriceFeed mapping
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited; // userCollateralBalance mapping
    mapping(address user => uint256 amountBscMinted) private s_bscMinted;
    address[] private s_collateralTokens; // array to keep track of the collateral tokens used in the system

    BarneyStableCoin private immutable i_bsc;

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
    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddresses, address bscAddress) {
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert CoinEngine__Token_Addresses_And_PriceFeeds_Length_Mismatch();
        }

        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i]; //setting the tokenAddress of i = priceFeedAddress of i
            s_collateralTokens.push(tokenAddresses[i]); //pushing the tokenAddress of i to the collateralTokens array
        }

        i_bsc = BarneyStableCoin(bscAddress);
    }

    /*//////////////////////////////////////////////////////////////
                               EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    /// @dev  This function allows users to deposit collateral and mint DSC in a single transaction.
    function depositCollateralAndMintBSC(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountToMint)
        external
    {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintBSC(amountToMint);
    }

    // @notice Follows the Checks-Effects-Interactions pattern
    // @param tokenCollateralAddress The address of the collateral token (e.g. wETH or wBTC)
    // @param amountCollateral The amount of collateral to deposit
    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral; //update the user's collateral balance(updating the state)
        //transfer the collateral from the user to the contract (interacting with an external contract)
        IERC20(tokenCollateralAddress).safeTransferFrom(msg.sender, address(this), amountCollateral);
        // safeTransferFrom will revert if the transfer fails, so we don't need to check for a failed transfer here.
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);
    }

    // @param tokenCollateralAddress The address of the token to redeem as collateral
    // @param amountCollateral The amount of collateral to redeem
    // @param amountBSCToBurn The amount of BSC to burn
    // @notice This function burns & redeems collateral in a single transaction
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
    {
        _redeemCollateral(msg.sender, msg.sender, tokenCollateralAddress, amountCollateral);
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

    function burnBSC(uint256 amountToBurn) public moreThanZero(amountToBurn) {
        _burnBSC(msg.sender, msg.sender, amountToBurn);
        //burning DSC won't break the health factor because we're removing the user's debt from the system but we will include a check just to be safe.
        _revertIfHealthFactorIsBroken(msg.sender); //SKEPTICAL IF THIS HITS!
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
     * follows CEI
     */
    function liquidate(address collateral, address user, uint256 debtToCover) external moreThanZero(debtToCover) {
        uint256 userStartingHealthFactor = _healthFactor(user);
        if (userStartingHealthFactor >= MIN_HEALTH_FACTOR) {
            revert CoinEngine__Health_Factor_Is_OK();
        }
        // We need to get the ETH value of the debtToCover
        uint256 collateralAmountFromDebtCovered = getCollateralAmountFromUsd(collateral, debtToCover);
        // Incetivising users by 10% of the debt to be covered
        // liqudator receives $110 of  wETH for 100 DSC
        // We should implement a feature to liquidate in the event the protocol is insolvent
        // Add sweep extra amounts into a treasury

        uint256 liquidationBonus = collateralAmountFromDebtCovered * LIQUIDATION_BONUS / LIQUIDATION_PRECISION;
        uint256 totalCollateralToEarn = collateralAmountFromDebtCovered + liquidationBonus;
        // Burn user's BSC
        _burnBSC(user, msg.sender, debtToCover);
        // check health_factor
        _redeemCollateral(user, msg.sender, collateral, totalCollateralToEarn);
        uint256 endingHealthFactor = _healthFactor(user);
        if (endingHealthFactor <= userStartingHealthFactor) {
            revert DSCEngine__health_Factor_Not_Improved();
        }
        // checking if the liquidator's health factor aint broken in the process of liquidation
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function getHealthFactor(address user) external view returns (uint256) {
        return _healthFactor(user);
    }

    /*//////////////////////////////////////////////////////////////
                  PRIVATE AND INTERNAL VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    /**
     * @dev CAVEAT: low-level internal function here! Do not call unless function calling it
     * is checking for health factor state
     */
    function _burnBSC(address onBehalfOf, address bscFrom, uint256 amountBscToBurn) private {
        s_bscMinted[onBehalfOf] -= amountBscToBurn; // removing their stableCoin debt from the system
        IERC20(address(i_bsc)).safeTransferFrom(bscFrom, address(this), amountBscToBurn); // transfer the BSC from the user to the smart contract
        i_bsc.burn(amountBscToBurn);
    }

    function _redeemCollateral(address from, address to, address tokenCollateralAddress, uint256 amountCollateral)
        private
    {
        s_collateralDeposited[from][tokenCollateralAddress] -= amountCollateral; //(Internal Accounting) pulling their debt out of the system
        emit CollateralRedeemed(from, to, tokenCollateralAddress, amountCollateral);
        IERC20(address(tokenCollateralAddress)).safeTransfer(to, amountCollateral); //transfer the token from the smart contract to the user
    }

    function _getAccountInformation(address user)
        private
        view
        returns (uint256 totalBscMinted, uint256 collateralValueInUsd)
    {
        totalBscMinted = s_bscMinted[user];
        collateralValueInUsd = getAccountCollateralValueInUsd(user);
    }

    /**
     * @notice Returns the health factor of a user, which is a measure of how close they are to being undercollateralized/liquidation.
     *  A health factor above 1 means the user is safe, while a health factor below 1 means the user is at risk of liquidation.
     * @param user The address of the user to calculate the health factor for
     */
    function _healthFactor(address user) private view returns (uint256) {
        //total BSC tokens minted
        // collateral value in usd
        (uint256 totalBscMinted, uint256 collateralValue) = _getAccountInformation(user);

        if (totalBscMinted == 0) {
            return type(uint256).max; //the function will immediately exit by preventing "division by zero error"
        }
        // $100  * 50 = 5000 / 100 = 50
        uint256 collateralAdjustedForThreshold = collateralValue * LIQUIDATION_THRESHOLD / LIQUIDATION_PRECISION;
        // $1000 ETH  100 BSCtoMint
        // $1000(collateralValue) * 50(liquidation_threshold) = 50000 / 100(liquidation_precision) = 500 / 100(BSCMinted) = 5 health factor > 1 means safe, < 1 means at risk of liquidation
        return (collateralAdjustedForThreshold * PRECISION) / totalBscMinted; // return health factor with precision
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
                     PUBLIC AND EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    function getAccountCollateralValueInUsd(address user) public view returns (uint256 totalCollateralValueInUsd) {
        // loop through the collateral addresses and get total collateral value in usd
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i]; //address of the token we're working with
            uint256 amountCollateral = s_collateralDeposited[user][token];
            totalCollateralValueInUsd += getUsdValue(token, amountCollateral);
        }
        return totalCollateralValueInUsd;
    }

    function getCollateralAmountFromUsd(address token, uint256 amountBSC) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.stalePriceCheckLatestRoundData();
        // price 2000e8 converting 10e18(bscTokensIn$) to ETH
        return (amountBSC * PRECISION) / (uint256(price) * FEE_PRECISION);
    }

    function getUsdValue(address token, uint256 amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.stalePriceCheckLatestRoundData();
        // 1 ETH = $1000
        // returned value = 1000 * 1e8 CAVEAT: Add precision to match decimal places
        return (uint256(price) * FEE_PRECISION) * amount / PRECISION;
    }

    function getAccountInformation(address user)
        external
        view
        returns (uint256 totalBscMinted, uint256 collateralValueInUsd)
    {
        (totalBscMinted, collateralValueInUsd) = _getAccountInformation(user);
    }

    /*//////////////////////////////////////////////////////////////
                            GETTER FUNCTIONS
    //////////////////////////////////////////////////////////////*/
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
}

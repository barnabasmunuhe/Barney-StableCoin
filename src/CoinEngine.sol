// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BarneyStableCoin} from "./BarneyStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
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
    event BadDebtAbsorbed(address indexed collateral, uint256 amountInCollateral);
    event ReserveAccrued(address indexed token, uint256 fee);

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/
    uint256 private constant FEE_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50;
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant LIQUIDATION_BONUS = 10;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;

    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant REDEEM_FEE_BPS = 10; // 0.10%

    BarneyStableCoin private immutable i_bsc;
    address public immutable i_badDebtSink; // treasury that receives absorbed collateral

    mapping(address token => address priceFeed) private s_priceFeeds;
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
    mapping(address token => uint256 total) private s_totalCollateralDeposited;
    mapping(address user => uint256 amountBscMinted) private s_bscMinted;
    mapping(address token => uint256 amount) private s_reserve;
    mapping(address user => uint256 amount) private s_recognizedBadDebt;
    address[] private s_collateralTokens;
    uint256 private s_totalBadDebt;

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/
    modifier moreThanZero(uint256 amount) {
        if (amount <= 0) revert CoinEngine__Must_Be_More_Than_Zero();
        _;
    }

    modifier isAllowedToken(address token) {
        if (s_priceFeeds[token] == address(0)) revert CoinEngine__Not_Allowed_Token();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/
    /// @dev Feeds are NOT validated at construction. A broken feed is caught on first
    ///      use via the OracleLib staleness + positivity checks.
    /// @param badDebtSink The address that receives collateral when the reserve absorbs
    ///        bad debt. Use a treasury/multisig in production. The engine transfers
    ///        absorbed collateral there, so `physical == user + reserve` stays intact.
    constructor(
        address[] memory tokenCollateralAddresses,
        address[] memory priceFeedAddresses,
        address bscAddress,
        address badDebtSink
    ) {
        if (tokenCollateralAddresses.length != priceFeedAddresses.length) {
            revert CoinEngine__Token_Addresses_And_PriceFeeds_Length_Mismatch();
        }
        if (tokenCollateralAddresses.length == 0) revert CoinEngine__No_CollateralTokens();
        if (bscAddress == address(0) || badDebtSink == address(0)) revert CoinEngine__Zero_Address();

        for (uint256 i = 0; i < tokenCollateralAddresses.length; i++) {
            if (tokenCollateralAddresses[i] == address(0)) revert CoinEngine__Zero_Address();
            if (priceFeedAddresses[i] == address(0)) revert CoinEngine__Zero_Address();

            for (uint256 j = 0; j < i; j++) {
                if (tokenCollateralAddresses[j] == tokenCollateralAddresses[i]) {
                    revert CoinEngine__DuplicateCollateralToken();
                }
            }
            s_priceFeeds[tokenCollateralAddresses[i]] = priceFeedAddresses[i];
            s_collateralTokens.push(tokenCollateralAddresses[i]);
        }

        i_bsc = BarneyStableCoin(bscAddress);
        i_badDebtSink = badDebtSink;
    }

    /*//////////////////////////////////////////////////////////////
                      PUBLIC & EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    /// @dev Deliberately not nonReentrant — inner calls guard individually.
    function depositCollateralAndMintBSC(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountToMint)
        external
    {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintBSC(amountToMint);
    }

    /// @notice Follows Checks-Effects-Interactions.
    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        s_totalCollateralDeposited[tokenCollateralAddress] += amountCollateral;
        IERC20(tokenCollateralAddress).safeTransferFrom(msg.sender, address(this), amountCollateral);
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);
    }

    /// @dev Deliberately not nonReentrant — inner calls guard individually.
    function redeemBSCForCollateral(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountBSCToBurn)
        external
    {
        burnBSC(amountBSCToBurn);
        redeemCollateral(tokenCollateralAddress, amountCollateral);
    }

    /// @notice Redeem collateral. Charged REDEEM_FEE_BPS on the redeemed amount.
    ///         Fee accrues to s_reserve and can later absorb bad debt.
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

        s_collateralDeposited[msg.sender][tokenCollateralAddress] -= amountCollateral;
        s_totalCollateralDeposited[tokenCollateralAddress] -= amountCollateral;
        if (fee > 0) {
            s_reserve[tokenCollateralAddress] += fee;
            emit ReserveAccrued(tokenCollateralAddress, fee);
        }

        IERC20(tokenCollateralAddress).safeTransfer(msg.sender, userReceives);
        emit CollateralRedeemed(msg.sender, msg.sender, tokenCollateralAddress, userReceives);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function mintBSC(uint256 amountToMint) public moreThanZero(amountToMint) nonReentrant {
        s_bscMinted[msg.sender] += amountToMint;
        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_bsc.mint(msg.sender, amountToMint);
        if (!minted) revert CoinEngine__Mint_Failed();
    }

    function burnBSC(uint256 amountToBurn) public nonReentrant moreThanZero(amountToBurn) {
        _burnBSC(msg.sender, msg.sender, amountToBurn);
    }

    /**
     * @param collateral The erc20 collateral address to liquidate from the user
     * @param user The user whose health factor is broken (below MIN_HEALTH_FACTOR)
     * @param debtToCover The amount of BSC you want to burn to improve the user's health factor
     * @notice You can partially liquidate a user
     * @notice You will get a 10% liquidation bonus for taking the user's collateral
     * @dev Bad debt is only recognized when ALL collateral is exhausted. Partial-coverage
     *      positions remain liquidatable and become bad debt only once fully drained.
     * @dev The reserve absorbs bad debt as a first-loss layer. If it's insufficient, the
     *      remainder is recorded in s_totalBadDebt and remains visible on-chain until
     *      Layer 3 (barney-guardian) resolves it.
     * @dev HF-improvement is only enforced above the 0.55 threshold. Below 0.55, the 10%
     *      bonus mathematically worsens HF on every liquidation, so demanding improvement
     *      would make the position permanently unliquidatable.
     */
    function liquidate(address collateral, address user, uint256 debtToCover)
        external
        nonReentrant
        moreThanZero(debtToCover)
    {
        uint256 userStartingHealthFactor = _healthFactor(user);
        if (userStartingHealthFactor >= MIN_HEALTH_FACTOR) revert CoinEngine__Health_Factor_Is_OK();

        uint256 userCollateralBalance = s_collateralDeposited[user][collateral];
        if (userCollateralBalance == 0) revert CoinEngine__InsufficientCollateral();

        uint256 userDebt = s_bscMinted[user];
        if (debtToCover > userDebt) debtToCover = userDebt;

        uint256 collateralAmountFromDebtCovered = getCollateralAmountFromUsd(collateral, debtToCover);
        uint256 liquidationBonus = collateralAmountFromDebtCovered * LIQUIDATION_BONUS / LIQUIDATION_PRECISION;
        uint256 totalCollateralToEarn = collateralAmountFromDebtCovered + liquidationBonus;

        if (totalCollateralToEarn > userCollateralBalance) {
            totalCollateralToEarn = userCollateralBalance;
            uint256 cappedCollateralForDebt =
                userCollateralBalance * LIQUIDATION_PRECISION / (LIQUIDATION_PRECISION + LIQUIDATION_BONUS);
            debtToCover = getUsdValue(collateral, cappedCollateralForDebt);
        }

        _burnBSC(user, msg.sender, debtToCover);
        _redeemCollateral(user, msg.sender, collateral, totalCollateralToEarn);

        uint256 endingHealthFactor = _healthFactor(user);
        if (userStartingHealthFactor >= (MIN_HEALTH_FACTOR * 55) / 100) {
            if (endingHealthFactor <= userStartingHealthFactor) {
                revert CoinEngine__health_Factor_Not_Improved();
            }
        }

        // Bad debt: deduplicated per user, absorbed by reserve first.
        uint256 remainingDebt = s_bscMinted[user];
        if (remainingDebt > 0 && getTotalAccountCollateralValueInUsd(user) == 0) {
            uint256 newBadDebt = remainingDebt - s_recognizedBadDebt[user];

            if (newBadDebt > 0) {
                s_recognizedBadDebt[user] = remainingDebt;
                s_totalBadDebt += newBadDebt;
                emit BadDebtRecognized(user, newBadDebt);
            }
        }

        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function getHealthFactor(address user) external view returns (uint256) {
        return _healthFactor(user);
    }

    /*//////////////////////////////////////////////////////////////
                  PRIVATE AND INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    function _redeemCollateral(address from, address to, address tokenCollateralAddress, uint256 amountCollateral)
        private
    {
        s_collateralDeposited[from][tokenCollateralAddress] -= amountCollateral;
        s_totalCollateralDeposited[tokenCollateralAddress] -= amountCollateral;
        emit CollateralRedeemed(from, to, tokenCollateralAddress, amountCollateral);
        IERC20(tokenCollateralAddress).safeTransfer(to, amountCollateral);
    }

    /// @dev Tries to cover `badDebtUsd` from the reserve for `collateral`.
    ///      Returns the portion that could NOT be covered (in USD).
    ///      Transfers absorbed collateral to i_badDebtSink so the accounting
    ///      invariant (physical == user + reserve) remains intact.
    function _absorbBadDebtFromReserve(address collateral, uint256 badDebtUsd) private returns (uint256 uncoveredUsd) {
        uint256 badDebtInCollateral = getCollateralAmountFromUsd(collateral, badDebtUsd);
        uint256 reserveAvailable = s_reserve[collateral];

        if (reserveAvailable >= badDebtInCollateral) {
            s_reserve[collateral] = reserveAvailable - badDebtInCollateral;
            IERC20(collateral).safeTransfer(i_badDebtSink, badDebtInCollateral);
            emit BadDebtAbsorbed(collateral, badDebtInCollateral);
            return 0;
        }

        if (reserveAvailable > 0) {
            s_reserve[collateral] = 0;
            IERC20(collateral).safeTransfer(i_badDebtSink, reserveAvailable);
            emit BadDebtAbsorbed(collateral, reserveAvailable);
        }
        uint256 absorbedUsd = getUsdValue(collateral, reserveAvailable);
        uncoveredUsd = badDebtUsd - absorbedUsd;
    }

    /// @dev CAVEAT: does not check health factor. Caller must verify.
    function _burnBSC(address onBehalfOf, address bscFrom, uint256 amountBscToBurn) private {
        s_bscMinted[onBehalfOf] -= amountBscToBurn;

        // Repay recognized bad debt first.
        uint256 recognizedDebt = s_recognizedBadDebt[onBehalfOf];
        uint256 badDebtReduction = amountBscToBurn < recognizedDebt ? amountBscToBurn : recognizedDebt;

        if (badDebtReduction > 0) {
            s_recognizedBadDebt[onBehalfOf] -= badDebtReduction;
            s_totalBadDebt -= badDebtReduction;
        }

        IERC20(address(i_bsc)).safeTransferFrom(bscFrom, address(this), amountBscToBurn);
        i_bsc.burn(amountBscToBurn);
    }

    function _getAccountInformation(address user)
        private
        view
        returns (uint256 totalBscMinted, uint256 collateralValueInUsd)
    {
        totalBscMinted = s_bscMinted[user];
        collateralValueInUsd = getTotalAccountCollateralValueInUsd(user);
    }

    function _healthFactor(address user) private view returns (uint256) {
        (uint256 totalBscMinted, uint256 totalCollateralValueInUsd) = _getAccountInformation(user);
        if (totalBscMinted == 0) return type(uint256).max;
        uint256 adjusted = totalCollateralValueInUsd * LIQUIDATION_THRESHOLD / LIQUIDATION_PRECISION;
        return (adjusted * PRECISION) / totalBscMinted;
    }

    function _revertIfHealthFactorIsBroken(address user) internal view {
        uint256 hf = _healthFactor(user);
        if (hf < MIN_HEALTH_FACTOR) revert CoinEngine__Health_Factor_Below_Minimum(hf);
    }

    /*//////////////////////////////////////////////////////////////
                    EXTERNAL & PUBLIC VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    function getAccountInformation(address user)
        external
        view
        returns (uint256 totalBscMinted, uint256 collateralValueInUsd)
    {
        (totalBscMinted, collateralValueInUsd) = _getAccountInformation(user);
    }

    function getTotalAccountCollateralValueInUsd(address user) public view returns (uint256 totalCollateralValueInUsd) {
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            totalCollateralValueInUsd += getUsdValue(token, s_collateralDeposited[user][token]);
        }
    }

    function getUsdValue(address token, uint256 amount) public view isAllowedToken(token) returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.stalePriceCheckLatestRoundData();
        uint256 tokenDecimals = IERC20Metadata(token).decimals();
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

    function getBadDebtSink() external view returns (address) {
        return i_badDebtSink;
    }

    function getCollateralTokenPriceFeed(address token) external view returns (address) {
        return s_priceFeeds[token];
    }

    function getTotalBadDebt() external view returns (uint256) {
        return s_totalBadDebt;
    }

    function getRecognizedBadDebt(address user) external view returns (uint256) {
        return s_recognizedBadDebt[user];
    }

    function getTotalUserCollateral(address token) external view returns (uint256) {
        return s_totalCollateralDeposited[token];
    }

    function getReserveBalance(address token) external view returns (uint256) {
        return s_reserve[token];
    }
}

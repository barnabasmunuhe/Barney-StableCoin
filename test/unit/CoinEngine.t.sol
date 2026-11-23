// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {DeployBSC} from "../../script/DeployBSC.s.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {BarneyStableCoin} from "../../src/BarneyStableCoin.sol";
import {CoinEngine} from "../../src/CoinEngine.sol";
import {ERC20, ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {MockV3Aggregator} from "@chainlink/contracts/src/v0.8/tests/MockV3Aggregator.sol";
import {ERC20MockEightDec} from "test/mocks/ERC20MockEightDec.sol";

contract CoinEngineTest is Test {
    DeployBSC deployer;
    HelperConfig helperConfig;
    BarneyStableCoin bsc;
    CoinEngine engine;

    address ethUsdPriceFeed;
    address btcUsdPriceFeed;
    address wEth;
    address wBtc;
    address treasury;

    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    address public USER = makeAddr("user");
    uint256 public constant AMOUNT_COLLATERAL = 10 ether;
    uint256 public constant ERC20_USER_BALANCE = 10 ether;
    uint256 public constant AMOUNT_TO_MINT = 100 ether;

    uint256 private _badUserCounter;

    function setUp() external {
        deployer = new DeployBSC();
        (bsc, engine, helperConfig) = deployer.run();
        HelperConfig.NetworkConfig memory config = helperConfig.getActiveNetworkConfig();

        ethUsdPriceFeed = config.wEthUsdPriceFeed;
        btcUsdPriceFeed = config.wBtcUsdPriceFeed;
        wEth = config.wEth;
        wBtc = config.wBtc;
        treasury = makeAddr("treasury");

        ERC20Mock(wEth).mint(USER, ERC20_USER_BALANCE);
    }

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/
    modifier collateralDeposited() {
        vm.startPrank(USER);
        ERC20Mock(wEth).approve(address(engine), AMOUNT_COLLATERAL);
        engine.depositCollateral(wEth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

    modifier mintedBSC() {
        vm.startPrank(USER);
        ERC20Mock(wEth).approve(address(engine), AMOUNT_COLLATERAL);
        engine.depositCollateral(wEth, AMOUNT_COLLATERAL);
        engine.mintBSC(100 ether);
        vm.stopPrank();
        _;
    }

    modifier depositedAndMinted() {
        vm.startPrank(USER);
        ERC20Mock(wEth).approve(address(engine), AMOUNT_COLLATERAL);
        engine.depositCollateral(wEth, AMOUNT_COLLATERAL);
        engine.mintBSC(AMOUNT_TO_MINT);
        vm.stopPrank();
        _;
    }

    modifier mintedNearThreshold() {
        vm.startPrank(USER);
        ERC20Mock(wEth).approve(address(engine), AMOUNT_COLLATERAL);
        engine.depositCollateral(wEth, AMOUNT_COLLATERAL);
        engine.mintBSC(10000 ether);
        vm.stopPrank();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                       BATCH 1 — CONSTRUCTOR TESTS
    //////////////////////////////////////////////////////////////*/
    function test_Reverts_If_Token_Length_Does_Not_Match_PriceFeeds() public {
        tokenAddresses.push(wEth);
        priceFeedAddresses.push(ethUsdPriceFeed);
        priceFeedAddresses.push(btcUsdPriceFeed);

        vm.expectRevert(CoinEngine.CoinEngine__Token_Addresses_And_PriceFeeds_Length_Mismatch.selector);
        new CoinEngine(tokenAddresses, priceFeedAddresses, address(bsc), treasury);
    }

    function test_constructorRevertsOnEmptyCollateral() public {
        address[] memory empty = new address[](0);
        vm.expectRevert(CoinEngine.CoinEngine__No_CollateralTokens.selector);
        new CoinEngine(empty, empty, address(bsc), address(0xdead));
    }

    function test_constructorRevertsOnZeroBSC() public {
        address[] memory tokens = new address[](1);
        tokens[0] = wEth;
        address[] memory feeds = new address[](1);
        feeds[0] = ethUsdPriceFeed;
        vm.expectRevert(CoinEngine.CoinEngine__Zero_Address.selector);
        new CoinEngine(tokens, feeds, address(0), address(0xdead));
    }

    function test_constructorRevertsOnZeroCollateral() public {
        address[] memory tokens = new address[](1);
        tokens[0] = address(0);
        address[] memory feeds = new address[](1);
        feeds[0] = ethUsdPriceFeed;
        vm.expectRevert(CoinEngine.CoinEngine__Zero_Address.selector);
        new CoinEngine(tokens, feeds, address(bsc), address(0xdead));
    }

    function test_constructorRevertsOnZeroPriceFeed() public {
        address[] memory tokens = new address[](1);
        tokens[0] = wEth;
        address[] memory feeds = new address[](1);
        feeds[0] = address(0);
        vm.expectRevert(CoinEngine.CoinEngine__Zero_Address.selector);
        new CoinEngine(tokens, feeds, address(bsc), address(0xdead));
    }

    function test_constructorRevertsOnZeroBadDebtSink() public {
        address[] memory tokens = new address[](1);
        tokens[0] = wEth;
        address[] memory feeds = new address[](1);
        feeds[0] = ethUsdPriceFeed;
        vm.expectRevert(CoinEngine.CoinEngine__Zero_Address.selector);
        new CoinEngine(tokens, feeds, address(bsc), address(0));
    }

    function test_deployment_engineOwnsBsc() public view {
        assertEq(bsc.owner(), address(engine));
    }

    /*//////////////////////////////////////////////////////////////
                       PRICE FEED TESTS
    //////////////////////////////////////////////////////////////*/
    function testGetUsdValue() public view {
        assertEq(engine.getUsdValue(wEth, 15e18), 30000e18);
    }

    function testGetCollateralAmountInUsd() public view {
        assertEq(engine.getCollateralAmountFromUsd(wEth, 100 ether), 0.05 ether);
    }

    function test_usdValueRespectsTokenDecimals() public {
        ERC20MockEightDec wBtc8 = new ERC20MockEightDec();
        MockV3Aggregator feed = new MockV3Aggregator(8, 40000e8);

        address[] memory tokens = new address[](1);
        tokens[0] = address(wBtc8);
        address[] memory feeds = new address[](1);
        feeds[0] = address(feed);

        CoinEngine freshEngine = new CoinEngine(tokens, feeds, address(bsc), address(0xdead));
        assertEq(freshEngine.getUsdValue(address(wBtc8), 1e8), 40000e18);
    }

    /*//////////////////////////////////////////////////////////////
                       BATCH 2 — DEPOSIT EDGE CASES
    //////////////////////////////////////////////////////////////*/
    function testRevertIfDepositZeroV1() external {
        vm.startPrank(USER);
        ERC20Mock(wEth).approve(address(engine), AMOUNT_COLLATERAL);
        vm.expectRevert(CoinEngine.CoinEngine__Must_Be_More_Than_Zero.selector);
        engine.depositCollateral(wEth, 0);
        vm.stopPrank();
    }

    function testRevertIfDepositZero() external {
        vm.prank(USER);
        vm.expectRevert(CoinEngine.CoinEngine__Must_Be_More_Than_Zero.selector);
        engine.depositCollateral(wEth, 0);
    }

    function testRevertsWithUnapprovedCollateral() public {
        ERC20Mock damnToken = new ERC20Mock();
        vm.startPrank(USER);
        vm.expectRevert(CoinEngine.CoinEngine__Not_Allowed_Token.selector);
        engine.depositCollateral(address(damnToken), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    function test_depositIncrementsBothLedgers() public {
        uint256 totalBefore = engine.getTotalUserCollateral(wEth);
        vm.startPrank(USER);
        ERC20Mock(wEth).approve(address(engine), 1e18);
        engine.depositCollateral(wEth, 1e18);
        vm.stopPrank();
        assertEq(engine.getTotalUserCollateral(wEth), totalBefore + 1e18);
        assertEq(ERC20Mock(wEth).balanceOf(address(engine)), totalBefore + 1e18);
    }

    function test_depositRevertsWhenUserHasInsufficientBalance() public {
        address broke = makeAddr("broke");
        vm.startPrank(broke);
        ERC20Mock(wEth).approve(address(engine), 1e18);
        vm.expectRevert();
        engine.depositCollateral(wEth, 1e18);
        vm.stopPrank();
    }

    function test_depositAccumulatesAcrossCalls() public {
        vm.startPrank(USER);
        ERC20Mock(wEth).approve(address(engine), 2e18);
        engine.depositCollateral(wEth, 1e18);
        engine.depositCollateral(wEth, 1e18);
        vm.stopPrank();
        assertEq(engine.getCollateralBalanceOfUser(wEth, USER), 2e18);
    }

    function test_depositDifferentTokensTrackedSeparately() public {
        vm.startPrank(USER);
        ERC20Mock(wEth).approve(address(engine), 1e18);
        engine.depositCollateral(wEth, 1e18);
        vm.stopPrank();
        assertEq(engine.getCollateralBalanceOfUser(wEth, USER), 1e18);
        assertEq(engine.getCollateralBalanceOfUser(wBtc, USER), 0);
    }

    function test_depositEmitsCollateralDepositedWithCorrectArgs() public {
        vm.startPrank(USER);
        ERC20Mock(wEth).approve(address(engine), 1e18);
        vm.expectEmit(true, true, true, true, address(engine));
        emit CoinEngine.CollateralDeposited(USER, wEth, 1e18);
        engine.depositCollateral(wEth, 1e18);
        vm.stopPrank();
    }

    function testDepositCollateralAndGetAccountInfo() public collateralDeposited {
        (uint256 totalBscMinted, uint256 collateralValueInUsd) = engine.getAccountInformation(USER);
        assertEq(totalBscMinted, 0);
        assertEq(AMOUNT_COLLATERAL, engine.getCollateralAmountFromUsd(wEth, collateralValueInUsd));
    }

    function testDepositCollateralEmitsEvent() public {
        vm.startPrank(USER);
        ERC20Mock(wEth).approve(address(engine), AMOUNT_COLLATERAL);
        vm.expectEmit(true, true, true, false);
        emit CoinEngine.CollateralDeposited(USER, wEth, AMOUNT_COLLATERAL);
        engine.depositCollateral(wEth, AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    function testDepositCollateralUpdatesBalance() public collateralDeposited {
        assertEq(engine.getCollateralBalanceOfUser(wEth, USER), AMOUNT_COLLATERAL);
    }

    /*//////////////////////////////////////////////////////////////
                       BATCH 3 — REDEEM EDGE CASES
    //////////////////////////////////////////////////////////////*/
    function test_redeemRevertsOnInsufficientBalance() public collateralDeposited {
        vm.prank(USER);
        vm.expectRevert(CoinEngine.CoinEngine__InsufficientCollateral.selector);
        engine.redeemCollateral(wEth, AMOUNT_COLLATERAL + 1);
    }

    function test_redeemRevertsOnZeroAmount() public collateralDeposited {
        vm.prank(USER);
        vm.expectRevert(CoinEngine.CoinEngine__Must_Be_More_Than_Zero.selector);
        engine.redeemCollateral(wEth, 0);
    }

    function test_redeemDecrementsUserCollateralLedger() public collateralDeposited {
        vm.prank(USER);
        engine.redeemCollateral(wEth, 1e18);
        assertEq(engine.getCollateralBalanceOfUser(wEth, USER), AMOUNT_COLLATERAL - 1e18);
    }

    function test_redeemTransfersCorrectAmountAfterFee() public collateralDeposited {
        uint256 balanceBefore = ERC20Mock(wEth).balanceOf(USER);
        vm.prank(USER);
        engine.redeemCollateral(wEth, 10e18);
        uint256 received = ERC20Mock(wEth).balanceOf(USER) - balanceBefore;
        assertEq(received, 10e18 - 1e16);
    }

    function test_redeemEmitsCollateralRedeemedWithNetAmount() public collateralDeposited {
        uint256 netAmount = 10e18 - (10e18 * 10 / 10000);
        vm.prank(USER);
        vm.expectEmit(true, true, true, true, address(engine));
        emit CoinEngine.CollateralRedeemed(USER, USER, wEth, netAmount);
        engine.redeemCollateral(wEth, 10e18);
    }

    function test_redeemRevertsIfHealthFactorWouldBreak() public mintedNearThreshold {
        vm.prank(USER);
        vm.expectRevert();
        engine.redeemCollateral(wEth, AMOUNT_COLLATERAL);
    }

    function testRedeemRevertsIfHealthFactorBreaks() public mintedBSC {
        vm.startPrank(USER);
        vm.expectRevert();
        engine.redeemCollateral(wEth, AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    function testCanRedeemCollateral() public mintedBSC {
        vm.startPrank(USER);
        bsc.approve(address(engine), 100 ether);
        engine.burnBSC(100 ether);
        engine.redeemCollateral(wEth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        assertEq(engine.getCollateralBalanceOfUser(wEth, USER), 0);
    }

    /*//////////////////////////////////////////////////////////////
                       MINT / BURN EDGE CASES
    //////////////////////////////////////////////////////////////*/
    function testRevertsIfMintAmountIsZero() public {
        vm.prank(USER);
        vm.expectRevert(CoinEngine.CoinEngine__Must_Be_More_Than_Zero.selector);
        engine.mintBSC(0);
    }

    function testRevertsIfMintBreaksHealthFactor() public collateralDeposited {
        vm.startPrank(USER);
        vm.expectRevert();
        engine.mintBSC(20000 ether);
        vm.stopPrank();
    }

    function testMintBSCUpdatesMintedAmount() public collateralDeposited {
        vm.prank(USER);
        engine.mintBSC(100 ether);
        (uint256 totalMinted,) = engine.getAccountInformation(USER);
        assertEq(totalMinted, 100 ether);
    }

    function testMintBSCTransfersTokensToUser() public collateralDeposited {
        vm.prank(USER);
        engine.mintBSC(100 ether);
        assertEq(bsc.balanceOf(USER), 100 ether);
    }

    function test_mintAccumulatesAcrossCalls() public collateralDeposited {
        vm.startPrank(USER);
        engine.mintBSC(50e18);
        engine.mintBSC(50e18);
        vm.stopPrank();
        (uint256 totalMinted,) = engine.getAccountInformation(USER);
        assertEq(totalMinted, 100e18);
    }

    function test_mintUpdatesMintedAmountByExactValue() public collateralDeposited {
        vm.prank(USER);
        engine.mintBSC(123e18);
        (uint256 totalMinted,) = engine.getAccountInformation(USER);
        assertEq(totalMinted, 123e18);
    }

    function test_mintIncreasesBSCSupply() public collateralDeposited {
        uint256 supplyBefore = bsc.totalSupply();
        vm.prank(USER);
        engine.mintBSC(30e18);
        assertEq(bsc.totalSupply(), supplyBefore + 30e18);
    }

    function testRevertsIfBurnAmountIsZero() public {
        vm.prank(USER);
        vm.expectRevert(CoinEngine.CoinEngine__Must_Be_More_Than_Zero.selector);
        engine.burnBSC(0);
    }

    function testBurnBSCDecreasesMintedAmount() public mintedBSC {
        vm.startPrank(USER);
        bsc.approve(address(engine), 100 ether);
        engine.burnBSC(100 ether);
        vm.stopPrank();
        (uint256 totalMinted,) = engine.getAccountInformation(USER);
        assertEq(totalMinted, 0);
    }

    function test_burnReducesDebt() public mintedBSC {
        vm.startPrank(USER);
        bsc.approve(address(engine), 50e18);
        engine.burnBSC(50e18);
        vm.stopPrank();
        (uint256 remaining,) = engine.getAccountInformation(USER);
        assertEq(remaining, 50e18);
    }

    function test_burnRevertsIfUserLacksBSC() public collateralDeposited {
        vm.prank(USER);
        vm.expectRevert();
        engine.burnBSC(1e18);
    }

    function test_burnReducesBSCSupply() public mintedBSC {
        uint256 supplyBefore = bsc.totalSupply();
        vm.startPrank(USER);
        bsc.approve(address(engine), 30e18);
        engine.burnBSC(30e18);
        vm.stopPrank();
        assertEq(bsc.totalSupply(), supplyBefore - 30e18);
    }

    function test_underwaterBorrowerCanPartiallyRepay() public {
        address badUser = _createBadDebt(0.02e18, 10e18, 500e8);

        uint256 debtBefore = engine.getRecognizedBadDebt(badUser);
        uint256 repayment = 0.25e18;

        vm.startPrank(badUser);
        bsc.approve(address(engine), repayment);
        engine.burnBSC(repayment);
        vm.stopPrank();

        assertEq(engine.getRecognizedBadDebt(badUser), debtBefore - repayment);
        assertEq(engine.getTotalBadDebt(), debtBefore - repayment);
    }

    function test_fullRepaymentClearsRecognizedBadDebt() public {
        address badUser = _createBadDebt(0.02e18, 10e18, 500e8);

        uint256 remainingDebt = engine.getRecognizedBadDebt(badUser);

        vm.startPrank(badUser);
        bsc.approve(address(engine), remainingDebt);
        engine.burnBSC(remainingDebt);
        vm.stopPrank();

        assertEq(engine.getRecognizedBadDebt(badUser), 0);
        assertEq(engine.getTotalBadDebt(), 0);
    }

    /*//////////////////////////////////////////////////////////////
                  DEPOSIT COLLATERAL AND MINTBSC TESTS
    //////////////////////////////////////////////////////////////*/
    function testDepositAndMintWorksTogether() public {
        uint256 amountToMint = 100 ether;
        vm.startPrank(USER);
        ERC20Mock(wEth).approve(address(engine), AMOUNT_COLLATERAL);
        engine.depositCollateralAndMintBSC(wEth, AMOUNT_COLLATERAL, amountToMint);
        vm.stopPrank();
        (uint256 totalMinted,) = engine.getAccountInformation(USER);
        assertEq(totalMinted, amountToMint);
    }

    function testMustReedeemMoreThanZero() public mintedBSC {
        vm.startPrank(USER);
        bsc.approve(address(engine), 100 ether);
        vm.expectRevert(CoinEngine.CoinEngine__Must_Be_More_Than_Zero.selector);
        engine.redeemBSCForCollateral(wEth, AMOUNT_COLLATERAL, 0);
        vm.stopPrank();
    }

    function testRedeemBSCForCollateralWorks() public mintedBSC {
        vm.startPrank(USER);
        bsc.approve(address(engine), 100 ether);
        engine.redeemBSCForCollateral(wEth, AMOUNT_COLLATERAL, 100 ether);
        vm.stopPrank();
        (uint256 minted,) = engine.getAccountInformation(USER);
        assertEq(minted, 0);
    }

    /*//////////////////////////////////////////////////////////////
                       BATCH 5 — LIQUIDATION EDGE CASES
    //////////////////////////////////////////////////////////////*/
    function test_liquidateRevertsOnZeroDebtToCover() public {
        address user = makeAddr("user1");
        deal(wEth, user, 1e18);
        vm.startPrank(user);
        ERC20Mock(wEth).approve(address(engine), 1e18);
        engine.depositCollateral(wEth, 1e18);
        engine.mintBSC(500e18);
        vm.stopPrank();

        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(200e8);

        vm.prank(makeAddr("liquidator"));
        vm.expectRevert(CoinEngine.CoinEngine__Must_Be_More_Than_Zero.selector);
        engine.liquidate(wEth, user, 0);
    }

    function test_liquidateRevertsIfHealthFactorIsOK() public collateralDeposited {
        vm.prank(USER);
        engine.mintBSC(100e18);
        vm.prank(makeAddr("liquidator"));
        vm.expectRevert(CoinEngine.CoinEngine__Health_Factor_Is_OK.selector);
        engine.liquidate(wEth, USER, 50e18);
    }

    function test_liquidateRevertsIfNoCollateralForThatToken() public {
        address user = makeAddr("noCollateralForToken");
        deal(wBtc, user, 1e8);
        vm.startPrank(user);
        ERC20Mock(wBtc).approve(address(engine), 1e8);
        engine.depositCollateral(wBtc, 1e8);
        engine.mintBSC(10000e18);
        vm.stopPrank();

        MockV3Aggregator(btcUsdPriceFeed).updateAnswer(5000e8);

        vm.prank(makeAddr("liquidator"));
        vm.expectRevert(CoinEngine.CoinEngine__InsufficientCollateral.selector);
        engine.liquidate(wEth, user, 1000e18);
    }

    function test_liquidatePartialDebtSucceeds() public {
        address user = makeAddr("partial");
        deal(wEth, user, 1e18);
        vm.startPrank(user);
        ERC20Mock(wEth).approve(address(engine), 1e18);
        engine.depositCollateral(wEth, 1e18);
        engine.mintBSC(1000e18);
        vm.stopPrank();

        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(1500e8);

        address liquidator = makeAddr("liq");
        deal(address(bsc), liquidator, 500e18);
        vm.startPrank(liquidator);
        bsc.approve(address(engine), 500e18);
        engine.liquidate(wEth, user, 500e18);
        vm.stopPrank();

        (uint256 remainingDebt,) = engine.getAccountInformation(user);
        assertEq(remainingDebt, 500e18);
    }

    function test_liquidateBurnsLiquidatorBSC() public {
        address user = makeAddr("burnCheck");
        deal(wEth, user, 1e18);
        vm.startPrank(user);
        ERC20Mock(wEth).approve(address(engine), 1e18);
        engine.depositCollateral(wEth, 1e18);
        engine.mintBSC(1000e18);
        vm.stopPrank();

        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(500e8);

        address liquidator = makeAddr("liq");
        deal(address(bsc), liquidator, 2000e18);
        uint256 supplyBefore = bsc.totalSupply();

        vm.startPrank(liquidator);
        bsc.approve(address(engine), 2000e18);
        engine.liquidate(wEth, user, 1000e18);
        vm.stopPrank();

        assertLt(bsc.totalSupply(), supplyBefore);
    }

    function test_liquidateTransfersCollateralToLiquidator() public {
        address user = makeAddr("collTransfer");
        deal(wEth, user, 1e18);
        vm.startPrank(user);
        ERC20Mock(wEth).approve(address(engine), 1e18);
        engine.depositCollateral(wEth, 1e18);
        engine.mintBSC(1000e18);
        vm.stopPrank();

        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(500e8);

        address liquidator = makeAddr("liq");
        deal(address(bsc), liquidator, 2000e18);
        uint256 collBefore = ERC20Mock(wEth).balanceOf(liquidator);

        vm.startPrank(liquidator);
        bsc.approve(address(engine), 2000e18);
        engine.liquidate(wEth, user, 1000e18);
        vm.stopPrank();

        assertGt(ERC20Mock(wEth).balanceOf(liquidator), collBefore);
    }

    function test_liquidateRecordsBadDebtWhenReserveEmpty() public {
        address user = makeAddr("badDebt");
        deal(wEth, user, 1e18);
        vm.startPrank(user);
        ERC20Mock(wEth).approve(address(engine), 1e18);
        engine.depositCollateral(wEth, 1e18);
        engine.mintBSC(1000e18);
        vm.stopPrank();

        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(500e8);

        address liquidator = makeAddr("liq");
        deal(address(bsc), liquidator, 2000e18);
        vm.startPrank(liquidator);
        bsc.approve(address(engine), 2000e18);
        engine.liquidate(wEth, user, 1000e18);
        vm.stopPrank();

        assertGt(engine.getTotalBadDebt(), 0);
    }

    function test_liquidateBankruptPositionSeizesAllCollateral() public {
        address user = makeAddr("bankruptUser");
        uint256 depositAmount = 1e18;
        deal(wEth, user, depositAmount);

        vm.startPrank(user);
        ERC20(wEth).approve(address(engine), depositAmount);
        engine.depositCollateral(wEth, depositAmount);
        engine.mintBSC(1000e18);
        vm.stopPrank();

        MockV3Aggregator(engine.getCollateralTokenPriceFeed(wEth)).updateAnswer(800e8);

        address liquidator = makeAddr("liquidator");
        deal(address(bsc), liquidator, 1000e18);
        uint256 liquidatorWethBefore = ERC20(wEth).balanceOf(liquidator);

        vm.startPrank(liquidator);
        ERC20(bsc).approve(address(engine), 1000e18);
        engine.liquidate(wEth, user, 1000e18);
        vm.stopPrank();

        uint256 cappedCollateralForDebt = depositAmount * 100 / 110;
        uint256 expectedDebtBurned = engine.getUsdValue(wEth, cappedCollateralForDebt);
        uint256 expectedRemainingDebt = 1000e18 - expectedDebtBurned;

        uint256 liquidatorWethAfter = ERC20(wEth).balanceOf(liquidator);
        assertEq(engine.getCollateralBalanceOfUser(wEth, user), 0);
        assertEq(liquidatorWethAfter - liquidatorWethBefore, depositAmount);

        (uint256 userRemainingDebt, uint256 userCollateralUsd) = engine.getAccountInformation(user);
        assertEq(userRemainingDebt, expectedRemainingDebt);
        assertEq(engine.getTotalBadDebt(), expectedRemainingDebt);
        assertEq(userCollateralUsd, 0);
    }

    /*//////////////////////////////////////////////////////////////
                       BATCH 6 — HEALTH FACTOR MATH
    //////////////////////////////////////////////////////////////*/
    function testHealthFactorReturnsMaxIfNoMinted() public collateralDeposited {
        assertEq(engine.getHealthFactor(USER), type(uint256).max);
    }

    function testHealthFactorCanDecreaseBelowOne() public mintedNearThreshold {
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(500e8);
        assertLt(engine.getHealthFactor(USER), 1e18);
    }

    function test_hfEqualsOneAtThreshold() public {
        vm.startPrank(USER);
        ERC20Mock(wEth).approve(address(engine), 1e18);
        engine.depositCollateral(wEth, 1e18);
        engine.mintBSC(1000e18);
        vm.stopPrank();
        assertEq(engine.getHealthFactor(USER), 1e18);
    }

    function test_hfEqualsTwoAtSafePosition() public {
        vm.startPrank(USER);
        ERC20Mock(wEth).approve(address(engine), 1e18);
        engine.depositCollateral(wEth, 1e18);
        engine.mintBSC(500e18);
        vm.stopPrank();
        assertEq(engine.getHealthFactor(USER), 2e18);
    }

    function test_hfImprovesAfterBurn() public mintedBSC {
        uint256 hfBefore = engine.getHealthFactor(USER);
        vm.startPrank(USER);
        bsc.approve(address(engine), 50e18);
        engine.burnBSC(50e18);
        vm.stopPrank();
        assertGt(engine.getHealthFactor(USER), hfBefore);
    }

    function test_hfDegradesAfterMint() public collateralDeposited {
        uint256 hfBefore = engine.getHealthFactor(USER);
        vm.prank(USER);
        engine.mintBSC(100e18);
        assertLt(engine.getHealthFactor(USER), hfBefore);
    }

    /*//////////////////////////////////////////////////////////////
                       BATCH 7 — GETTERS
    //////////////////////////////////////////////////////////////*/
    function test_getCollateralTokensReturnsBoth() public view {
        address[] memory tokens = engine.getCollateralTokens();
        assertEq(tokens.length, 2);
        assertEq(tokens[0], wEth);
        assertEq(tokens[1], wBtc);
    }

    function test_getBSCAddressReturnsBSC() public view {
        assertEq(engine.getBSCAddress(), address(bsc));
    }

    function test_getBadDebtSinkReturnsNonZero() public view {
        assertTrue(engine.getBadDebtSink() != address(0));
    }

    function test_getRecognizedBadDebtStartsAtZero() public view {
        assertEq(engine.getRecognizedBadDebt(USER), 0);
    }

    function test_getTotalUserCollateralTracksDeposits() public {
        vm.startPrank(USER);
        ERC20Mock(wEth).approve(address(engine), 1e18);
        engine.depositCollateral(wEth, 1e18);
        vm.stopPrank();
        assertEq(engine.getTotalUserCollateral(wEth), 1e18);
    }

    /*//////////////////////////////////////////////////////////////
                       BATCH 8 — ORACLE INTEGRATION
    //////////////////////////////////////////////////////////////*/
    function test_mintRevertsOnStalePrice() public collateralDeposited {
        vm.warp(block.timestamp + 2 hours);
        vm.prank(USER);
        vm.expectRevert();
        engine.mintBSC(100e18);
    }

    function test_getUsdValueRevertsOnStalePrice() public {
        vm.warp(block.timestamp + 2 hours);
        vm.expectRevert();
        engine.getUsdValue(wEth, 1e18);
    }

    function test_getUsdValueRevertsOnZeroPrice() public {
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(0);
        vm.expectRevert();
        engine.getUsdValue(wEth, 1e18);
    }

    function test_getUsdValueRevertsOnNegativePrice() public {
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(-1);
        vm.expectRevert();
        engine.getUsdValue(wEth, 1e18);
    }

    function test_liquidateRevertsOnStalePrice() public {
        address user = makeAddr("staleUser");
        deal(wEth, user, 1e18);
        vm.startPrank(user);
        ERC20Mock(wEth).approve(address(engine), 1e18);
        engine.depositCollateral(wEth, 1e18);
        engine.mintBSC(1000e18);
        vm.stopPrank();

        vm.warp(block.timestamp + 2 hours);

        vm.prank(makeAddr("liquidator"));
        vm.expectRevert();
        engine.liquidate(wEth, user, 500e18);
    }

    /*//////////////////////////////////////////////////////////////
                       BATCH 9 — RESERVE ADDITIONAL
    //////////////////////////////////////////////////////////////*/
    function _createBadDebt(uint256 depositAmount, uint256 mintAmount, int256 newPrice)
        internal
        returns (address badUser)
    {
        badUser = makeAddr(string(abi.encodePacked("badUser", _badUserCounter)));
        _badUserCounter++;
        deal(wEth, badUser, depositAmount);

        vm.startPrank(badUser);
        ERC20Mock(wEth).approve(address(engine), depositAmount);
        engine.depositCollateral(wEth, depositAmount);
        engine.mintBSC(mintAmount);
        vm.stopPrank();

        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(newPrice);

        address liquidator = makeAddr("liquidator");
        deal(wEth, liquidator, 1e18);
        deal(address(bsc), liquidator, mintAmount * 2);
        vm.startPrank(liquidator);
        ERC20Mock(wEth).approve(address(engine), 1e18);
        engine.depositCollateral(wEth, 1e18);
        bsc.approve(address(engine), mintAmount * 2);
        engine.liquidate(wEth, badUser, mintAmount);
        vm.stopPrank();
    }

    function test_reserveRemainsAfterBadDebtRecognition() public mintedBSC {
        vm.prank(USER);
        engine.redeemCollateral(wEth, 5e18);

        uint256 reserveBefore = engine.getReserveBalance(wEth);
        uint256 treasuryBefore = ERC20Mock(wEth).balanceOf(engine.getBadDebtSink());

        address badUser = _createBadDebt(0.02e18, 10e18, 500e8);

        uint256 recognizedDebt = engine.getRecognizedBadDebt(badUser);

        assertGt(recognizedDebt, 0);
        assertEq(engine.getTotalBadDebt(), recognizedDebt);
        assertEq(engine.getReserveBalance(wEth), reserveBefore);
        assertEq(ERC20Mock(wEth).balanceOf(engine.getBadDebtSink()), treasuryBefore);
    }

    function test_reserveRemainsWhenBadDebtExceedsReserve() public mintedBSC {
        vm.prank(USER);
        engine.redeemCollateral(wEth, 0.05e18);

        uint256 reserveBefore = engine.getReserveBalance(wEth);

        address badUser = _createBadDebt(1e18, 1000e18, 500e8);

        assertGt(engine.getRecognizedBadDebt(badUser), 0);
        assertEq(engine.getTotalBadDebt(), engine.getRecognizedBadDebt(badUser));
        assertEq(engine.getReserveBalance(wEth), reserveBefore);
    }

    function test_reserveAccruesOnEveryRedeem() public mintedBSC {
        vm.prank(USER);
        engine.redeemCollateral(wEth, 1e18);
        uint256 afterFirst = engine.getReserveBalance(wEth);
        assertEq(afterFirst, 1e15);

        vm.prank(USER);
        engine.redeemCollateral(wEth, 1e18);
        assertEq(engine.getReserveBalance(wEth), afterFirst + 1e15);
    }

    function test_reserveEmitsAccruedEvent() public mintedBSC {
        uint256 expectedFee = 1e15;
        vm.prank(USER);
        vm.expectEmit(true, false, false, true, address(engine));
        emit CoinEngine.ReserveAccrued(wEth, expectedFee);
        engine.redeemCollateral(wEth, 1e18);
    }

    function test_reserveStaysZeroForTokenWithNoActivity() public mintedBSC {
        assertEq(engine.getReserveBalance(wBtc), 0);
    }

    function test_reservePersistenceAcrossUserInteractions() public mintedBSC {
        vm.prank(USER);
        engine.redeemCollateral(wEth, 2e18);
        uint256 reserveAfterRedeem = engine.getReserveBalance(wEth);

        vm.startPrank(USER);
        ERC20Mock(wEth).approve(address(engine), 1e18);
        engine.depositCollateral(wEth, 1e18);
        vm.stopPrank();

        assertEq(engine.getReserveBalance(wEth), reserveAfterRedeem);
    }
}

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

        // Give the user some collateral
        ERC20Mock(wEth).mint(USER, ERC20_USER_BALANCE);
    }

    /*//////////////////////////////////////////////////////////////
                               CONSTRUCTOR TESTS
        //////////////////////////////////////////////////////////////*/
    modifier mintedBSC() {
        vm.startPrank(USER);
        ERC20Mock(wEth).approve(address(engine), AMOUNT_COLLATERAL);
        engine.depositCollateral(wEth, AMOUNT_COLLATERAL);
        engine.mintBSC(100 ether); //100BSC
        vm.stopPrank();
        _;
    }

    /// @dev USER deposits AMOUNT_COLLATERAL and mints AMOUNT_TO_MINT. HF ends up very safe
    ///      so subsequent redeems won't revert on health factor.
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

        engine.mintBSC(10000 ether); // near bsc maximum minting allowed

        vm.stopPrank();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                           CONSTRUCTOR TESTS
    //////////////////////////////////////////////////////////////*/
    function test_Reverts_If_Token_Length_Does_Not_Match_PriceFeeds() public {
        tokenAddresses.push(wEth);
        priceFeedAddresses.push(ethUsdPriceFeed);
        priceFeedAddresses.push(btcUsdPriceFeed);

        vm.expectRevert(CoinEngine.CoinEngine__Token_Addresses_And_PriceFeeds_Length_Mismatch.selector);
        new CoinEngine(tokenAddresses, priceFeedAddresses, address(bsc), treasury);
    }

    function test_deployment_engineOwnsBsc() public view {
        assertEq(bsc.owner(), address(engine));
    }

    /*//////////////////////////////////////////////////////////////
                           PRICE FEEDS TESTS
    //////////////////////////////////////////////////////////////*/
    function testGetUsdValue() public view {
        uint256 ethAmount = 15e18; // 15 ETH
        // 15 ETH * 2000e8 = 30000e18
        uint256 expectedUsdValue = 30000e18;
        uint256 actualUsdValue = engine.getUsdValue(wEth, ethAmount);
        assertEq(actualUsdValue, expectedUsdValue);
    }

    function testGetCollateralAmountInUsd() public view {
        uint256 collateralAmountInUsd = 100 ether;
        // $2000/ETH $100 = ?eth
        uint256 expectedWeth = 0.05 ether;
        uint256 actualWeth = engine.getCollateralAmountFromUsd(wEth, collateralAmountInUsd);
        assertEq(expectedWeth, actualWeth);
    }

    function test_usdValueRespectsTokenDecimals() public {
        // 1. Deploy an 8-dec ERC20
        ERC20MockEightDec wBtc8 = new ERC20MockEightDec();

        // 2. Deploy a fresh price feed
        MockV3Aggregator feed = new MockV3Aggregator(8, 40000e8);

        // 3. Deploy a fresh engine with just this one collateral
        address[] memory tokens = new address[](1);
        tokens[0] = address(wBtc8);
        address[] memory feeds = new address[](1);
        feeds[0] = address(feed);

        CoinEngine freshEngine = new CoinEngine(tokens, feeds, address(bsc), address(0xdead));

        // 4. Assert
        assertEq(freshEngine.getUsdValue(address(wBtc8), 1e8), 40000e18);
        // 1e8 = 1 whole BTC in 8-dec, price = $40,000, expected = 40000e18
    }

    /*//////////////////////////////////////////////////////////////
                        DEPOSIT COLLATERAL TESTS
    //////////////////////////////////////////////////////////////*/
    function testRevertIfDepositZeroV1() external {
        // good practice man!
        vm.startPrank(USER);
        ERC20Mock(wEth).approve(address(engine), AMOUNT_COLLATERAL);

        vm.expectRevert(CoinEngine.CoinEngine__Must_Be_More_Than_Zero.selector);
        engine.depositCollateral(wEth, 0);
        vm.stopPrank();
    }

    function testRevertIfDepositZero() external {
        // the function reverts before the safeTransferFrom is called, so we don't need to approve any tokens for this test.
        vm.prank(USER);
        vm.expectRevert(CoinEngine.CoinEngine__Must_Be_More_Than_Zero.selector);
        engine.depositCollateral(wEth, 0);
    }

    modifier collateralDeposited() {
        vm.startPrank(USER);
        ERC20Mock(wEth).approve(address(engine), AMOUNT_COLLATERAL);
        engine.depositCollateral(wEth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

    function testRevertsWithUnapprovedCollateral() public {
        ERC20Mock damnToken = new ERC20Mock();
        vm.startPrank(USER);
        vm.expectRevert(CoinEngine.CoinEngine__Not_Allowed_Token.selector);
        engine.depositCollateral(address(damnToken), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    function testDepositCollateralAndGetAccountInfo() public collateralDeposited {
        (uint256 totalBscMinted, uint256 collateralValueInUsd) = engine.getAccountInformation(USER);

        uint256 expectedTotalBscMinted = 0;
        uint256 expectedDepositAmount = engine.getCollateralAmountFromUsd(wEth, collateralValueInUsd);

        assertEq(totalBscMinted, expectedTotalBscMinted);
        assertEq(AMOUNT_COLLATERAL, expectedDepositAmount);
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
        uint256 balance = engine.getCollateralBalanceOfUser(wEth, USER);

        assertEq(balance, AMOUNT_COLLATERAL);
    }

    function testRevertsIfMintAmountIsZero() public {
        vm.prank(USER);
        vm.expectRevert(CoinEngine.CoinEngine__Must_Be_More_Than_Zero.selector);

        engine.mintBSC(0);
    }

    // User deposits $20,000 collateral
    // Threshold = 50%.
    // Max mint allowed = $10,000
    // If user tries minting above that → revert
    function testRevertsIfMintBreaksHealthFactor() public collateralDeposited {
        uint256 amountToMint = 20000 ether;

        vm.startPrank(USER);
        vm.expectRevert();
        engine.mintBSC(amountToMint);
        vm.stopPrank();
    }

    function testMintBSCUpdatesMintedAmount() public collateralDeposited {
        uint256 amountToMint = 100 ether;

        vm.prank(USER);
        engine.mintBSC(amountToMint);

        (uint256 totalMinted,) = engine.getAccountInformation(USER);

        assertEq(totalMinted, amountToMint);
    }

    function testMintBSCTransfersTokensToUser() public collateralDeposited {
        uint256 amountToMint = 100 ether;

        vm.prank(USER);
        engine.mintBSC(amountToMint);

        uint256 userBalance = bsc.balanceOf(USER);
        assertEq(userBalance, amountToMint);
    }

    /*//////////////////////////////////////////////////////////////
                               BURN TESTS
    //////////////////////////////////////////////////////////////*/
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

    /*//////////////////////////////////////////////////////////////
                        REDEEM COLLATERAL TESTS
    //////////////////////////////////////////////////////////////*/
    function testRedeemRevertsIfHealthFactorBreaks() public mintedBSC {
        vm.startPrank(USER);
        vm.expectRevert();
        engine.redeemCollateral(wEth, AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    function testCanRedeemCollateral() public mintedBSC {
        vm.startPrank(USER);
        bsc.approve(address(engine), 100 ether); //allowing engine to use the 100BSC
        engine.burnBSC(100 ether);
        engine.redeemCollateral(wEth, AMOUNT_COLLATERAL);
        vm.stopPrank();

        uint256 balance = engine.getCollateralBalanceOfUser(USER, wEth);

        assertEq(balance, 0);
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

    /*//////////////////////////////////////////////////////////////
                    REDEEM COLLATERAL FROM BSC TESTS
    //////////////////////////////////////////////////////////////*/
    function testMustReedeemMoreThanZero() public mintedBSC {
        vm.startPrank(USER);
        bsc.approve(address(engine), 100 ether); // amount to mint == 100 ether(BSC)
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
                          HEALTH FACTOR TESTS
    //////////////////////////////////////////////////////////////*/
    function testHealthFactorReturnsMaxIfNoMinted() public collateralDeposited {
        uint256 healthFactor = engine.getHealthFactor(USER);

        assertEq(healthFactor, type(uint256).max);
    }

    function testHealthFactorCanDecreaseBelowOne() public mintedNearThreshold {
        int256 ethUsdTankedPrice = 500e8; // $500/ETH

        // we need to be 200% overcollaterized at all time

        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdTankedPrice);

        uint256 userHealthFactor = engine.getHealthFactor(USER);
        assert(userHealthFactor < 1e18);
    }

    function test_liquidateBankruptPositionSeizesAllCollateral() public {
        // ── Setup: user deposits 1 ETH, mints at HF ≈ 1.0
        address user = makeAddr("bankruptUser");
        uint256 depositAmount = 1e18; // 1 ETH
        deal(wEth, user, depositAmount);

        vm.startPrank(user);
        ERC20(wEth).approve(address(engine), depositAmount);
        engine.depositCollateral(wEth, depositAmount);
        // Mint up to HF ≈ 1.0: debt = (collateral USD × 50%) → HF = 1.0
        // With ETH = $2000, collateral = $2000, max safe debt = $1000
        engine.mintBSC(1000e18);
        vm.stopPrank();

        // ── Crash ETH from $2000 to $800 (60% drop)
        MockV3Aggregator(engine.getCollateralTokenPriceFeed(wEth)).updateAnswer(800e8);

        // Now: collateral = $800, debt = $1000.
        // HF = (800 × 0.5) / 1000 = 0.4  → bankrupt territory (< 0.55)

        // ── Liquidator steps in
        address liquidator = makeAddr("liquidator");
        deal(address(bsc), liquidator, 1000e18); // give liquidator BSC to burn

        uint256 liquidatorWethBefore = ERC20(wEth).balanceOf(liquidator);

        vm.startPrank(liquidator);
        ERC20(bsc).approve(address(engine), 1000e18);
        engine.liquidate(wEth, user, 1000e18); // try to cover all debt
        vm.stopPrank();

        // Calculate the expected debt burn using the same collateral cap.
        uint256 cappedCollateralForDebt = depositAmount * 100 / 110;

        uint256 expectedDebtBurned = engine.getUsdValue(wEth, cappedCollateralForDebt);

        uint256 expectedRemainingDebt = 1000e18 - expectedDebtBurned;

        // ── Liquidation assertions
        uint256 liquidatorWethAfter = ERC20(wEth).balanceOf(liquidator);

        assertEq(engine.getCollateralBalanceOfUser(wEth, user), 0);

        assertEq(liquidatorWethAfter - liquidatorWethBefore, depositAmount);

        // User's remaining debt should equal the recognized bad debt.
        (uint256 userRemainingDebt, uint256 userCollateralUsd) = engine.getAccountInformation(user);

        assertEq(userRemainingDebt, expectedRemainingDebt);
        assertEq(engine.getTotalBadDebt(), expectedRemainingDebt);
        assertEq(userCollateralUsd, 0);
    }

    /*//////////////////////////////////////////////////////////////
                        ABSORPTION TESTS
    //////////////////////////////////////////////////////////////*/

    /// @dev Creates a bad-debt event: fresh user deposits, mints, price crashes, liquidator covers.
    ///      Returns the user address. Uses a unique address per call so tests can chain multiple events.
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
        deal(wEth, liquidator, 1e18); // Give liquidator some collateral
        vm.startPrank(liquidator);
        ERC20Mock(wEth).approve(address(engine), 1e18);
        engine.depositCollateral(wEth, 1e18); // Liquidator deposits collateral

        deal(address(bsc), liquidator, mintAmount * 2);
        bsc.approve(address(engine), mintAmount * 2);
        engine.liquidate(wEth, badUser, mintAmount);
        vm.stopPrank();
    }

    /// @notice Reserve is large enough → absorbs bad debt fully. No uncovered debt recorded.
    /// @dev Setup numbers (price = $500 during crash):
    ///      USER redeems 5 ETH → reserve = 0.005 ETH = 5e15 wei
    ///      Bad debt user: 0.02 ETH deposit, 10 BSC debt, HF = 0.5
    ///      After liquidation: ~0.0018 ETH of uncovered debt = 1.8e15 wei
    ///      Reserve (5e15) > bad debt (1.8e15) → full absorption
    function test_reserveAbsorbsBadDebtFully() public mintedBSC {
        vm.prank(USER);
        engine.redeemCollateral(wEth, 5e18);

        uint256 reserveBefore = engine.getReserveBalance(wEth);
        uint256 treasuryBefore = ERC20Mock(wEth).balanceOf(engine.getBadDebtSink());
        assertGt(reserveBefore, 0, "reserve should have accrued");

        _createBadDebt(0.02e18, 10e18, 500e8);

        assertLt(engine.getReserveBalance(wEth), reserveBefore, "reserve should decrease");
        assertEq(engine.getTotalBadDebt(), 0, "no uncovered bad debt - reserve covered it all");
        assertGt(
            ERC20Mock(wEth).balanceOf(engine.getBadDebtSink()),
            treasuryBefore,
            "treasury should receive absorbed collateral"
        );
    }

    /// @notice Reserve is too small → depleted to zero, rest recorded as uncovered debt.
    /// @dev Tiny reserve: USER redeems 0.05 ETH → fee = 5e13 wei
    ///      Large bad debt: 1 ETH deposit, 1000 BSC, crash to $500 → HF = 0.25
    ///      Bad debt in ETH terms ≫ reserve → partial absorption, remainder tracked
    function test_reserveDepletedThenUncoveredBadDebtRecorded() public mintedBSC {
        vm.prank(USER);
        engine.redeemCollateral(wEth, 0.05e18);

        uint256 reserveBefore = engine.getReserveBalance(wEth);
        assertGt(reserveBefore, 0, "reserve should have accrued");

        _createBadDebt(1e18, 1000e18, 500e8);

        assertEq(engine.getReserveBalance(wEth), 0, "reserve should be depleted");
        assertGt(engine.getTotalBadDebt(), 0, "uncovered bad debt should be recorded");
    }

    /// @notice Physical collateral flows to the treasury address (not address(0xdead)),
    ///         proving the sink transfer works with a real destination.
    function test_reserveTransferredToTreasuryOnAbsorption() public mintedBSC {
        vm.prank(USER);
        engine.redeemCollateral(wEth, 5e18); // Redeem half — HF stays healthy

        address sink = engine.getBadDebtSink();
        uint256 sinkBefore = ERC20Mock(wEth).balanceOf(sink);

        _createBadDebt(0.02e18, 10e18, 500e8);

        assertGt(
            ERC20Mock(wEth).balanceOf(engine.getBadDebtSink()),
            sinkBefore,
            "treasury should receive physically transferred collateral"
        );
    }
}

// SPDX-License-Identifier: MIT

pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {DeployBSC} from "../../script/DeployBSC.s.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {BarneyStableCoin} from "../../src/BarneyStableCoin.sol";
import {CoinEngine} from "../../src/CoinEngine.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {MockV3Aggregator} from "@chainlink/contracts/src/v0.8/tests/MockV3Aggregator.sol";

contract CoinEngineTest is Test {
    DeployBSC deployer;
    HelperConfig helperConfig;
    BarneyStableCoin bsc;
    CoinEngine engine;

    address ethUsdPriceFeed;
    address btcUsdPriceFeed;
    address wEth;
    address wBtc;

    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    address public USER = makeAddr("user");
    uint256 public constant AMOUNT_COLLATERAL = 10 ether;
    uint256 public constant ERC20_USER_BALANCE = 10 ether;

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
    function test_Reverts_If_Token_Length_Does_Not_Match_PriceFeeds() public {
        tokenAddresses.push(wEth);
        priceFeedAddresses.push(ethUsdPriceFeed);
        priceFeedAddresses.push(btcUsdPriceFeed);

        vm.expectRevert(CoinEngine.CoinEngine__Token_Addresses_And_PriceFeeds_Length_Mismatch.selector);
        new CoinEngine(tokenAddresses, priceFeedAddresses, address(bsc));
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

    modifier mintedBSC() {
        vm.startPrank(USER);
        ERC20Mock(wEth).approve(address(engine), AMOUNT_COLLATERAL);
        engine.depositCollateral(wEth, AMOUNT_COLLATERAL);
        engine.mintBSC(100 ether); //100BSC
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
}

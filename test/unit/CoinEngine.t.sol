// SPDX-License-Identifier: MIT

pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {DeployBSC} from "../../script/DeployBSC.s.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {BarneyStableCoin} from "../../src/BarneyStableCoin.sol";
import {CoinEngine} from "../../src/CoinEngine.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

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
}

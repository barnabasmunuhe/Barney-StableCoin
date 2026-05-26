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
                           PRICE FEEDS TESTS
    //////////////////////////////////////////////////////////////*/
    function testGetUsdValue() public {
        uint256 ethAmount = 15e18; // 15 ETH
        // 15 ETH * 2000e8 = 30000e18
        uint256 expectedUsdValue = 30000e18;
        uint256 actualUsdValue = engine.getUsdValue(wEth, ethAmount);
        assertEq(actualUsdValue, expectedUsdValue);
    }

    /*//////////////////////////////////////////////////////////////
                        DEPOSIT COLLATERAL TESTS
    //////////////////////////////////////////////////////////////*/
    function testRevertIfDepositZeroV1() external {
        // good practice man!
        vm.startPrank(USER);
        ERC20Mock(wEth).approve(address(engine), AMOUNT_COLLATERAL);

        vm.expectRevert(CoinEngine.CoinEngine__MustBeMoreThanZero.selector);
        engine.depositCollateral(wEth, 0);
        vm.stopPrank();
    }

    function testRevertIfDepositZero() external {
        // the function reverts before the safeTransferFrom is called, so we don't need to approve any tokens for this test.
        vm.prank(USER);
        vm.expectRevert(CoinEngine.CoinEngine__MustBeMoreThanZero.selector);
        engine.depositCollateral(wEth, 0);
    }
}

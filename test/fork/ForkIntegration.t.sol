// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {BarneyStableCoin} from "../../src/BarneyStableCoin.sol";
import {CoinEngine} from "../../src/CoinEngine.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// Sepolia WBTC is not deployed as a contract at the address we expected,
// so we deploy a small 8-decimal mock. The Chainlink BTC/USD feed is still real,
// which is the thing this test actually needs to prove.
contract MockWBTC is ERC20 {
    constructor() ERC20("Wrapped BTC", "WBTC") {}

    function decimals() public pure override returns (uint8) {
        return 8;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @title  Fork Integration Test
/// @notice Runs against a Sepolia fork with real Chainlink feeds and real WETH.
///         Exercises every contract in the system: BarneyStableCoin, CoinEngine, OracleLib.
/// @dev    Requires SEPOLIA_RPC_URL env var.
///         Run: forge test --match-path "test/fork/*" -vvv
contract ForkIntegrationTest is Test {
    /*//////////////////////////////////////////////////////////////
                          SEPOLIA ADDRESSES
    //////////////////////////////////////////////////////////////*/
    // ETH/USD and BTC/USD feeds — both confirmed live on Sepolia
    address constant SEPOLIA_ETH_USD_FEED = 0x694AA1769357215DE4FAC081bf1f309aDC325306;
    address constant SEPOLIA_BTC_USD_FEED = 0x1b44F3514812d835EB1BDB0acB33d3fA3351Ee43;
    // Real WETH on Sepolia — confirmed working (decimals returns 18)
    address constant SEPOLIA_WETH = 0xdd13E55209Fd76AfE204dBda4007C227904f0a81;

    /*//////////////////////////////////////////////////////////////
                          SYSTEM UNDER TEST
    //////////////////////////////////////////////////////////////*/
    BarneyStableCoin bsc;
    CoinEngine engine;
    MockWBTC wbtc;
    address treasury = makeAddr("treasury");

    /*//////////////////////////////////////////////////////////////
                               ACTORS
    //////////////////////////////////////////////////////////////*/
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address liquidator = makeAddr("liquidator");

    function setUp() public {
        vm.createSelectFork(vm.envString("SEPOLIA_RPC_URL"));

        // deploy the WBTC mock — see top-of-file note
        wbtc = new MockWBTC();

        address[] memory tokens = new address[](2);
        tokens[0] = SEPOLIA_WETH;
        tokens[1] = address(wbtc);

        address[] memory feeds = new address[](2);
        feeds[0] = SEPOLIA_ETH_USD_FEED;
        feeds[1] = SEPOLIA_BTC_USD_FEED; // real feed, real data

        bsc = new BarneyStableCoin();
        engine = new CoinEngine(tokens, feeds, address(bsc), treasury);
        // engine needs ownership so it can mint and burn BSC
        bsc.transferOwnership(address(engine));
    }

    /*//////////////////////////////////////////////////////////////
                            HELPERS
    //////////////////////////////////////////////////////////////*/

    // deal tokens to `user`, deposit them, and optionally mint BSC
    function _fundAndDeposit(address user, address token, uint256 amount, uint256 mintAmount) internal {
        deal(token, user, amount);
        vm.startPrank(user);
        IERC20(token).approve(address(engine), amount);
        engine.depositCollateral(token, amount);
        if (mintAmount > 0) {
            engine.mintBSC(mintAmount);
        }
        vm.stopPrank();
    }

    // read the live USD price straight from the Chainlink feed
    function _livePrice(address token) internal view returns (int256) {
        (, int256 price,,,) = AggregatorV3Interface(engine.getCollateralTokenPriceFeed(token)).latestRoundData();
        return price;
    }

    /*//////////////////////////////////////////////////////////////
                      FULL LIFECYCLE TEST
    //////////////////////////////////////////////////////////////*/

    // deposit → mint → burn half → redeem half, all against real feeds
    function test_fork_fullLifecycle() public {
        // 1 WETH at ~$2000 = $2000 collateral, mint $500 of BSC → HF ≈ 4
        uint256 depositAmount = 1e18;
        uint256 mintAmount = 500e18;

        _fundAndDeposit(alice, SEPOLIA_WETH, depositAmount, mintAmount);

        // sanity check the deposit + mint landed
        assertEq(engine.getCollateralBalanceOfUser(SEPOLIA_WETH, alice), depositAmount);
        assertEq(bsc.balanceOf(alice), mintAmount);
        (uint256 minted, uint256 collateralUsd) = engine.getAccountInformation(alice);
        assertEq(minted, mintAmount);
        assertGt(collateralUsd, 0);

        // burn half the debt
        uint256 burnAmount = 250e18;
        vm.startPrank(alice);
        bsc.approve(address(engine), burnAmount);
        engine.burnBSC(burnAmount);
        vm.stopPrank();
        (uint256 mintedAfterBurn,) = engine.getAccountInformation(alice);
        assertEq(mintedAfterBurn, mintAmount - burnAmount);

        // redeem half the collateral — 0.1% fee should hit the reserve
        uint256 redeemAmount = 0.5e18;
        uint256 reserveBefore = engine.getReserveBalance(SEPOLIA_WETH);
        vm.prank(alice);
        engine.redeemCollateral(SEPOLIA_WETH, redeemAmount);

        uint256 expectedFee = (redeemAmount * 10) / 10_000;
        assertEq(engine.getReserveBalance(SEPOLIA_WETH), reserveBefore + expectedFee);
        assertEq(engine.getCollateralBalanceOfUser(SEPOLIA_WETH, alice), depositAmount - redeemAmount);
    }

    /*//////////////////////////////////////////////////////////////
                   DECIMAL HANDLING (WBTC 8-DEC)
    //////////////////////////////////////////////////////////////*/

    // 1 whole WBTC = 1e8 raw units. If the engine handles this right,
    // getAccountInformation should report the correct USD value.
    function test_fork_wbtcDecimalHandling() public {
        assertEq(wbtc.decimals(), 8, "WBTC mock should be 8 decimals");

        uint256 depositAmount = 1e8; // 1 whole WBTC
        wbtc.mint(alice, depositAmount);

        vm.startPrank(alice);
        wbtc.approve(address(engine), depositAmount);
        engine.depositCollateral(address(wbtc), depositAmount);
        vm.stopPrank();

        (, uint256 collateralUsd) = engine.getAccountInformation(alice);
        int256 btcPrice = _livePrice(address(wbtc));

        // feed price is 8-dec, USD value is 18-dec → multiply by 1e10
        uint256 expectedUsd = uint256(btcPrice) * 1e10;
        // small tolerance in case the live feed moves during the fork block
        assertApproxEqRel(collateralUsd, expectedUsd, 0.01e18);
    }

    /*//////////////////////////////////////////////////////////////
                      LIQUIDATION + RESERVE + TREASURY
    //////////////////////////////////////////////////////////////*/

    // Mock a crash on the ETH/USD feed, liquidate alice's position, prove the
    // reserve absorbs part of the bad debt and collateral lands in the treasury.
    function test_fork_liquidationReserveAndTreasury() public {
        // alice: 1 WETH deposit, mint $500 of debt.
        // At fork price ~$1730: HF = (1730 × 0.5) / 500 = 1.73 → safely mintable.
        // If the price moves a bit during execution it still stays above 1.0.
        _fundAndDeposit(alice, SEPOLIA_WETH, 1e18, 500e18);

        // bob accrues some reserve by redeeming — no debt so redeem won't break HF
        _fundAndDeposit(bob, SEPOLIA_WETH, 2e18, 0);
        vm.prank(bob);
        engine.redeemCollateral(SEPOLIA_WETH, 1e18); // fee = 1e15 wei
        uint256 reserveBefore = engine.getReserveBalance(SEPOLIA_WETH);
        assertGt(reserveBefore, 0, "reserve should have accrued");

        uint256 treasuryBefore = IERC20(SEPOLIA_WETH).balanceOf(treasury);

        // mock the ETH feed down to $400.
        // collateral value = $400, debt = $500 → HF = 0.4 (bankrupt zone, < 0.55)
        // liquidator can only cover 1 ETH / 1.1 × $400 = $363.64 of the $500 debt,
        // leaving ~$136 as bad debt → reserve absorbs what it can, rest goes to
        // s_totalBadDebt and the treasury receives the absorbed collateral.
        vm.mockCall(
            SEPOLIA_ETH_USD_FEED,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(1), int256(400e8), uint256(block.timestamp), uint256(block.timestamp), uint80(1))
        );

        // liquidator covers the (now capped) debt
        deal(address(bsc), liquidator, 500e18);
        vm.startPrank(liquidator);
        bsc.approve(address(engine), 500e18);
        engine.liquidate(SEPOLIA_WETH, alice, 500e18);
        vm.stopPrank();

        // alice's collateral fully seized
        assertEq(engine.getCollateralBalanceOfUser(SEPOLIA_WETH, alice), 0, "alice collateral seized");

        // treasury received whatever the reserve absorbed
        uint256 treasuryAfter = IERC20(SEPOLIA_WETH).balanceOf(treasury);
        assertGt(treasuryAfter, treasuryBefore, "treasury received absorbed collateral");

        // leftover debt that the reserve couldn't cover is recorded as bad debt
        assertGt(engine.getTotalBadDebt(), 0, "uncovered bad debt should be recorded");
    }

    /*//////////////////////////////////////////////////////////////
                   ORACLE STALENESS ON FORK
    //////////////////////////////////////////////////////////////*/

    // Warp 2 hours → the feed is stale → OracleLib should revert mint.
    function test_fork_stalePriceReverts() public {
        _fundAndDeposit(alice, SEPOLIA_WETH, 1e18, 0);

        vm.warp(block.timestamp + 2 hours);

        vm.prank(alice);
        vm.expectRevert();
        engine.mintBSC(100e18);
    }

    /*//////////////////////////////////////////////////////////////
                   INVARIANT UNDER FORK
    //////////////////////////////////////////////////////////////*/

    // same accounting invariant that passes in fuzzing must also hold
    // when the system is running against real fork state.
    function test_fork_accountingInvariantHolds() public {
        _fundAndDeposit(alice, SEPOLIA_WETH, 2e18, 500e18);
        _fundAndDeposit(bob, address(wbtc), 1e8, 5000e18);

        // redeem a bit to accrue reserve
        vm.prank(alice);
        engine.redeemCollateral(SEPOLIA_WETH, 0.5e18);

        // physical balance must equal user claims + reserve, per token
        address[] memory tokens = engine.getCollateralTokens();
        for (uint256 i = 0; i < tokens.length; i++) {
            address token = tokens[i];
            uint256 physical = IERC20(token).balanceOf(address(engine));
            uint256 accounting = engine.getTotalUserCollateral(token) + engine.getReserveBalance(token);
            assertEq(physical, accounting, "fork invariant broken");
        }
    }

    /*//////////////////////////////////////////////////////////////
                       INVARIANT UNDER FORK
        //////////////////////////////////////////////////////////////*/
    function test_fork_combinedFunctionsWork() public {
        deal(SEPOLIA_WETH, alice, 1e18);
        vm.startPrank(alice);
        IERC20(SEPOLIA_WETH).approve(address(engine), 1e18);
        engine.depositCollateralAndMintBSC(SEPOLIA_WETH, 1e18, 500e18);
        vm.stopPrank();

        assertEq(bsc.balanceOf(alice), 500e18);

        vm.startPrank(alice);
        bsc.approve(address(engine), 250e18);
        engine.redeemBSCForCollateral(SEPOLIA_WETH, 0.5e18, 250e18);
        vm.stopPrank();

        (uint256 remaining,) = engine.getAccountInformation(alice);
        assertEq(remaining, 250e18);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {DeployBSC} from "../../script/DeployBSC.s.sol";
import {CoinEngine} from "../../src/CoinEngine.sol";
import {BarneyStableCoin} from "../../src/BarneyStableCoin.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {Handler} from "./Handler.t.sol";

// PROPERTIES THAT MUST ALWAYS BE TRUE
// 1. Physical collateral matches user claims + reserves.
// 2. Getter functions remain callable.
// 3. BSC total supply equals outstanding debt.
// 4. Aggregate bad debt matches individual recognized bad-debt records.
// 5. Recognized bad debt never exceeds outstanding debt.

contract InvariantsTest is StdInvariant, Test {
    DeployBSC deployer;
    CoinEngine engine;
    BarneyStableCoin bsc;
    HelperConfig helperConfig;
    address wEth;
    address wBtc;
    Handler handler;

    uint256 public constant wEthAmount = 1e18;
    uint256 public constant wBtcAmount = 1e8;

    function setUp() external {
        deployer = new DeployBSC();
        (bsc, engine, helperConfig) = deployer.run();
        (,, wEth, wBtc,,) = helperConfig.activeNetworkConfig();
        handler = new Handler(engine, bsc);
        targetContract(address(handler));
    }

    function invariant_totalSupplyEqualsOutstandingDebt() public view {
        uint256 totalSupply = bsc.totalSupply();
        uint256 totalDebt = handler.getTotalDebt();

        assertEq(totalSupply, totalDebt, "BSC supply must equal outstanding debt");
    }

    function invariant_getterFunctionsShouldNotRevert() public view {
        engine.getCollateralTokens();
        engine.getCollateralBalanceOfUser(wEth, address(this));
        engine.getCollateralBalanceOfUser(wBtc, address(this));
        engine.getAccountInformation(address(this));
        engine.getUsdValue(wEth, wEthAmount);
        engine.getUsdValue(wBtc, wBtcAmount);
        engine.getBSCAddress();
        engine.getCollateralTokenPriceFeed(wEth);
        engine.getCollateralTokenPriceFeed(wBtc);
        engine.getCollateralAmountFromUsd(wEth, wEthAmount);
        engine.getHealthFactor(address(this));
        engine.getBadDebtSink();
        engine.getTotalBadDebt();
        engine.getTotalUserCollateral(wEth);
        engine.getReserveBalance(wEth);
    }

    /// @notice Physical collateral must always equal user claims + reserve.
    ///         Logs detailed diagnostic info on failure so CI failures are debuggable
    ///         without needing local reproduction.
    function invariant_engineBalanceMatchesAccounting() public view {
        address[] memory tokens = engine.getCollateralTokens();
        for (uint256 i = 0; i < tokens.length; i++) {
            address token = tokens[i];
            uint256 physical = IERC20(token).balanceOf(address(engine));
            uint256 userCollateral = engine.getTotalUserCollateral(token);
            uint256 reserve = engine.getReserveBalance(token);
            uint256 accounting = userCollateral + reserve;

            if (physical != accounting) {
                console.log("=== INVARIANT FAILURE: balance != accounting ===");
                console.log("Token:", token);
                console.log("Physical balance:", physical);
                console.log("User collateral:", userCollateral);
                console.log("Reserve:", reserve);
                console.log("Accounting (user + reserve):", accounting);
                if (physical > accounting) {
                    console.log("Delta (physical excess):", physical - accounting);
                } else {
                    console.log("Delta (accounting excess):", accounting - physical);
                }
            }
            assertEq(physical, accounting, "balance/accounting mismatch");
        }
    }

    function invariant_totalBadDebtMatchesActorRecords() public view {
        address[] memory actors = handler.getActors();
        uint256 totalRecognizedBadDebt;

        for (uint256 i = 0; i < actors.length; i++) {
            totalRecognizedBadDebt += engine.getRecognizedBadDebt(actors[i]);
        }

        assertEq(engine.getTotalBadDebt(), totalRecognizedBadDebt, "Aggregate bad debt mismatch");
    }

    function invariant_recognizedBadDebtNeverExceedsDebt() public view {
        address[] memory actors = handler.getActors();

        for (uint256 i = 0; i < actors.length; i++) {
            (uint256 debt,) = engine.getAccountInformation(actors[i]);

            assertLe(engine.getRecognizedBadDebt(actors[i]), debt, "Recognized bad debt exceeds outstanding debt");
        }
    }
}

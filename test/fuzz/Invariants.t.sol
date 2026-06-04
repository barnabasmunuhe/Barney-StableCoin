// SPDX-License-Identifier: MIT

// What are our invariants?
// 1. Total supply of BSC should always be less than the total value of collateral
// 2. Getter view functions should NEVER revert

pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {DeployBSC} from "../../script/DeployBSC.s.sol";
import {CoinEngine} from "../../src/CoinEngine.sol";
import {BarneyStableCoin} from "../../src/BarneyStableCoin.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {Handler} from "../../test/fuzz/Handler.t.sol";

contract InvariantsTests is StdInvariant, Test {
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
        (,, wEth, wBtc,) = helperConfig.activeNetworkConfig();
        handler = new Handler(engine, bsc);
        targetContract(address(handler));
    }

    function invariant_protocolMustHaveMoreValueThanTotalSupply() public view {
        // get value of all the collateral in the protocol
        // compare it to all debt (bsc)
        uint256 totalSupply = bsc.totalSupply();
        uint256 totalWEthDeposited = IERC20(wEth).balanceOf(address(engine));
        uint256 totalWBtcDeposited = IERC20(wBtc).balanceOf(address(engine));

        uint256 wEthValue = engine.getUsdValue(wEth, totalWEthDeposited);
        uint256 wBtcValue = engine.getUsdValue(wBtc, totalWBtcDeposited);

        console.log("wEth value: ", wEthValue);
        console.log("wBtc value: ", wBtcValue);
        console.log("total supply: ", totalSupply);
        console.log("times mint is called: ", handler.timesMintIsCalled());

        assert(wEthValue + wBtcValue >= totalSupply);
    }

    function invariant_getterFunctionsShouldNotRevert() public view {
        // we just call all the getter functions we have in our protocol and make sure they dont revert
        engine.getCollateralTokens();
        engine.getCollateralBalanceOfUser(wEth, address(this));
        engine.getCollateralBalanceOfUser(wBtc, address(this));
        engine.getAccountInformation(address(this));
        engine.getUsdValue(wEth, wEthAmount);
        engine.getUsdValue(wBtc, wBtcAmount);
        // engine.getAccountCollateralValueInUsd()
    }
}

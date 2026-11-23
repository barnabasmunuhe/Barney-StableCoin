// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {CoinEngine} from "../../src/CoinEngine.sol";
import {BarneyStableCoin} from "../../src/BarneyStableCoin.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {MockV3Aggregator} from "@chainlink/contracts/src/v0.8/tests/MockV3Aggregator.sol";

contract Handler is Test {
    CoinEngine engine;
    BarneyStableCoin bsc;

    ERC20Mock wEth;
    ERC20Mock wBtc;

    address[] public actors;
    uint256 public timesMintIsCalled;
    MockV3Aggregator public ethUsdPriceFeed;
    MockV3Aggregator public btcUsdPriceFeed;

    uint256 MAX_DEPOSIT_SIZE = type(uint96).max;

    constructor(CoinEngine _bscEngine, BarneyStableCoin _bsc) {
        engine = _bscEngine;
        bsc = _bsc;

        address[] memory collateralTokens = engine.getCollateralTokens();
        wEth = ERC20Mock(collateralTokens[0]);
        wBtc = ERC20Mock(collateralTokens[1]);

        ethUsdPriceFeed = MockV3Aggregator(engine.getCollateralTokenPriceFeed(address(wEth)));
        btcUsdPriceFeed = MockV3Aggregator(engine.getCollateralTokenPriceFeed(address(wBtc)));

        // Fixed actors — cannot collide with engine, bsc, tokens, or feeds
        actors.push(makeAddr("actor0"));
        actors.push(makeAddr("actor1"));
        actors.push(makeAddr("actor2"));
        actors.push(makeAddr("actor3"));
    }

    function getActors() external view returns (address[] memory) {
        return actors;
    }

    function depositCollateral(uint256 randomCollateral, uint256 amountCollateral, uint256 actorSeed) public {
        address actor = actors[actorSeed % actors.length];
        ERC20Mock collateral = _getCollateralFromRandomCollateral(randomCollateral);
        amountCollateral = bound(amountCollateral, 1, MAX_DEPOSIT_SIZE);

        vm.startPrank(actor);
        collateral.mint(actor, amountCollateral);
        collateral.approve(address(engine), amountCollateral);
        engine.depositCollateral(address(collateral), amountCollateral);
        vm.stopPrank();
    }

    function mintBSC(uint256 amount, uint256 actorSeed) public {
        address actor = actors[actorSeed % actors.length];
        (uint256 totalBscMinted, uint256 collateralValueInUsd) = engine.getAccountInformation(actor);
        int256 maxBSCToMint = (int256(collateralValueInUsd) / 2) - int256(totalBscMinted);
        if (maxBSCToMint <= 0) return;
        amount = bound(amount, 1, uint256(maxBSCToMint));

        vm.prank(actor);
        try engine.mintBSC(amount) {
            timesMintIsCalled++;
        } catch {}
    }

    function redeemCollateral(uint256 randomCollateral, uint256 amountCollateral, uint256 actorSeed) public {
        address actor = actors[actorSeed % actors.length];
        ERC20Mock collateral = _getCollateralFromRandomCollateral(randomCollateral);
        uint256 maxCollateralToRedeem = engine.getCollateralBalanceOfUser(address(collateral), actor);
        if (maxCollateralToRedeem == 0) return;
        amountCollateral = bound(amountCollateral, 1, maxCollateralToRedeem);

        vm.prank(actor);
        try engine.redeemCollateral(address(collateral), amountCollateral) {} catch {}
    }

    function _getCollateralFromRandomCollateral(uint256 randomCollateral) private view returns (ERC20Mock) {
        if (randomCollateral % 2 == 0) {
            return wEth;
        } else {
            return wBtc;
        }
    }
}

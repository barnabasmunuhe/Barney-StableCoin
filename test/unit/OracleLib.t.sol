// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {OracleLib} from "../../src/libraries/OracleLib.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {MockV3Aggregator} from "@chainlink/contracts/src/v0.8/tests/MockV3Aggregator.sol";

contract OracleLibTest is Test {
    uint8 private constant FEED_DECIMALS = 8;
    int256 private constant INITIAL_PRICE = 2000e8;
    uint256 private constant TIMEOUT = 1 hours;

    MockV3Aggregator private feed;

    function setUp() public {
        feed = new MockV3Aggregator(FEED_DECIMALS, INITIAL_PRICE);
    }

    function _check() internal view {
        OracleLib.stalePriceCheckLatestRoundData(AggregatorV3Interface(address(feed)));
    }

    function test_staleCheck_passesOnFreshPrice() public view {
        _check();
    }

    function test_staleCheck_passesAtExactTimeoutBoundary() public {
        vm.warp(block.timestamp + TIMEOUT);

        _check();
    }

    function test_staleCheck_revertsAfterTimeout() public {
        vm.warp(block.timestamp + TIMEOUT + 1);

        vm.expectRevert(OracleLib.OracleLib__PriceFeed_Is_Stale.selector);

        _check();
    }

    function test_staleCheck_revertsOnZeroPrice() public {
        feed.updateAnswer(0);

        vm.expectRevert(OracleLib.OracleLib__InvalidPrice.selector);

        _check();
    }

    function test_staleCheck_revertsOnNegativePrice() public {
        feed.updateAnswer(-1);

        vm.expectRevert(OracleLib.OracleLib__InvalidPrice.selector);

        _check();
    }

    function test_staleCheck_revertsOnFutureTimestamp() public {
        uint256 currentTime = block.timestamp;

        feed.updateRoundData(2, INITIAL_PRICE, currentTime + 1, currentTime + 3);

        vm.expectRevert(OracleLib.OracleLib__PriceFeed_Is_Stale.selector);

        _check();
    }

    function test_staleCheck_passesAfterPriceUpdate() public {
        vm.warp(block.timestamp + TIMEOUT + 1);

        // A new update refreshes the feed timestamp.
        feed.updateAnswer(2100e8);

        _check();
    }
}

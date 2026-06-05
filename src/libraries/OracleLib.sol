// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

/**
 * @title OracleLib
 * @author Barnabas Milton
 * @notice This library is used to check the Chainlink Oracle for stale data
 * -If the price feed is stale, the function will revert & render CoinEngine unusable until the price feed is updated
 * -The CoinEngine freezes up if the price feed is stale to prevent people from minting coins with outdated collateral prices, which could lead to undercollateralization of the system
 * @notice The downside of this is that if the price feed goes down, the entire system goes down, but this is a risk we are willing to take to prevent undercollateralization of the system
 */
library OracleLib {
    error OracleLib__PriceFeed_Is_Stale();
    uint256 private constant TIMEOUT = 3 hours;

    function stalePriceCheckLatestRoundData(AggregatorV3Interface priceFeed)
        public
        view
        returns (uint80, int256, uint256, uint256, uint80)
    {
        (uint80 roundID, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            priceFeed.latestRoundData();

        uint256 secondsSinceLastUpdate = block.timestamp - updatedAt;
        if (secondsSinceLastUpdate > TIMEOUT) {
            revert OracleLib__PriceFeed_Is_Stale();
        }
        return (roundID, answer, startedAt, updatedAt, answeredInRound);
    }
}

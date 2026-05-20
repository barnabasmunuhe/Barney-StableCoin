// SPDX-License-Identifier: MIT

pragma solidity ^0.8.28;

import {Script} from "forge-std/Script.sol";
import {BarneyStableCoin} from "../src/BarneyStableCoin.sol";
import {CoinEngine} from "../src/CoinEngine.sol";
import {HelperConfig} from "./HelperConfig.s.sol";

contract DeployBSC is Script {
    HelperConfig public helperConfig;

    address[] tokenAddresses;
    address[] priceFeedAddresses;

    function run() external returns (BarneyStableCoin, CoinEngine, HelperConfig) {
        helperConfig = new HelperConfig();
        HelperConfig.NetworkConfig memory config = helperConfig.getActiveNetworkConfig();

        tokenAddresses = new address[](2);
        tokenAddresses[0] = config.wEth;
        tokenAddresses[1] = config.wBtc;

        priceFeedAddresses = new address[](2);
        priceFeedAddresses[0] = config.wEthUsdPriceFeed;
        priceFeedAddresses[1] = config.wBtcUsdPriceFeed;

        vm.startBroadcast(config.deployerKey);
        BarneyStableCoin bsc = new BarneyStableCoin();
        CoinEngine engine = new CoinEngine(tokenAddresses, priceFeedAddresses, address(bsc));
        // Transfer ownership of the stablecoin to the engine
        bsc.transferOwnership(address(engine));
        vm.stopBroadcast();

        return (bsc, engine, helperConfig);
    }
}

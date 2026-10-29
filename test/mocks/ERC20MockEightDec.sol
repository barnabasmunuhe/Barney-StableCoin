// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice wBTC-shaped mock: 8 decimals, mintable, no approval magic.
///         Mirrors the decimal behavior of the real Wrapped BTC so the engine's
///         decimal-normalization logic is exercised correctly in tests.
contract ERC20MockEightDec is ERC20 {
    constructor() ERC20("wBTC8", "wBTC8") {}

    function decimals() public pure override returns (uint8) {
        return 8;
    }

    function mint(address to, uint256 amt) external {
        _mint(to, amt);
    }
}

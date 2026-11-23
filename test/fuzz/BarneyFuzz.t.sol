// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {BarneyStableCoin} from "../../src/BarneyStableCoin.sol";

contract BarneyFuzzTests is Test {
    BarneyStableCoin bsc;

    function setUp() public {
        bsc = new BarneyStableCoin();
    }

    /*//////////////////////////////////////////////////////////////
                       MINT FUZZ
    //////////////////////////////////////////////////////////////*/
    function testFuzz_mintMintsExactAmount(uint256 amount) public {
        amount = bound(amount, 1, type(uint128).max);
        bsc.mint(address(0x1234), amount);
        assertEq(bsc.balanceOf(address(0x1234)), amount);
    }

    function testFuzz_mintIncreasesSupply(uint256 amount) public {
        amount = bound(amount, 1, type(uint128).max);
        uint256 before = bsc.totalSupply();
        bsc.mint(address(0x1234), amount);
        assertEq(bsc.totalSupply(), before + amount);
    }

    /*//////////////////////////////////////////////////////////////
                       BURN FUZZ
    //////////////////////////////////////////////////////////////*/
    function testFuzz_burnReducesExactAmount(uint256 mintAmount, uint256 burnAmount) public {
        mintAmount = bound(mintAmount, 1, type(uint128).max);
        burnAmount = bound(burnAmount, 1, mintAmount);

        bsc.mint(address(this), mintAmount);
        bsc.burn(burnAmount);

        assertEq(bsc.balanceOf(address(this)), mintAmount - burnAmount);
        assertEq(bsc.totalSupply(), mintAmount - burnAmount);
    }

    function testFuzz_burnMoreThanBalanceReverts(uint256 mintAmount, uint256 excess) public {
        mintAmount = bound(mintAmount, 1, type(uint128).max);
        excess = bound(excess, 1, type(uint128).max);

        bsc.mint(address(this), mintAmount);
        vm.expectRevert(BarneyStableCoin.BarneyStableCoin__BurnAmountExceedsBalance.selector);
        bsc.burn(mintAmount + excess);
    }

    function testFuzz_mintThenBurnRestoresState(uint256 amount) public {
        amount = bound(amount, 1, type(uint128).max);
        uint256 supplyBefore = bsc.totalSupply();

        bsc.mint(address(this), amount);
        bsc.burn(amount);

        assertEq(bsc.totalSupply(), supplyBefore);
        assertEq(bsc.balanceOf(address(this)), 0);
    }

    /*//////////////////////////////////////////////////////////////
                       TRANSFER FUZZ
    //////////////////////////////////////////////////////////////*/
    function testFuzz_transferPreservesTotalSupply(uint256 mintAmount, uint256 transferAmount) public {
        mintAmount = bound(mintAmount, 1, type(uint128).max);
        transferAmount = bound(transferAmount, 1, mintAmount);
        address recipient = makeAddr("recipient");

        bsc.mint(address(this), mintAmount);
        uint256 supplyBefore = bsc.totalSupply();
        bsc.transfer(recipient, transferAmount);

        assertEq(bsc.totalSupply(), supplyBefore);
        assertEq(bsc.balanceOf(address(this)) + bsc.balanceOf(recipient), supplyBefore);
    }

    function testFuzz_transferReducesSenderBalance(uint256 mintAmount, uint256 transferAmount) public {
        mintAmount = bound(mintAmount, 1, type(uint128).max);
        transferAmount = bound(transferAmount, 1, mintAmount);
        address recipient = makeAddr("recipient");

        bsc.mint(address(this), mintAmount);
        bsc.transfer(recipient, transferAmount);

        assertEq(bsc.balanceOf(address(this)), mintAmount - transferAmount);
        assertEq(bsc.balanceOf(recipient), transferAmount);
    }

    function testFuzz_totalSupplyEqualsSumOfBalances(uint256 amount1, uint256 amount2) public {
        amount1 = bound(amount1, 1, type(uint128).max);
        amount2 = bound(amount2, 1, type(uint128).max);
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");

        bsc.mint(alice, amount1);
        bsc.mint(bob, amount2);

        assertEq(bsc.totalSupply(), bsc.balanceOf(alice) + bsc.balanceOf(bob));
    }
}

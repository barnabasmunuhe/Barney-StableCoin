// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {BarneyStableCoin} from "../../src/BarneyStableCoin.sol";

contract BSCTest is Test {
    BarneyStableCoin bsc;

    function setUp() public {
        bsc = new BarneyStableCoin();
        // Test contract is the deployer → becomes owner → can mint/burn
    }

    /*//////////////////////////////////////////////////////////////
                       CONSTRUCTOR / OWNER
    //////////////////////////////////////////////////////////////*/
    function test_constructorSetsNameAndSymbol() public view {
        assertEq(bsc.name(), "BarneyStableCoin");
        assertEq(bsc.symbol(), "BSC");
    }

    function test_ownerIsDeployer() public view {
        assertEq(bsc.owner(), address(this));
    }

    function test_initialSupplyIsZero() public view {
        assertEq(bsc.totalSupply(), 0);
    }

    /*//////////////////////////////////////////////////////////////
                       MINT TESTS
    //////////////////////////////////////////////////////////////*/
    function test_mintMintsToRecipient() public {
        bsc.mint(address(0x1234), 100e18);
        assertEq(bsc.balanceOf(address(0x1234)), 100e18);
        assertEq(bsc.totalSupply(), 100e18);
    }

    function test_mintReturnsTrue() public {
        assertTrue(bsc.mint(address(0x1234), 100e18));
    }

    function test_mintRevertsOnZeroAddress() public {
        vm.expectRevert(BarneyStableCoin.BarneyStableCoin__NotZeroAddress.selector);
        bsc.mint(address(0), 100e18);
    }

    function test_mintRevertsOnZeroAmount() public {
        vm.expectRevert(BarneyStableCoin.BarneyStableCoin__MustBeMoreThanZero.selector);
        bsc.mint(address(0x1234), 0);
    }

    function test_mintRevertsForNonOwner() public {
        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", attacker));
        bsc.mint(address(0x1234), 100e18);
    }

    /*//////////////////////////////////////////////////////////////
                       BURN TESTS
    //////////////////////////////////////////////////////////////*/
    function test_burnReducesBalanceAndSupply() public {
        bsc.mint(address(this), 100e18);
        uint256 supplyBefore = bsc.totalSupply();

        bsc.burn(40e18);

        assertEq(bsc.balanceOf(address(this)), 60e18);
        assertEq(bsc.totalSupply(), supplyBefore - 40e18);
    }

    function test_burnRevertsOnZeroAmount() public {
        bsc.mint(address(this), 100e18);
        vm.expectRevert(BarneyStableCoin.BarneyStableCoin__MustBeMoreThanZero.selector);
        bsc.burn(0);
    }

    function test_burnRevertsOnExcessAmount() public {
        bsc.mint(address(this), 100e18);
        vm.expectRevert(BarneyStableCoin.BarneyStableCoin__BurnAmountExceedsBalance.selector);
        bsc.burn(101e18);
    }

    function test_burnRevertsForNonOwner() public {
        address nonOwner = makeAddr("nonOwner");
        bsc.mint(address(this), 100e18);
        bsc.transfer(nonOwner, 50e18);

        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", nonOwner));
        bsc.burn(50e18);
    }

    /*//////////////////////////////////////////////////////////////
                       ERC20 BEHAVIOR TESTS
    //////////////////////////////////////////////////////////////*/
    function test_transferWorks() public {
        bsc.mint(address(this), 100e18);
        bsc.transfer(address(0x1234), 30e18);
        assertEq(bsc.balanceOf(address(0x1234)), 30e18);
        assertEq(bsc.balanceOf(address(this)), 70e18);
    }

    function test_approveAndTransferFromWorks() public {
        bsc.mint(address(this), 100e18);
        bsc.approve(address(0x1234), 50e18);

        vm.prank(address(0x1234));
        bsc.transferFrom(address(this), address(0x1234), 30e18);

        assertEq(bsc.balanceOf(address(0x1234)), 30e18);
        assertEq(bsc.allowance(address(this), address(0x1234)), 20e18);
    }
}
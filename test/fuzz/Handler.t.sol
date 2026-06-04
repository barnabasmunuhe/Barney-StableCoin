// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// Narrows down the way we call a function

import {Test} from "forge-std/Test.sol";
import {DeployBSC} from "../../script/DeployBSC.s.sol";
import {CoinEngine} from "../../src/CoinEngine.sol";
import {BarneyStableCoin} from "../../src/BarneyStableCoin.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

contract Handler is Test {
    CoinEngine engine;
    BarneyStableCoin bsc;

    ERC20Mock wEth;
    ERC20Mock wBtc;

    uint256 public timesMintIsCalled;
    address[] public usersWithCollateralDeposited;

    uint256 MAX_DEPOSIT_SIZE = type(uint96).max;

    constructor(CoinEngine _bscEngine, BarneyStableCoin _bsc) {
        engine = _bscEngine;
        bsc = _bsc;

        // getting full array of our allowed collaterals
        address[] memory collateralTokens = engine.getCollateralTokens();
        wEth = ERC20Mock(collateralTokens[0]);
        wBtc = ERC20Mock(collateralTokens[1]);
    }

    /**
     * @dev CAVEAT: Only Mint BSC with an address that has actually deposited collateral
     * -Its impossible for someone to mint coins without them depositing collateral
     */
    function mintBSC(uint256 amount, uint256 addressSeed) public {
        // msg.sender
        if (usersWithCollateralDeposited.length == 0) {
            return; // if no one has deposited collateral, we can't mint any bsc, so we just skip
        }
        address sender = usersWithCollateralDeposited[addressSeed % usersWithCollateralDeposited.length];
        (uint256 totalBscMinted, uint256 collateralValueInUsd) = engine.getAccountInformation(sender);
        int256 maxBSCToMint = (int256(collateralValueInUsd) / 2) - int256(totalBscMinted); //have them mint the max bsc they can mint, which is 50% of their collateral value in usd minus the amount of bsc they have already minted
        if (maxBSCToMint <= 0) {
            return; // we can't mint any more BSC, so we just return
        }
        amount = bound(amount, 0, uint256(maxBSCToMint));
        if (amount == 0) {
            return; // if the amount to mint is 0, we just return
        }
        vm.prank(sender);
        engine.mintBSC(amount);
        timesMintIsCalled++;
    }

    function depositCollateral(uint256 randomCollateral, uint256 amountCollateral) public {
        ERC20Mock collateral = _getCollateralFromRandomCollateral(randomCollateral);
        amountCollateral = bound(amountCollateral, 1, MAX_DEPOSIT_SIZE);

        vm.startPrank(msg.sender);
        collateral.mint(msg.sender, amountCollateral); //minting some collateral to the user so they can deposit it
        collateral.approve(address(engine), amountCollateral);
        engine.depositCollateral(address(collateral), amountCollateral);
        vm.stopPrank();
        // this will double push if the same address deposits twice
        // Check if someone has already deposited collateral
        usersWithCollateralDeposited.push(msg.sender);
    }

    function redeemCollateral(uint256 randomCollateral, uint256 amountCollateral) public {
        ERC20Mock collateral = _getCollateralFromRandomCollateral(randomCollateral);
        uint256 maxCollateralToRedeem = engine.getCollateralBalanceOfUser(address(collateral), msg.sender);
        if (maxCollateralToRedeem == 0) {
            return;
        }
        if (amountCollateral == 0) {
            return; // if the amount to redeem is 0, we just return
        }
        amountCollateral = bound(amountCollateral, 1, maxCollateralToRedeem);
        vm.prank(msg.sender);
        try engine.redeemCollateral(address(collateral), amountCollateral) {}
        catch {
            return;
        }
    }

    /*//////////////////////////////////////////////////////////////
                            HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    function _getCollateralFromRandomCollateral(uint256 randomCollateral) private view returns (ERC20Mock) {
        if (randomCollateral % 2 == 0) {
            return wEth;
        } else {
            return wBtc;
        }
    }
}

// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "forge-std/console.sol";
import "./utils/Helpers.sol";
import {Setup, ERC20, IStrategyInterface} from "./utils/Setup.sol";
import {Auction, AuctionFactory} from "@periphery/Auctions/AuctionFactory.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract OperationTest is Setup {
    Auction public auction;
    bytes32 public auctionId;

    function setUp() public virtual override {
        super.setUp();

        AuctionFactory auctionFactory = AuctionFactory(
            strategy.auctionFactory()
        );
        auction = Auction(
            auctionFactory.createNewAuction(strategy.asset(), address(strategy))
        );
        vm.prank(auction.governance());
        auctionId = auction.enable(strategy.AJNA_TOKEN(), address(strategy));
        auction.setHookFlags(false, true, false, false);
    }

    function test_auction(uint256 _amount) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);

        ERC20 ajnaToken = ERC20(strategy.AJNA_TOKEN());
        vm.prank(management);
        strategy.setAuction(address(auction));

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        // airdrop on strategy
        deal(address(ajnaToken), address(strategy), 500 ether);
        assertTrue(ajnaToken.balanceOf(address(strategy)) == 500 ether);

        // below minimum should revert
        vm.expectRevert();
        auction.kick(auctionId);

        deal(address(ajnaToken), address(strategy), 1000 ether);
        auction.kick(auctionId);

        // wait until the auction is 75% complete
        skip((auction.auctionLength() * 75) / 100);
        address buyer = address(62735);
        uint256 amountNeeded = auction.getAmountNeeded(auctionId, 1000 ether);

        deal(address(strategy.asset()), buyer, amountNeeded);

        vm.prank(buyer);
        asset.approve(address(auction), amountNeeded);

        // take the auction
        vm.prank(buyer);
        auction.take(auctionId);

        Helpers.logStrategyInfo(strategy);

        skip(strategy.profitMaxUnlockTime());

        // Report profit
        vm.prank(keeper);
        (uint256 profit, uint256 loss) = strategy.report();
        checkLTV(false);

        // Expect a loss
        assertGe(profit, 0, "!profit");
        assertEq(loss, 0, "!loss");

        uint256 balanceBefore = asset.balanceOf(user);

        // Withdraw all funds
        vm.prank(user);
        strategy.redeem(_amount, user, user);

        assertGe(
            asset.balanceOf(user),
            balanceBefore + _amount,
            "!final balance"
        );
    }
}

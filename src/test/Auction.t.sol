// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "forge-std/console.sol";
import "./utils/Helpers.sol";
import {Setup, ERC20, IStrategyInterface} from "./utils/Setup.sol";
import {Auction, AuctionFactory} from "@periphery/Auctions/AuctionFactory.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract AuctionTest is Setup {
    Auction public auction;
    bytes32 public auctionId;

    ERC20 ajnaToken = ERC20(0x9a96ec9B57Fb64FbC60B423d1f4da7691Bd35079);

    function setUp() public virtual override {
        super.setUp();

        AuctionFactory auctionFactory = AuctionFactory(
            strategy.auctionFactory()
        );
        auction = Auction(
            auctionFactory.createNewAuction(strategy.asset(), address(strategy))
        );
        vm.prank(auction.governance());
        auctionId = auction.enable(address(ajnaToken), address(strategy));
        auction.setHookFlags(true, true, false, false);

        setFees(0, 0); // set fees to 0 to make life easy
    }

    function test_auction() public {
        uint256 _amount = maxFuzzAmount;

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
        vm.prank(management);
        strategy.setDoHealthCheck(false);
        vm.prank(keeper);
        (uint256 profit, uint256 loss) = strategy.report();
        checkLTV(false);

        // Expect a loss
        assertGt(profit, 0, "!profit");
        assertEq(loss, 0, "!loss");

        skip(strategy.profitMaxUnlockTime());

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

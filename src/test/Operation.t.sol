// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "forge-std/console.sol";
import "./utils/Helpers.sol";
import {Setup, ERC20, IStrategyInterface} from "./utils/Setup.sol";

contract OperationTest is Setup {
    uint256 public constant REPORTING_PERIOD = 14 days;

    function setUp() public virtual override {
        super.setUp();
    }

    function test_setupStrategyOK() public {
        console.log("address of strategy", address(strategy));
        assertTrue(address(0) != address(strategy));
        assertEq(strategy.asset(), address(asset));
        assertEq(strategy.management(), management);
        assertEq(strategy.performanceFeeRecipient(), performanceFeeRecipient);
        assertEq(strategy.keeper(), keeper);
        // TODO: add additional check on strat params
    }

    function test_operation(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        // TODO: Implement logic so totalDebt is _amount and totalIdle = 0.
        assertEq(strategy.totalAssets(), _amount, "!totalAssets");
        assertEq(strategy.totalDebt(), 0, "!totalDebt");
        assertEq(strategy.totalIdle(), _amount, "!totalIdle");
        assertEq(strategy.estimatedTotalAssets(), _amount, "!eta");

        Helpers.logStrategyInfo(strategy);

        vm.prank(keeper);
        strategy.tend();

        assertEq(strategy.totalAssets(), _amount, "!totalAssets");
        assertEq(strategy.totalDebt(), _amount, "!totalDebt");
        assertEq(strategy.totalIdle(), 0, "!totalIdle");
        //assertLt(strategy.estimatedTotalAssets(), _amount, "!eta");

        Helpers.logStrategyInfo(strategy);

        // Lose money
        skip(1 days);

        Helpers.logStrategyInfo(strategy);

        // Report profit
        vm.prank(keeper);
        (uint256 profit, uint256 loss) = strategy.report();

        // Expect a loss
        assertEq(profit, 0, "!profit");
        assertGe(loss, 0, "!loss");

        Helpers.logStrategyInfo(strategy);

        skip(strategy.profitMaxUnlockTime());

        uint256 balanceBefore = asset.balanceOf(user);

        // Withdraw all funds
        vm.prank(user);
        strategy.redeem(_amount, user, user);

        // Expect a loss since no profit was created
        assertLe(
            asset.balanceOf(user),
            balanceBefore + _amount,
            "!final balance"
        );

        Helpers.logStrategyInfo(strategy);
    }

    function test_profitableOperation(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        // TODO: Implement logic so totalDebt is _amount and totalIdle = 0.
        assertEq(strategy.totalAssets(), _amount, "!totalAssets");
        assertEq(strategy.totalDebt(), 0, "!totalDebt");
        assertEq(strategy.totalIdle(), _amount, "!totalIdle");
        assertEq(strategy.estimatedTotalAssets(), _amount, "!eta");

        Helpers.logStrategyInfo(strategy);

        vm.prank(keeper);
        strategy.tend();

        assertEq(strategy.totalAssets(), _amount, "!totalAssets");
        assertEq(strategy.totalDebt(), _amount, "!totalDebt");
        assertEq(strategy.totalIdle(), 0, "!totalIdle");
        //assertLt(strategy.estimatedTotalAssets(), _amount, "!eta");

        Helpers.logStrategyInfo(strategy);

        // Make money
        uint256 _lstPrice = Helpers.generatePaperProfit(vm, strategy, REPORTING_PERIOD);
        Helpers.setUniswapPoolPrice(vm, strategy, _lstPrice);
        skip(REPORTING_PERIOD);

        Helpers.logStrategyInfo(strategy);

        // Report profit
        vm.prank(keeper);
        (uint256 profit, uint256 loss) = strategy.report();

        // Expect a loss
        assertGe(profit, 0, "!profit");
        assertEq(loss, 0, "!loss");

        Helpers.logStrategyInfo(strategy);

        skip(strategy.profitMaxUnlockTime());

        uint256 balanceBefore = asset.balanceOf(user);

        // Withdraw all funds
        vm.prank(user);
        strategy.redeem(_amount, user, user);

        // Expect a loss since no profit was created
        assertGe(
            asset.balanceOf(user),
            balanceBefore + _amount,
            "!final balance"
        );

        Helpers.logStrategyInfo(strategy);
    }

    function test_profitableReport(uint256 _amount, uint16 _profitFactor)
        public
    {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);
        _profitFactor = uint16(bound(uint256(_profitFactor), 10, MAX_BPS));

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        // tend to deploy funds
        vm.prank(keeper);
        strategy.tend();

        assertEq(strategy.totalAssets(), _amount, "!totalAssets");
        assertEq(strategy.totalDebt(), _amount, "!totalDebt");
        assertEq(strategy.totalIdle(), 0, "!totalIdle");

        // Make money
        uint256 _lstPrice = Helpers.generatePaperProfit(vm, strategy, REPORTING_PERIOD);
        Helpers.setUniswapPoolPrice(vm, strategy, _lstPrice);
        skip(REPORTING_PERIOD);

        // Report profit
        vm.prank(keeper);
        (uint256 profit, uint256 loss) = strategy.report();

        // Check return Values
        assertGe(profit, 0, "!profit");
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

    function test_profitableReport_withFees(
        uint256 _amount,
        uint16 _profitFactor
    ) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);
        _profitFactor = uint16(bound(uint256(_profitFactor), 10, MAX_BPS));

        // Set protocol fee to 0 and perf fee to 10%
        setFees(0, 1_000);

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        // tend to deploy funds
        vm.prank(keeper);
        strategy.tend();

        assertEq(strategy.totalAssets(), _amount, "!totalAssets");
        assertEq(strategy.totalDebt(), _amount, "!totalDebt");
        assertEq(strategy.totalIdle(), 0, "!totalIdle");

        // Make money
        uint256 _lstPrice = Helpers.generatePaperProfit(vm, strategy, REPORTING_PERIOD);
        Helpers.setUniswapPoolPrice(vm, strategy, _lstPrice);
        skip(REPORTING_PERIOD);

        // Report profit
        vm.prank(keeper);
        (uint256 profit, uint256 loss) = strategy.report();

        // Check return Values
        assertGe(profit, 0, "!profit");
        assertEq(loss, 0, "!loss");

        skip(strategy.profitMaxUnlockTime());

        // Get the expected fee
        uint256 expectedShares = (profit * 1_000) / MAX_BPS;

        assertEq(strategy.balanceOf(performanceFeeRecipient), expectedShares);

        uint256 balanceBefore = asset.balanceOf(user);

        // Withdraw all funds
        vm.prank(user);
        strategy.redeem(_amount, user, user);

        assertGe(
            asset.balanceOf(user),
            balanceBefore + _amount,
            "!final balance"
        );

        vm.prank(performanceFeeRecipient);
        strategy.redeem(
            expectedShares,
            performanceFeeRecipient,
            performanceFeeRecipient
        );

        checkStrategyTotals(strategy, 0, 0, 0);

        assertGe(
            asset.balanceOf(performanceFeeRecipient),
            expectedShares,
            "!perf fee out"
        );
    }

    function test_tendTrigger(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        (bool trigger, ) = strategy.tendTrigger();
        assertTrue(!trigger);

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        (trigger, ) = strategy.tendTrigger();
        assertTrue(!trigger);

        // Skip some time
        skip(1 days);

        (trigger, ) = strategy.tendTrigger();
        assertTrue(!trigger);

        vm.prank(keeper);
        strategy.report();

        (trigger, ) = strategy.tendTrigger();
        assertTrue(!trigger);

        // Unlock Profits
        skip(strategy.profitMaxUnlockTime());

        (trigger, ) = strategy.tendTrigger();
        assertTrue(!trigger);

        vm.prank(user);
        strategy.redeem(_amount, user, user);

        (trigger, ) = strategy.tendTrigger();
        assertTrue(!trigger);
    }
}

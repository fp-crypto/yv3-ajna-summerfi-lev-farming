// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "forge-std/console.sol";
import "./utils/Helpers.sol";
import {Setup, ERC20, IStrategyInterface} from "./utils/Setup.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract OperationTest is Setup {
    uint256 public constant REPORTING_PERIOD = 30 days;

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
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        // TODO: Implement logic so totalDebt is _amount and totalIdle = 0.
        checkStrategyTotals(strategy, _amount, 0, _amount);
        assertEq(strategy.estimatedTotalAssets(), _amount, "!eta");

        Helpers.logStrategyInfo(strategy);

        vm.prank(keeper);
        strategy.tend();
        checkLTV(false);

        checkStrategyTotals(strategy, _amount, _amount, 0);
        //assertLt(strategy.estimatedTotalAssets(), _amount, "!eta");

        Helpers.logStrategyInfo(strategy);

        // Lose money
        skip(1 days);

        Helpers.logStrategyInfo(strategy);

        // Report profit
        vm.prank(keeper);
        (uint256 profit, uint256 loss) = strategy.report();
        checkLTV(false);

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

    function test_profitableReport(uint256 _amount) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        // TODO: Implement logic so totalDebt is _amount and totalIdle = 0.
        checkStrategyTotals(strategy, _amount, 0, _amount);
        assertEq(strategy.estimatedTotalAssets(), _amount, "!eta");

        Helpers.logStrategyInfo(strategy);

        vm.prank(keeper);
        strategy.tend();
        checkLTV(false);

        checkStrategyTotals(strategy, _amount, _amount, 0);
        //assertLt(strategy.estimatedTotalAssets(), _amount, "!eta");

        Helpers.logStrategyInfo(strategy);

        // Make money
        uint256 _lstPrice = Helpers.generatePaperProfit(
            vm,
            strategy,
            REPORTING_PERIOD
        );
        Helpers.setUniswapPoolPrice(vm, strategy, _lstPrice);
        skip(REPORTING_PERIOD);

        Helpers.logStrategyInfo(strategy);

        // Report profit
        vm.prank(keeper);
        (uint256 profit, uint256 loss) = strategy.report();
        checkLTV(false);

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

    function test_withdrawSubset_profit(
        uint64 _depositAmount,
        uint64 _withdrawAmount,
        bool profit
    ) public {
        vm.assume(
            _depositAmount > minFuzzAmount && _depositAmount < maxFuzzAmount
        );
        vm.assume(_depositAmount > _withdrawAmount && _withdrawAmount > 0);

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _depositAmount);

        // tend to deploy funds
        vm.prank(keeper);
        strategy.tend();
        checkLTV(false);

        checkStrategyTotals(strategy, _depositAmount, _depositAmount, 0);

        if (profit) {
            // Make money
            uint256 _lstPrice = Helpers.generatePaperProfit(
                vm,
                strategy,
                REPORTING_PERIOD
            );
            Helpers.setUniswapPoolPrice(vm, strategy, _lstPrice);
            skip(REPORTING_PERIOD);
        }

        uint256 balanceBefore = asset.balanceOf(user);
        uint256 totalAssetsBefore = Math.min(
            strategy.estimatedTotalAssets(),
            strategy.totalAssets()
        );

        assertEq(
            totalAssetsBefore,
            profit ? strategy.totalAssets() : strategy.estimatedTotalAssets()
        );

        // Withdraw all funds
        vm.prank(user);
        strategy.redeem(_withdrawAmount, user, user);
        checkLTV();

        assertLe(
            asset.balanceOf(user),
            balanceBefore + _withdrawAmount,
            "!final balance"
        );

        uint256 targetRatio = (uint256(_withdrawAmount) * 1e4) /
            _depositAmount;
        uint256 actualRatio = ((asset.balanceOf(user) - balanceBefore) * 1e4) /
            totalAssetsBefore;

        assertApproxEq(
            actualRatio,
            targetRatio,
            30, // bp
            "!ratio"
        );
    }

    function test_ltvChanges(uint64 _ltv) public {
        uint256 _amount = 20e18;
        vm.assume(
            _ltv <= 0.9e18 &&
                _ltv >= 0.4e18 &&
                Helpers.abs(int64(strategy.ltvs().targetLTV) - int64(_ltv)) >
                strategy.ltvs().minAdjustThreshold
        ); // max ltv 90% and change must be more than the minimum adjustment threshold

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        // TODO: Implement logic so totalDebt is _amount and totalIdle = 0.
        checkStrategyTotals(strategy, _amount, 0, _amount);
        assertEq(strategy.estimatedTotalAssets(), _amount, "!eta");

        vm.prank(keeper);
        strategy.tend();
        Helpers.logStrategyInfo(strategy);
        checkLTV(false);
        checkStrategyTotals(strategy, _amount, _amount, 0);

        // Lose money
        skip(1 days);

        IStrategyInterface.LTVConfig memory _newLtvConfig = strategy.ltvs();
        _newLtvConfig.targetLTV = _ltv;
        vm.prank(management);
        strategy.setLtvConfig(_newLtvConfig);

        // Tend to new LTV
        vm.prank(keeper);
        strategy.tend();
        Helpers.logStrategyInfo(strategy);
        checkLTV(false);
        checkStrategyTotals(strategy, _amount, _amount, 0);
    }

    // TODO: tend trigger on LTV
    function test_tendTrigger(uint256 _amount) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);

        return;

        (bool trigger, ) = strategy.tendTrigger();
        assertFalse(trigger); // trigger should be false as position isn't open

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        (trigger, ) = strategy.tendTrigger();
        assertTrue(trigger); // there are funds

        return;

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

    function checkLTV() internal {
        checkLTV(true);
    }

    function checkLTV(bool canBeZero) internal {
        if (canBeZero && strategy.currentLTV() == 0) return;
        assertApproxEq(
            strategy.currentLTV(),
            strategy.ltvs().targetLTV,
            strategy.ltvs().minAdjustThreshold,
            "!ltv"
        );
    }
}

// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "forge-std/console.sol";
import "./utils/Helpers.sol";
import {Setup, ERC20, IStrategyInterface} from "./utils/Setup.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract OperationTest is Setup {
    using Helpers for IStrategyInterface;

    function setUp() public virtual override {
        super.setUp();
    }

    function test_manualLeverDown_targetLTV(uint256 _amount, uint64 _targetLTV)
        public
    {
        vm.prank(management);
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);
        _targetLTV = uint64(bound(_amount, 0, 0.80e18));

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

        Helpers.logStrategyInfo(strategy);

        // Lose money
        skip(1 days);
        Helpers.logStrategyInfo(strategy);

        vm.prank(management);
        strategy.manualLeverDown(0, _targetLTV, false);
        Helpers.logStrategyInfo(strategy);
        checkLTV(_targetLTV);

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

    function test_manualLeverDown_toLoose(uint256 _amount, uint256 _toLoose)
        public
    {
        vm.prank(management);
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

        Helpers.logStrategyInfo(strategy);

        // Lose money
        skip(1 days);
        Helpers.logStrategyInfo(strategy);


        uint64 _targetLTV = strategy.ltvs().targetLTV;
        _toLoose = bound(_amount, 0.0001e18, strategy.estimatedTotalAssets());

        // manual lever down
        vm.prank(management);
        strategy.manualLeverDown(_toLoose, _targetLTV, false);

        Helpers.logStrategyInfo(strategy);
        checkLTV(_targetLTV);
        assertApproxEq(_toLoose, _toLoose, 0.0001e18);

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


    function test_manualLeverDown_both(uint256 _amount, uint64 _targetLTV, uint256 _toLoose)
        public
    {
        vm.prank(management);
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);
        _targetLTV = uint64(bound(_amount, 0, 0.80e18));

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

        Helpers.logStrategyInfo(strategy);

        // Lose money
        skip(1 days);
        Helpers.logStrategyInfo(strategy);


        _toLoose = bound(_amount, 0.0001e18, strategy.estimatedTotalAssets());

        // manual lever down
        vm.prank(management);
        strategy.manualLeverDown(_toLoose, _targetLTV, false);

        Helpers.logStrategyInfo(strategy);
        checkLTV(_targetLTV);
        assertApproxEq(_toLoose, _toLoose, 0.0001e18);

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
}

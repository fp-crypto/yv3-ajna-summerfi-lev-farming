// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "forge-std/console.sol";
import "./utils/Helpers.sol";
import {Setup, ERC20, IStrategyInterface} from "./utils/Setup.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract TendTriggerTest is Setup {
    uint256 public constant REPORTING_PERIOD = 60 days;

    function setUp() public virtual override {
        super.setUp();
    }

    function test_tendTrigger(uint256 _amount) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);

        (bool trigger, ) = strategy.tendTrigger();
        assertFalse(trigger); // trigger should be false as position isn't open

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        (trigger, ) = strategy.tendTrigger();
        assertFalse(trigger); // tend will never be true due to loose funds

        vm.prank(keeper);
        strategy.tend();
        assertTrue(strategy.positionOpen());
        checkLTV(false);

        // Skip some time
        skip(1 days);

        Helpers.logStrategyInfo(strategy);

        (trigger, ) = strategy.tendTrigger();
        assertFalse(trigger);

        // Skip some time
        skip(1 days);
        Helpers.generatePaperProfitOrLoss(vm, strategy, -200);
        Helpers.logStrategyInfo(strategy);

        // False due to fee too high
        vm.fee(strategy.maxTendBasefee() + 1);
        (trigger, ) = strategy.tendTrigger();
        assertFalse(trigger);

        // True due to fee below max
        vm.fee(strategy.maxTendBasefee() - 1);
        (trigger, ) = strategy.tendTrigger();
        assertTrue(trigger);

        skip(1 days);
        Helpers.generatePaperProfitOrLoss(vm, strategy, -200);
        Helpers.logStrategyInfo(strategy);

        // True because LTV is above emergency threshold
        vm.fee(strategy.maxTendBasefee() + 1);
        (trigger, ) = strategy.tendTrigger();
        assertTrue(trigger);

        vm.prank(keeper);
        strategy.tend();
        checkLTV(false);

        vm.fee(strategy.maxTendBasefee() - 1);
        (trigger, ) = strategy.tendTrigger();
        assertFalse(trigger);

        // Unlock Profits
        skip(strategy.profitMaxUnlockTime());

        (trigger, ) = strategy.tendTrigger();
        assertFalse(trigger);

        // Skip some time
        skip(1 days);
        Helpers.generatePaperProfitOrLoss(vm, strategy, 200);
        Helpers.logStrategyInfo(strategy);

        // LTV should be below min threshold
        (trigger, ) = strategy.tendTrigger();
        assertTrue(trigger);

        vm.prank(user);
        strategy.redeem(_amount, user, user);

        (trigger, ) = strategy.tendTrigger();
        assertTrue(!trigger);
    }
}

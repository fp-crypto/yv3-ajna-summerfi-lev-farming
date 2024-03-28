// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "forge-std/console.sol";
import "./utils/Helpers.sol";
import {Setup, ERC20, IStrategyInterface} from "./utils/Setup.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract OperationTest is Setup {
    using Helpers for IStrategyInterface;

    uint256 public constant REPORTING_PERIOD = 60 days;

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
        
        // allow loss
        vm.prank(management);
        strategy.setDoHealthCheck(false);
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
        setFees(0, 0); // set fees to 0 to make life easy

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
        uint256 _lstPrice = Helpers.generatePaperProfitOrLoss(
            vm,
            strategy,
            100
        );
        Helpers.setUniswapPoolPrice(vm, strategy, _lstPrice);
        skip(REPORTING_PERIOD);

        Helpers.logStrategyInfo(strategy);

        vm.prank(management);
        strategy.setDoHealthCheck(false);

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

        assertGe(
            asset.balanceOf(user),
            balanceBefore + _amount,
            "!final balance"
        );
        assertFalse(strategy.positionOpen());

        Helpers.logStrategyInfo(strategy);
    }

    function test_withdrawSubset(
        uint64 _depositAmount,
        uint64 _withdrawAmount,
        bool profit
    ) public {
        vm.assume(
            _depositAmount > minFuzzAmount && _depositAmount < maxFuzzAmount
        );
        vm.assume(
            _depositAmount > _withdrawAmount && _withdrawAmount >= 0.025e18
        );

        vm.prank(management);
        strategy.setSlippageAllowedBps(100);

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
            strategy.estimatedTotalAssetsNoSlippage(),
            strategy.totalAssets()
        );

        // Withdraw some funds
        vm.prank(user);
        strategy.redeem(_withdrawAmount, user, user);
        checkLTV(true, true);

        assertLe(
            asset.balanceOf(user),
            balanceBefore + _withdrawAmount,
            "!final balance"
        );

        uint256 targetRatio = (uint256(_withdrawAmount) * 1e4) / _depositAmount;
        uint256 actualRatio = ((asset.balanceOf(user) - balanceBefore) * 1e4) /
            totalAssetsBefore;

        // TODO: tighter range
        if (profit) {
            assertLe(actualRatio, targetRatio, "!ratio");
        } else {
            assertApproxEq(
                actualRatio,
                targetRatio,
                100, // bp
                "!ratio"
            );
        }

        balanceBefore = asset.balanceOf(user);
        uint256 redeemAmount = strategy.balanceOf(user);
        console.log("redeemAmount: %s", redeemAmount);
        vm.prank(user);
        strategy.redeem(redeemAmount, user, user);

        if (profit) {
            assertGe(
                (asset.balanceOf(user) *
                    (1e4 + strategy.slippageAllowedBps() * 2)) / 1e4,
                balanceBefore + (_depositAmount - _withdrawAmount),
                "!final balance"
            );
        }
    }

    function test_ltvChanges(uint64 _startingLtv, uint64 _endingLtv) public {
        _startingLtv = uint64(bound(_startingLtv, 0.4e18, 0.70e18)); // max ltv 70%
        _endingLtv = uint64(bound(_endingLtv, 0.4e18, 0.70e18)); // max ltv 70%
        vm.assume(
            Helpers.abs(int64(strategy.ltvs().targetLTV) - int64(_endingLtv)) >
                strategy.ltvs().minAdjustThreshold
        ); // change must be more than the minimum adjustment threshold

        uint256 _amount = 20e18;

        IStrategyInterface.LTVConfig memory _newLtvConfig = strategy.ltvs();
        _newLtvConfig.targetLTV = _startingLtv;
        vm.prank(management);
        strategy.setLtvConfig(_newLtvConfig);

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

        _newLtvConfig.targetLTV = _endingLtv;
        vm.prank(management);
        strategy.setLtvConfig(_newLtvConfig);

        // Tend to new LTV
        vm.prank(keeper);
        strategy.tend();
        Helpers.logStrategyInfo(strategy);
        checkLTV(false);
        checkStrategyTotals(strategy, _amount, _amount, 0);
    }

    function test_ltvToZero(uint64 _startingLtv) public {
        _startingLtv = uint64(bound(_startingLtv, 0.4e18, 0.7e18)); // max ltv 70%
        uint64 _endingLtv = 0; 

        vm.assume(
            Helpers.abs(int64(strategy.ltvs().targetLTV) - int64(_endingLtv)) >
                strategy.ltvs().minAdjustThreshold
        ); // change must be more than the minimum adjustment threshold

        uint256 _amount = 20e18;

        IStrategyInterface.LTVConfig memory _newLtvConfig = strategy.ltvs();
        _newLtvConfig.targetLTV = _startingLtv;
        vm.prank(management);
        strategy.setLtvConfig(_newLtvConfig);

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

        _newLtvConfig.targetLTV = _endingLtv;
        vm.prank(management);
        strategy.setLtvConfig(_newLtvConfig);

        // Tend to new LTV
        vm.prank(keeper);
        strategy.tend();
        Helpers.logStrategyInfo(strategy);
        checkLTV(false);
        assertEq(strategy.totalIdle(), strategy.estimatedTotalAssetsNoSlippage());
 
        // allow loss
        vm.prank(management);
        strategy.setDoHealthCheck(false);   
        vm.prank(keeper);
        strategy.report();
        assertEq(strategy.totalIdle(), strategy.totalAssets());
    }
}

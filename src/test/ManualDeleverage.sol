// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "forge-std/console.sol";
import "./utils/Helpers.sol";
import {Setup, ERC20, IStrategyInterface} from "./utils/Setup.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20Pool} from "@ajna-core/interfaces/pool/erc20/IERC20Pool.sol";

contract ManualDeleverageTest is Setup {
    using Helpers for IStrategyInterface;

    function setUp() public virtual override {
        super.setUp();
    }

    function test_manualLeverDown_targetLTV(
        uint256 _amount,
        uint64 _targetLTV
    ) public {
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

    function test_manualLeverDown_toLoose(
        uint256 _amount,
        uint256 _toLoose
    ) public {
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

    function test_manualLeverDown_both(
        uint256 _amount,
        uint64 _targetLTV,
        uint256 _toLoose
    ) public {
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

    function test_manualLeverDown_force(
        uint64 _targetLTV,
        uint256 _toLoose
    ) public {
        uint256 _amount = maxFuzzAmount;
        _targetLTV = uint64(bound(_amount, 0, 0.50e18));

        IStrategyInterface.LTVConfig memory _newLtvConfig = strategy.ltvs();
        _newLtvConfig.targetLTV = _targetLTV;
        vm.prank(management);
        strategy.setLtvConfig(_newLtvConfig);

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

        _toLoose = bound(
            _amount,
            _amount / 10,
            strategy.estimatedTotalAssets()
        );

        // manual lever down
        vm.prank(management);
        strategy.manualLeverDown(_toLoose, 0.85e18, true);

        Helpers.logStrategyInfo(strategy);
        checkLTV(false, true, 0.85e18);
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

    function test_manualLeverDown_fullyManual() public {
        uint256 _amount = maxFuzzAmount * 2;

        IStrategyInterface.LTVConfig memory _newLtvConfig = strategy.ltvs();
        _newLtvConfig.targetLTV = 0.70e18;
        vm.prank(management);
        strategy.setLtvConfig(_newLtvConfig);

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

        (uint256 _debt, uint256 _collateral, , ) = strategy.positionInfo();

        uint256 _price = 0.88e18; // assume price for simplicity

        ERC20 weth = ERC20(tokenAddrs["WETH"]);

        // manual lever down
        vm.startPrank(management);
        for (uint8 i; _debt > 100 && i < 15; ++i) {
            console.log();
            console.log("==== Loop %s ====", i);
            uint256 _repayAmount = Math.min(
                weth.balanceOf(address(strategy)),
                _debt
            );
            if (
                _repayAmount != _debt && _debt - _repayAmount < _minLoanSize()
            ) {
                // we need a donation to exit via this path
                console.log("donating weth, %s", _debt - _repayAmount);
                deal(address(weth), address(strategy), _debt);
                _repayAmount = _debt;
            }
            uint256 _targetCollateral = ((_debt - _repayAmount) * _price) /
                0.85e18;
            uint256 _amountToWithdraw = Math.min(
                _collateral - _targetCollateral,
                _collateral
            );
            if (_repayAmount + _amountToWithdraw < 0.00001e18) {
                break;
            }
            Helpers.logStrategyInfo(strategy);
            console.log("Weth: %s", weth.balanceOf(address(strategy)));
            strategy.manualRepayWithdraw(
                _repayAmount,
                _amountToWithdraw,
                false
            );
            (_debt, _collateral, , ) = strategy.positionInfo();

            if (_debt != 0) strategy.manualSwap(strategy.totalIdle(), 0, true);

            (_debt, _collateral, , ) = strategy.positionInfo();
        }
        vm.stopPrank();
        Helpers.logStrategyInfo(strategy);
        console.log("Weth: %s", weth.balanceOf(address(strategy)));
        /*
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

        Helpers.logStrategyInfo(strategy);*/
    }

    function _minLoanSize() internal view returns (uint256 _minDebtAmount) {
        IERC20Pool _ajnaPool = IERC20Pool(strategy.ajnaPool());
        (uint256 _poolDebt, , , ) = _ajnaPool.debtInfo();
        (, , uint256 _noOfLoans) = _ajnaPool.loansInfo();

        if (_noOfLoans != 0) {
            // minimum debt is 10% of the average loan size
            _minDebtAmount = (_poolDebt / _noOfLoans) / 10;
        }
    }
}

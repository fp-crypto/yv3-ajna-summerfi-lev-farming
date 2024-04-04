pragma solidity ^0.8.18;

import "forge-std/console.sol";
import {Setup} from "./utils/Setup.sol";

import {StrategyAprOracle} from "../periphery/StrategyAprOracle.sol";

contract OracleTest is Setup {
    StrategyAprOracle public oracle;

    function setUp() public override {
        super.setUp();
        vm.prank(management);
        oracle = new StrategyAprOracle();
        vm.prank(management);
        oracle.setLstApr(address(asset), 0.0325e18);
    }

    function checkOracle(address _strategy, uint256 _delta) public {
        // Check set up
        // TODO: Add checks for the setup

        uint256 currentApr = oracle.aprAfterDebtChange(_strategy, 0);
        console.log("APR: %e", currentApr);

        // Should be greater than 0 but likely less than 100%
        assertGt(currentApr, 0, "ZERO");
        assertLt(currentApr, 1e18, "+100%");

        uint256 negativeDebtChangeApr = oracle.aprAfterDebtChange(
            _strategy,
            -int256(_delta)
        );

        // The apr should go up if deposits go down
        assertEq(currentApr, negativeDebtChangeApr, "negative change");

        uint256 positiveDebtChangeApr = oracle.aprAfterDebtChange(
            _strategy,
            int256(_delta)
        );

        assertEq(currentApr, positiveDebtChangeApr, "positive change");

        uint64 _newLstApr = 0.05e18;
        address _asset = address(asset);
        vm.expectRevert("!governance");
        vm.prank(user);
        oracle.setLstApr(_asset, _newLstApr);

        vm.prank(management);
        oracle.setLstApr(_asset, _newLstApr);
        assertEq(oracle.lstApr(_asset), _newLstApr);

        uint256 higherLstApr = oracle.aprAfterDebtChange(
            _strategy,
            0
        );

        assertLt(currentApr, higherLstApr, "higher Apr");

        _newLstApr = 0.02e18;
        vm.prank(management);
        oracle.setLstApr(_asset, _newLstApr);
        assertEq(oracle.lstApr(_asset), _newLstApr);

        uint256 lowerLstApr = oracle.aprAfterDebtChange(
            _strategy,
            0
        );

        assertGt(currentApr, lowerLstApr, "lower Apr");

        bool _useUniswapTwap = true;
        vm.expectRevert("!governance");
        vm.prank(user);
        oracle.setUseUniswapTwap(_asset, _useUniswapTwap);

        vm.prank(management);
        oracle.setUseUniswapTwap(_asset, _useUniswapTwap);
        assertEq(oracle.useUniswapTwap(_asset), _useUniswapTwap);
    }

    function test_oracle(uint256 _amount, uint16 _percentChange) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);
        _percentChange = uint16(bound(uint256(_percentChange), 10, MAX_BPS));

        mintAndDepositIntoStrategy(strategy, user, _amount);
        vm.prank(keeper);
        strategy.tend();

        uint256 _delta = (_amount * _percentChange) / MAX_BPS;

        checkOracle(address(strategy), _delta);
    }
}

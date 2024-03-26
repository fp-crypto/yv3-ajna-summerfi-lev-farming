// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "forge-std/console.sol";
import "./utils/Helpers.sol";
import {Setup, ERC20, IStrategyInterface} from "./utils/Setup.sol";
import {IERC20Pool} from "@ajna-core/interfaces/pool/erc20/IERC20Pool.sol";
import {PoolInfoUtils} from "@ajna-core/PoolInfoUtils.sol";

contract LiquidationTest is Setup {
    PoolInfoUtils private constant POOL_INFO_UTILS =
        PoolInfoUtils(0x30c5eF2997d6a882DE52c4ec01B6D0a5e5B4fAAE);
    ERC20 public constant weth =
        ERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

    function setUp() public virtual override {
        super.setUp();
    }

    // borrowed from: https://gist.github.com/poolpitako/b5d100cf96de2b93f4de1aa2c886a3d8
    function test_liquidation_total() public {
        uint256 _amount = 2e18;
        IERC20Pool ajnaPool = IERC20Pool(strategy.ajnaPool());
        uint256 lenderBucket = POOL_INFO_UTILS.hpbIndex(address(ajnaPool)) - 1;
        address borrower = strategy.summerfiAccount();

        IStrategyInterface.LTVConfig memory _newLtvConfig = strategy.ltvs();
        _newLtvConfig.targetLTV = 0.914e18;
        vm.prank(management);
        strategy.setLtvConfig(_newLtvConfig);

        supplyQuote(
            (_amount * 1e18) / (1e18 - _newLtvConfig.targetLTV),
            address(ajnaPool),
            lenderBucket
        );

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        vm.prank(keeper);
        strategy.tend();
        assertTrue(strategy.positionOpen());
        checkLTV(false);

        Helpers.logStrategyInfo(strategy);
        skip(60 * 60 * 24 * 365);

        address liquidator = address(7190164707);
        deal(address(weth), liquidator, 100e18);

        vm.startPrank(liquidator);
        weth.approve(address(ajnaPool), 100e18);
        ajnaPool.kick(strategy.summerfiAccount(), 7388);

        auctionStatus(address(ajnaPool), borrower);

        skip((60 * 60 * 775) / 100);

        auctionStatus(address(ajnaPool), borrower);

        ajnaPool.take(borrower, 2**256 - 1, liquidator, "");
        vm.stopPrank();

        Helpers.logStrategyInfo(strategy);
        vm.prank(management);
        strategy.setDoHealthCheck(false);
        vm.prank(keeper);
        strategy.report();
        Helpers.logStrategyInfo(strategy);
    }

    // borrowed from: https://gist.github.com/poolpitako/b5d100cf96de2b93f4de1aa2c886a3d8
    function test_liquidation_partial() public {
        uint256 _amount = 2e18;
        IERC20Pool ajnaPool = IERC20Pool(strategy.ajnaPool());
        uint256 lenderBucket = POOL_INFO_UTILS.hpbIndex(address(ajnaPool)) - 1;
        address borrower = strategy.summerfiAccount();

        IStrategyInterface.LTVConfig memory _newLtvConfig = strategy.ltvs();
        _newLtvConfig.targetLTV = 0.914e18;
        vm.prank(management);
        strategy.setLtvConfig(_newLtvConfig);

        supplyQuote(
            (_amount * 1e18) / (1e18 - _newLtvConfig.targetLTV),
            address(ajnaPool),
            lenderBucket
        );

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        vm.prank(keeper);
        strategy.tend();
        assertTrue(strategy.positionOpen());
        checkLTV(false);

        Helpers.logStrategyInfo(strategy);
        skip(60 * 60 * 24 * 365);

        address liquidator = address(7190164707);
        deal(address(weth), liquidator, 100e18);

        vm.startPrank(liquidator);
        weth.approve(address(ajnaPool), 100e18);
        ajnaPool.kick(strategy.summerfiAccount(), 7388);

        auctionStatus(address(ajnaPool), borrower);

        skip((60 * 60 * 200) / 100);

        auctionStatus(address(ajnaPool), borrower);

        ajnaPool.take(borrower, 2**256 - 1, liquidator, "");
        vm.stopPrank();

        Helpers.logStrategyInfo(strategy);
        _newLtvConfig.targetLTV = 0.85e18;
        vm.prank(management);
        strategy.setLtvConfig(_newLtvConfig);
        vm.prank(management);
        strategy.setDoHealthCheck(false);
        vm.prank(keeper);
        strategy.report();
        Helpers.logStrategyInfo(strategy);
    }

    function auctionStatus(address ajnaPool, address borrower) internal view {
        (
            uint256 kickTime_,
            uint256 collateral_,
            uint256 debtToCover_,
            bool isCollateralized_,
            uint256 price_,
            uint256 neutralPrice_,
            uint256 referencePrice_,
            uint256 debtToCollateral_,
            uint256 bondFactor_
        ) = POOL_INFO_UTILS.auctionStatus(ajnaPool, borrower);

        console.log();
        console.log("==== Auction Status ====");
        console.log("kickTime: %s", kickTime_);
        console.log("collateral: %s", collateral_);
        console.log("debtToCover: %s", debtToCover_);
        console.log("isCollateralized: %s", isCollateralized_);
        console.log("price: %s", price_);
        console.log("neutralPrice: %s", neutralPrice_);
        console.log("referencePrice: %s", referencePrice_);
        console.log("debtToCollateral: %s", debtToCollateral_);
    }
}

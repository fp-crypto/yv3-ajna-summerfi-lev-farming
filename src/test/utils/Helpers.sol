// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {IStrategyInterface} from "../../interfaces/IStrategyInterface.sol";
import {IChainlinkAggregator} from "../../interfaces/chainlink/IChainlinkAggregator.sol";
import {Vm} from "forge-std/Test.sol";
import {ISwapRouter} from "@periphery/interfaces/Uniswap/V3/ISwapRouter.sol";
import {IUniswapV3Pool} from "@uniswap-v3-core/interfaces/IUniswapV3Pool.sol";
import {ERC20} from "@tokenized-strategy/BaseStrategy.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IWETH} from "../../interfaces/IWeth.sol";
import "forge-std/console.sol";

library Helpers {
    uint256 internal constant SECONDS_PER_YEAR = 31_536_000;
    uint256 internal constant MAX_BPS = 10_000;
    uint256 internal constant ONE_WAD = 1e18;
    uint256 internal constant LST_YIELD_PER_YEAR_BPS = 1_000;
    uint256 internal constant MAX_SWAP_AMOUNT = 100_000e18;

    address internal constant RANDO = address(3287043278);

    function logStrategyInfo(IStrategyInterface strategy) internal view {
        (uint256 _debt, uint256 _collateral, , ) = strategy.positionInfo();
        console.log("\n");
        console.log("==== Strategy Info ====");
        console.log("Debt: %i", _debt);
        console.log("Collateral: %i", _collateral);
        console.log(
            "LTV (actual/target): %s/%s",
            strategy.currentLTV(),
            strategy.ltvs().targetLTV
        );
        console.log("ETA: %i", strategy.estimatedTotalAssets());
        console.log("Total Assets: %i", strategy.totalAssets());
        console.log("Total Debt: %i", totalDebt(strategy));
        console.log("Total Idle: %i", totalIdle(strategy));
    }

    function generatePaperProfit(
        Vm vm,
        IStrategyInterface strategy,
        uint256 time
    ) internal returns (uint256 _lstValue) {
        return
            generatePaperProfitOrLoss(
                vm,
                strategy,
                int256((LST_YIELD_PER_YEAR_BPS * time) / SECONDS_PER_YEAR)
            );
    }

    function generatePaperProfitOrLoss(
        Vm vm,
        IStrategyInterface strategy,
        int256 pnlBps
    ) internal returns (uint256 _lstValue) {
        IChainlinkAggregator oracle = IChainlinkAggregator(
            strategy.chainlinkOracle()
        );

        _lstValue =
            (uint256(oracle.latestAnswer()) *
                uint256(int256(MAX_BPS) + pnlBps)) /
            MAX_BPS;

        vm.mockCall(
            address(oracle),
            abi.encodeWithSelector(oracle.latestAnswer.selector),
            abi.encode(_lstValue)
        );
    }

    function setUniswapPoolPrice(
        Vm vm,
        IStrategyInterface strategy,
        uint256 _lstValue
    ) internal {
        ISwapRouter router = ISwapRouter(
            0xE592427A0AEce92De3Edee1F18E0157C05861564
        );
        address weth = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
        address asset = strategy.asset();

        (, bytes memory data) = address(asset).staticcall(
            abi.encodeWithSelector(bytes4(0xb0e38900), (ONE_WAD**2) / _lstValue)
        );
        _lstValue = (ONE_WAD**2) / abi.decode(data, (uint256));

        uint160 sqrtPriceLimitX96 = uint160(
            (Math.sqrt(_lstValue * ONE_WAD) * 2**96) / ONE_WAD
        );
        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter
            .ExactInputSingleParams(
                weth, // tokenIn
                asset, // tokenOut
                IUniswapV3Pool(strategy.uniswapPool()).fee(), // from-to fee
                address(this), // recipient
                block.timestamp, // deadline
                MAX_SWAP_AMOUNT, // amountIn
                0, // amountOut
                sqrtPriceLimitX96 // sqrtPriceLimitX96
            );

        vm.deal(RANDO, MAX_SWAP_AMOUNT);
        vm.startPrank(RANDO);
        IWETH(weth).deposit{value: MAX_SWAP_AMOUNT}();
        uint256 wethBefore = ERC20(weth).balanceOf(RANDO);
        ERC20(weth).approve(address(router), MAX_SWAP_AMOUNT);
        ISwapRouter(router).exactInputSingle(params);
        uint256 wethAfter = ERC20(weth).balanceOf(RANDO);
        vm.stopPrank();
        require(wethBefore - wethAfter <= MAX_SWAP_AMOUNT, "!not enough input");
    }

    function abs(int256 x) internal pure returns (uint256) {
        return uint256(x >= 0 ? x : -x);
    }

    function totalIdle(IStrategyInterface _strategy)
        internal
        view
        returns (uint256)
    {
        return ERC20(_strategy.asset()).balanceOf(address(_strategy));
    }

    function totalDebt(IStrategyInterface _strategy)
        internal
        view
        returns (uint256)
    {
        uint256 _totalIdle = totalIdle(_strategy);
        uint256 _totalAssets = _strategy.totalAssets();
        if (_totalIdle >= _totalAssets) return 0;
        return _totalAssets - _totalIdle;
    }
}

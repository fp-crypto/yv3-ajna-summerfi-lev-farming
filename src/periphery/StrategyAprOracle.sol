// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {AprOracleBase} from "@periphery/AprOracle/AprOracleBase.sol";
import {IStrategyInterface} from "../interfaces/IStrategyInterface.sol";

import {IUniswapV3Pool} from "@uniswap-v3-core/interfaces/IUniswapV3Pool.sol";
import {TickMath} from "@uniswap-v3-core/libraries/TickMath.sol";
import {OracleLibrary} from "@uniswap-v3-periphery/libraries/OracleLibrary.sol";
import {IChainlinkAggregator} from "../interfaces/chainlink/IChainlinkAggregator.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20Pool} from "@ajna-core/interfaces/pool/erc20/IERC20Pool.sol";

contract StrategyAprOracle is AprOracleBase {
    uint256 private constant HALF_HOUR = 30 minutes;
    uint256 private constant WEEK = 7 days;
    uint256 private constant YEAR = 365 days;
    uint256 private constant WAD = 1e18;

    uint64 public lstApr = 0.0325e18;
    bool public useUniswapTwap;

    constructor() AprOracleBase("Ajna LST Strategy APR Oracle", msg.sender) {}

    /**
     * @notice Will return the expected Apr of a strategy post a debt change.
     * @dev _delta is a signed integer so that it can also represent a debt
     * decrease.
     *
     * This should return the annual expected return at the current timestamp
     * represented as 1e18.
     *
     *      ie. 10% == 1e17
     *
     * _delta will be == 0 to get the current apr.
     *
     * This will potentially be called during non-view functions so gas
     * efficiency should be taken into account.
     *
     * @param  _strategy The token to get the apr for.
     * @param  _delta    The difference in debt.
     * @return _apr      The expected apr for the strategy represented as 1e18.
     */
    function aprAfterDebtChange(address _strategy, int256 _delta)
        external
        view
        override
        returns (uint256 _apr)
    {
        IStrategyInterface _iStrategy = IStrategyInterface(_strategy);
        uint256 _targetLTV = _iStrategy.ltvs().targetLTV;

        uint256 _lstApr;
        if (useUniswapTwap) {
            int256 _uniswapTwapApr = _getLstAprFromUniswapTWAP(
                _iStrategy.uniswapPool(),
                _iStrategy.asset()
            );
            _lstApr = (_uniswapTwapApr >= 0) ? uint256(_uniswapTwapApr) : 0;
        } else {
            _lstApr = lstApr;
        }

        IERC20Pool _ajnaPool = IERC20Pool(_iStrategy.ajnaPool());

        (uint256 _ajnaBorrowApr, ) = _ajnaPool.interestRateInfo();
        uint256 _assets = WAD;
        uint256 _collateral = WAD**2 / (WAD - _targetLTV);
        uint256 _debt = (_collateral * _targetLTV) / WAD;

        uint256 _debtCost = (_debt * _ajnaBorrowApr) / WAD;
        uint256 _extraYield;
        if (_collateral > _assets) {
            _extraYield = ((_collateral - _assets) * _lstApr) / WAD;
        }

        if (_assets != 0 && _extraYield > _debtCost) {
            _apr = ((_extraYield - _debtCost) * WAD) / _assets;
        }
    }

    function getLstAprFromUniswapTWAP(address _strategy)
        external
        view
        returns (int256)
    {
        IStrategyInterface _iStrategy = IStrategyInterface(_strategy);
        return
            _getLstAprFromUniswapTWAP(
                _iStrategy.uniswapPool(),
                _iStrategy.asset()
            );
    }

    function setLstApr(uint64 _lstApr) external onlyGovernance {
        lstApr = _lstApr;
    }

    function setUseUniswapTwap(bool _useUniswapTwap) external onlyGovernance {
        useUniswapTwap = _useUniswapTwap;
    }

    function _getLstAprFromUniswapTWAP(address _uniswapPool, address _asset)
        internal
        view
        returns (int256 _lstApr)
    {
        uint32 oldestObservation = OracleLibrary.getOldestObservationSecondsAgo(
            _uniswapPool
        );
        uint32 startingObservation = uint32(Math.min(oldestObservation, WEEK));

        (int24 pastMeanTick, ) = consult(
            _uniswapPool,
            startingObservation,
            uint32(startingObservation - HALF_HOUR)
        );
        (int24 currentMeanTick, ) = consult(_uniswapPool, uint32(HALF_HOUR), 0);

        uint160 pastSqrtX96 = TickMath.getSqrtRatioAtTick(pastMeanTick);
        uint160 currentSqrtX96 = TickMath.getSqrtRatioAtTick(currentMeanTick);

        uint256 pastPrice = (((uint256(pastSqrtX96) * WAD) / 2**96)**2) / WAD;
        uint256 currentPrice = (((uint256(currentSqrtX96) * WAD) / 2**96)**2) /
            WAD;

        if (IUniswapV3Pool(_uniswapPool).token1() == _asset) {
            pastPrice = 1e36 / pastPrice;
            currentPrice = 1e36 / currentPrice;
        }
        uint256 timeMultiplier = (YEAR * WAD) / (oldestObservation - HALF_HOUR);

        _lstApr =
            ((int256(currentPrice) - int256(pastPrice)) *
                int256(timeMultiplier)) /
            int256(pastPrice);
    }

    function consult(
        address pool,
        uint32 startingSecondsAgo,
        uint32 endingSecondsAgo
    )
        internal
        view
        returns (int24 arithmeticMeanTick, uint128 harmonicMeanLiquidity)
    {
        require(startingSecondsAgo > endingSecondsAgo, "BP");

        uint32[] memory range = new uint32[](2);
        range[0] = startingSecondsAgo;
        range[1] = endingSecondsAgo;

        (
            int56[] memory tickCumulatives,
            uint160[] memory secondsPerLiquidityCumulativeX128s
        ) = IUniswapV3Pool(pool).observe(range);

        uint32 secondsElapsed = startingSecondsAgo - endingSecondsAgo;

        int56 tickCumulativesDelta = tickCumulatives[1] - tickCumulatives[0];
        uint160 secondsPerLiquidityCumulativesDelta = secondsPerLiquidityCumulativeX128s[
                1
            ] - secondsPerLiquidityCumulativeX128s[0];

        arithmeticMeanTick = int24(
            tickCumulativesDelta / int56(uint56(secondsElapsed))
        );
        // Always round to negative infinity
        if (
            tickCumulativesDelta < 0 &&
            (tickCumulativesDelta % int56(uint56(secondsElapsed)) != 0)
        ) arithmeticMeanTick--;

        // We are multiplying here instead of shifting to ensure that harmonicMeanLiquidity doesn't overflow uint128
        uint192 secondsX160 = uint192(secondsElapsed) * type(uint160).max;
        harmonicMeanLiquidity = uint128(
            secondsX160 / (uint192(secondsPerLiquidityCumulativesDelta) << 32)
        );
    }
}

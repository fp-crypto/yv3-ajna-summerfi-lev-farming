// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {IStrategy} from "@tokenized-strategy/interfaces/IStrategy.sol";

interface IStrategyInterface is IStrategy {
    function WETH() external view returns (address);

    function AJNA_TOKEN() external view returns (address);

    function summerfiAccount() external view returns (address);

    function ajnaPool() external view returns (address);

    function uniswapPool() external view returns (address);

    function auctionFactory() external view returns (address);

    function positionOpen() external view returns (bool);

    function chainlinkOracle() external view returns (address);

    function oracleWrapped() external view returns (address);

    function maxTendBasefee() external view returns (uint64);

    function depositLimit() external view returns (uint256);

    function minAjnaToAuction() external view returns (uint96);

    function slippageAllowedBps() external view returns (uint256);

    struct LTVConfig {
        uint64 targetLTV;
        uint64 minAdjustThreshold;
        uint64 warningThreshold;
        uint64 emergencyThreshold;
    }

    function ltvs() external view returns (LTVConfig memory);

    function positionInfo()
        external
        view
        returns (
            uint256 _debt,
            uint256 _collateral,
            uint256 _t0Np,
            uint256 _thresholdPrice
        );

    function currentLTV() external view returns (uint256 _ltv);

    function estimatedTotalAssets() external view returns (uint256 _eta);

    function estimatedTotalAssetsNoSlippage()
        external
        view
        returns (uint256 _eta);

    function setLtvConfig(LTVConfig memory _ltvs) external;

    function setUniswapFee(uint24 _fee) external;

    function setDepositLimit(uint256 _depositLimit) external;

    function setMinAjnaToAuction(uint96 _minAjna) external;

    function setSlippageAllowedBps(uint16 _slippageAllowedBps) external;

    function setMaxTendBasefee(uint64 _maxTendBasefee) external;

    function setAuction(address _auction) external;

    function manualLeverDown(
        uint256 _toLoose,
        uint64 _targetLTV,
        bool _force
    ) external;
}

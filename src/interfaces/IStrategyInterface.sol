// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.18;

import {IStrategy} from "@tokenized-strategy/interfaces/IStrategy.sol";

interface IStrategyInterface is IStrategy {
    function summerfiAccount() external view returns (address);

    function ajnaPool() external view returns (address);

    function chainlinkOracle() external view returns (address);

    function oracleWrapped() external view returns (address);

    function depositLimit() external view returns (uint256);

    function expectedFlashloanFee() external view returns (uint256);

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
}

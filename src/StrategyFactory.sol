// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.18;

import {Strategy} from "./Strategy.sol";
import {IStrategyInterface} from "./interfaces/IStrategyInterface.sol";

contract StrategyFactory {
    /// @notice Revert message for when a strategy has already been deployed.
    error AlreadyDeployed(address _strategy);

    event NewStrategy(address indexed strategy, address indexed asset);

    address public constant SMS = 0x16388463d60FFE0661Cf7F1f31a7D658aC790ff7;

    address public keeper;

    /// @notice Track the deployments by asset
    mapping(address => address) public deployments;

    constructor(address _keeper) {
        keeper = _keeper;
    }

    /**
     * @notice Deploy a new strategy
     * @dev This will set the msg.sender to all of the permissioned roles.
     */
    function newStrategy(
        address _asset,
        string memory _name,
        address _ajnaPool,
        uint24 _uniswapFee,
        bytes4 _unwrappedToWrappedSelector,
        address _chainlinkOracle,
        bool _oracleWrapped
    ) external returns (address) {
        if (deployments[_asset] != address(0))
            revert AlreadyDeployed(deployments[_asset]);

        // We need to use the custom interface with the
        // tokenized strategies available setters.
        IStrategyInterface _newStrategy = IStrategyInterface(
            address(
                new Strategy(
                    _asset,
                    _name,
                    _ajnaPool,
                    _uniswapFee,
                    _unwrappedToWrappedSelector,
                    _chainlinkOracle,
                    _oracleWrapped
                )
            )
        );

        _newStrategy.setKeeper(keeper);
        _newStrategy.setPendingManagement(SMS);

        emit NewStrategy(address(_newStrategy), _asset);

        deployments[_asset] = address(_newStrategy);
        return address(_newStrategy);
    }

    function setKeeper(address _keeper) external {
        require(msg.sender == SMS, "!SMS");
        keeper = _keeper;
    }

    function isDeployedAsset(address _asset) external view returns (bool) {
        return deployments[_asset] != address(0);
    }
}

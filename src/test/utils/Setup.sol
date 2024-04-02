// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import "forge-std/console.sol";
import {ExtendedTest} from "./ExtendedTest.sol";

import {Strategy, ERC20} from "../../Strategy.sol";
import {StrategyFactory} from "../../StrategyFactory.sol";
import {IStrategyInterface} from "../../interfaces/IStrategyInterface.sol";

// Inherit the events so they can be checked if desired.
import {IEvents} from "@tokenized-strategy/interfaces/IEvents.sol";

import {IERC20Pool} from "@ajna-core/interfaces/pool/erc20/IERC20Pool.sol";
import {ERC20PoolFactory} from "@ajna-core/ERC20PoolFactory.sol";

import {Helpers} from "./Helpers.sol";

interface IFactory {
    function governance() external view returns (address);

    function set_protocol_fee_bps(uint16) external;

    function set_protocol_fee_recipient(address) external;
}

contract Setup is ExtendedTest, IEvents {
    using Helpers for IStrategyInterface;

    // Contract instances that we will use repeatedly.
    ERC20 public asset;
    IStrategyInterface public strategy;

    mapping(string => address) public tokenAddrs;

    // Addresses for different roles we will use repeatedly.
    address public user = address(10);
    address public keeper = address(4);
    address public management = address(0x01fE3347316b2223961B20689C65eaeA71348e93);
    address public performanceFeeRecipient = address(3);
    address public ajnaDepositor = address(42069);

    // Address of the real deployed Factory
    address public factory;

    // Integer variables that will be used repeatedly.
    uint256 public decimals;
    uint256 public MAX_BPS = 10_000;

    // Fuzz from $0.01 of 1e6 stable coins up to 1 trillion of a 1e18 coin
    uint256 public maxFuzzAmount = 1e18;
    uint256 public minFuzzAmount = 0.5e18;

    // Default profit max unlock time is set for 10 days
    uint256 public profitMaxUnlockTime = 10 days;

    function setUp() public virtual {
        _setTokenAddrs();

        // Set asset
        asset = ERC20(tokenAddrs["WSTETH"]);

        // Set decimals
        decimals = asset.decimals();

        // Deploy strategy and set variables
        strategy = IStrategyInterface(setUpStrategy());

        factory = strategy.FACTORY();

        // label all the used addresses for traces
        vm.label(keeper, "keeper");
        vm.label(factory, "factory");
        vm.label(address(asset), "asset");
        vm.label(tokenAddrs["WETH"], "WETH");
        vm.label(management, "management");
        vm.label(address(strategy), "strategy");
        vm.label(strategy.ajnaPool(), "ajnaPool");
        vm.label(strategy.summerfiAccount(), "summerfiAccount");
        vm.label(strategy.chainlinkOracle(), "cl-oracle");
        vm.label(performanceFeeRecipient, "performanceFeeRecipient");
    }

    function setUpStrategy() public returns (address) {
        StrategyFactory _strategyFactory = new StrategyFactory(keeper);

        // we save the strategy as a IStrategyInterface to give it the needed interface
        IStrategyInterface _strategy = IStrategyInterface(
            address(
                _strategyFactory.newStrategy(
                    address(asset),
                    "Tokenized Strategy",
                    getAjnaPoolForAsset(address(asset)),
                    100, // uniswap 1bp pool
                    bytes4(0), // selector,
                    0xa669E5272E60f78299F4824495cE01a3923f4380, // oracle,
                    true // oracleWrapped
                )
            )
        );

        vm.startPrank(management);
        _strategy.acceptManagement();
        // set keeper
        _strategy.setKeeper(keeper);
        // set treasury
        _strategy.setPerformanceFeeRecipient(performanceFeeRecipient);
        // set management of the strategy
        _strategy.setPendingManagement(management);
        // set deposit limit
        _strategy.setDepositLimit(2**256 - 1);
        IStrategyInterface.LTVConfig memory _ltvConfig = _strategy.ltvs();
        _ltvConfig.targetLTV = 0.70e18;
        // set target ltv
        _strategy.setLtvConfig(_ltvConfig);
        vm.stopPrank();

        supplyQuote(maxFuzzAmount * 100, getAjnaPoolForAsset(address(asset)));

        return address(_strategy);
    }

    function depositIntoStrategy(
        IStrategyInterface _strategy,
        address _user,
        uint256 _amount
    ) public {
        vm.prank(_user);
        asset.approve(address(_strategy), _amount);

        vm.prank(_user);
        _strategy.deposit(_amount, _user);
    }

    function getAjnaPoolForAsset(address _asset)
        public
        view
        returns (address _pool)
    {
        ERC20PoolFactory ajnaFactory = ERC20PoolFactory(
            0x214f62B5836D83f3D6c4f71F174209097B1A779C
        );
        address WETH = tokenAddrs["WETH"];

        for (uint256 i; i < ajnaFactory.getNumberOfDeployedPools(); ++i) {
            IERC20Pool pool = IERC20Pool(ajnaFactory.deployedPoolsList(i));
            if (
                pool.collateralAddress() == _asset &&
                pool.quoteTokenAddress() == WETH
            ) return address(pool);
        }
    }

    function mintAndDepositIntoStrategy(
        IStrategyInterface _strategy,
        address _user,
        uint256 _amount
    ) public {
        airdrop(asset, _user, _amount);
        depositIntoStrategy(_strategy, _user, _amount);
    }

    function supplyQuote(uint256 _amount, address _ajnaPool) public {
        supplyQuote(_amount, _ajnaPool, 4130);
    }

    function supplyQuote(uint256 _amount, address _ajnaPool, uint256 _bucketIndex) public {
        ERC20 WETH = ERC20(tokenAddrs["WETH"]);
        airdrop(WETH, ajnaDepositor, _amount);
        vm.prank(ajnaDepositor);
        WETH.approve(_ajnaPool, _amount);
        vm.prank(ajnaDepositor);
        IERC20Pool(_ajnaPool).addQuoteToken(_amount, _bucketIndex, type(uint256).max);
    }

    function totalIdle(IStrategyInterface _strategy) public view returns (uint256) {
        return ERC20(_strategy.asset()).balanceOf(address(_strategy));
    }

    function totalDebt(IStrategyInterface _strategy) public view returns (uint256) {
        uint256 _totalIdle = totalIdle(_strategy);
        uint256 _totalAssets = _strategy.totalAssets();
        if (_totalIdle >= _totalAssets) return 0;
        return _totalAssets - _totalIdle;
    }

    // For checking the amounts in the strategy
    function checkStrategyTotals(
        IStrategyInterface _strategy,
        uint256 _totalAssets,
        uint256 _totalDebt,
        uint256 _totalIdle
    ) public {
        assertEq(_strategy.totalAssets(), _totalAssets, "!totalAssets");
        assertEq(_strategy.totalDebt(), _totalDebt, "!totalDebt");
        assertEq(_strategy.totalIdle(), _totalIdle, "!totalIdle");
        assertEq(_totalAssets, _totalDebt + _totalIdle, "!Added");
    }

    function airdrop(
        ERC20 _asset,
        address _to,
        uint256 _amount
    ) public {
        uint256 balanceBefore = _asset.balanceOf(_to);
        deal(address(_asset), _to, balanceBefore + _amount);
    }

    function setFees(uint16 _protocolFee, uint16 _performanceFee) public {
        address gov = IFactory(factory).governance();

        // Need to make sure there is a protocol fee recipient to set the fee.
        vm.prank(gov);
        IFactory(factory).set_protocol_fee_recipient(gov);

        vm.prank(gov);
        IFactory(factory).set_protocol_fee_bps(_protocolFee);

        vm.prank(management);
        strategy.setPerformanceFee(_performanceFee);
    }

    function checkLTV() public {
        checkLTV(true);
    }

    function checkLTV(uint64 targetLTV) public {
        checkLTV(true, false, targetLTV);
    }

    function checkLTV(bool canBeZero) public {
        checkLTV(canBeZero, false);
    }

    function checkLTV(bool canBeZero, bool onlyCheckTooHigh) public {
        checkLTV(canBeZero, onlyCheckTooHigh, strategy.ltvs().targetLTV);
    }

    function checkLTV(bool canBeZero, bool onlyCheckTooHigh, uint64 targetLTV) public {
        if (canBeZero && strategy.currentLTV() == 0) return;
        if (onlyCheckTooHigh) {
            assertLe(
                strategy.currentLTV(),
                targetLTV + strategy.ltvs().minAdjustThreshold,
                "!LTV too high"
            );
        } else {
            assertApproxEq(
                strategy.currentLTV(),
                targetLTV,
                strategy.ltvs().minAdjustThreshold,
                "!LTV not target"
            );
        }
    }

    function _setTokenAddrs() internal {
        tokenAddrs["WETH"] = 0x4200000000000000000000000000000000000006;
        tokenAddrs["WSTETH"] = 0xc1CBa3fCea344f92D9239c08C0568f6F2F0ee452;
        tokenAddrs["RETH"] = 0xae78736Cd615f374D3085123A210448E74Fc6393;
    }
}

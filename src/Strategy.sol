// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {BaseStrategy, ERC20} from "@tokenized-strategy/BaseStrategy.sol";

import {BaseHealthCheck} from "@periphery/Bases/HealthCheck/BaseHealthCheck.sol";
import {Auction, AuctionSwapper} from "@periphery/swappers/AuctionSwapper.sol";

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IERC20Pool} from "@ajna-core/interfaces/pool/erc20/IERC20Pool.sol";
import {COLLATERALIZATION_FACTOR} from "@ajna-core/libraries/helpers/PoolHelper.sol";
import {Maths} from "@ajna-core/libraries/internal/Maths.sol";
import {PoolCommons} from "@ajna-core/libraries/external/PoolCommons.sol";
//import {PoolInfoUtils} from "@ajna-core/PoolInfoUtils.sol";

import {IUniswapV3Pool} from "@uniswap-v3-core/interfaces/IUniswapV3Pool.sol";
import {IUniswapV3SwapCallback} from "@uniswap-v3-core/interfaces/callback/IUniswapV3SwapCallback.sol";
import {IUniswapV3Factory} from "@uniswap-v3-core/interfaces/IUniswapV3Factory.sol";

import {IWETH} from "./interfaces/IWeth.sol";
import {IAccount} from "./interfaces/summerfi/IAccount.sol";
import {IAccountFactory} from "./interfaces/summerfi/IAccountFactory.sol";
import {AjnaProxyActions} from "./interfaces/summerfi/AjnaProxyActions.sol";
import {IAjnaRedeemer} from "./interfaces/summerfi/IAjnaRedeemer.sol";
import {IChainlinkAggregator} from "./interfaces/chainlink/IChainlinkAggregator.sol";

// import "forge-std/console.sol"; // TODO: delete

contract Strategy is BaseHealthCheck, IUniswapV3SwapCallback /*, AuctionSwapper */ {
    using SafeERC20 for ERC20;

    IAccountFactory private constant SUMMERFI_ACCOUNT_FACTORY =
        IAccountFactory(0x881CD31218f45a75F8ad543A3e1Af087f3986Ae0);
    AjnaProxyActions private constant SUMMERFI_AJNA_PROXY_ACTIONS =
        AjnaProxyActions(0x099708408aDb18F6D49013c88F3b1Bb514cC616F);
    //PoolInfoUtils private constant POOL_INFO_UTILS =
    //    PoolInfoUtils(0x30c5eF2997d6a882DE52c4ec01B6D0a5e5B4fAAE);
    //IAjnaRedeemer private constant SUMMERFI_REWARDS =
    //    IAjnaRedeemer(0xf309EE5603bF05E5614dB930E4EAB661662aCeE6);
    IUniswapV3Factory private constant UNISWAP_FACTORY =
        IUniswapV3Factory(0x33128a8fC17869897dcE68Ed026d694621f6FDfD);

    address private constant WETH = 0x4200000000000000000000000000000000000006;
    //address private constant AJNA_TOKEN =
    //    0x9a96ec9B57Fb64FbC60B423d1f4da7691Bd35079;

    IAccount public immutable summerfiAccount;
    IERC20Pool public immutable ajnaPool;
    IChainlinkAggregator public immutable chainlinkOracle;
    bool public immutable oracleWrapped;
    bytes4 private immutable unwrappedToWrappedSelector;
    bool private immutable uniswapAsset0Weth1;

    uint96 public minAjnaToAuction = 1_000e18; // 1000 ajna
    IUniswapV3Pool public uniswapPool;
    bool public positionOpen;
    uint16 public slippageAllowedBps = 75; // 0.75%
    uint64 public maxTendBasefee = 5e9; // 5 gwei
    uint256 public depositLimit;

    struct LTVConfig {
        uint64 targetLTV;
        uint64 minAdjustThreshold;
        uint64 warningThreshold;
        uint64 emergencyThreshold;
    }
    LTVConfig public ltvs;

    uint256 private constant ONE_WAD = 1e18;
    uint64 internal constant DEFAULT_MIN_ADJUST_THRESHOLD = 0.005e18;
    uint64 internal constant DEFAULT_WARNING_THRESHOLD = 0.01e18;
    uint64 internal constant DEFAULT_EMERGENCY_THRESHOLD = 0.02e18;
    uint64 internal constant DUST_THRESHOLD = 100; //0.00001e18;

    /// @dev The minimum value that can be returned from #getSqrtRatioAtTick. Equivalent to getSqrtRatioAtTick(MIN_TICK)
    uint160 internal constant UNISWAP_MIN_SQRT_RATIO = 4295128739;
    /// @dev The maximum value that can be returned from #getSqrtRatioAtTick. Equivalent to getSqrtRatioAtTick(MAX_TICK)
    uint160 internal constant UNISWAP_MAX_SQRT_RATIO =
        1461446703485210103287273052203988822378723970342;

    constructor(
        address _asset,
        string memory _name,
        address _ajnaPool,
        uint24 _uniswapFee,
        bytes4 _unwrappedToWrappedSelector,
        address _chainlinkOracle,
        bool _oracleWrapped
    ) BaseHealthCheck(_asset, _name) {
        require(_asset == IERC20Pool(_ajnaPool).collateralAddress(), "!collat"); // dev: asset must be collateral
        require(WETH == IERC20Pool(_ajnaPool).quoteTokenAddress(), "!weth"); // dev: quoteToken must be WETH

        address _summerfiAccount = SUMMERFI_ACCOUNT_FACTORY.createAccount();

        ajnaPool = IERC20Pool(_ajnaPool);
        summerfiAccount = IAccount(_summerfiAccount);
        unwrappedToWrappedSelector = _unwrappedToWrappedSelector;
        chainlinkOracle = IChainlinkAggregator(_chainlinkOracle);
        oracleWrapped = _oracleWrapped;
        uniswapAsset0Weth1 = address(asset) < WETH;

        ERC20(_asset).safeApprove(_summerfiAccount, type(uint256).max);

        LTVConfig memory _ltvs;
        _ltvs.minAdjustThreshold = DEFAULT_MIN_ADJUST_THRESHOLD;
        _ltvs.warningThreshold = DEFAULT_WARNING_THRESHOLD;
        _ltvs.emergencyThreshold = DEFAULT_EMERGENCY_THRESHOLD;
        ltvs = _ltvs;

        _setUniswapFee(_uniswapFee);
        //_enableAuction(AJNA_TOKEN, address(asset));
    }

    /*******************************************
     *          PUBLIC VIEW FUNCTIONS          *
     *******************************************/

    /**
     *  @notice Retrieves info related to our debt position
     *  @return _debt             Current debt owed (`WAD`).
     *  @return _collateral       Pledged collateral, including encumbered (`WAD`).
     *  @return _t0Np             `Neutral price` (`WAD`).
     *  @return _thresholdPrice   Borrower's `Threshold Price` (`WAD`).
     */
    function positionInfo()
        external
        view
        returns (
            uint256 _debt,
            uint256 _collateral,
            uint256 _t0Np,
            uint256 _thresholdPrice
        )
    {
        return _positionInfo();
    }

    /**
     *  @return . The strategy's current LTV
     */
    function currentLTV() external view returns (uint256) {
        (uint256 _debt, uint256 _collateral, , ) = _positionInfo();
        return _calculateLTV(_debt, _collateral, _getAssetPerWeth());
    }

    /**
     * @notice A conservative estimate of assets taking into account
     * the max slippage allowed
     *
     * @return . estimated total assets
     */
    function estimatedTotalAssets() external view returns (uint256) {
        (uint256 _debt, uint256 _collateral, , ) = _positionInfo();
        uint256 _idle = _looseAssets();
        return
            _calculateNetPositionWithMaxSlippage(
                _debt,
                _collateral,
                _getAssetPerWeth()
            ) + _idle;
    }

    /**
     * @notice A liberal estimate of assets not taking into account
     * the max slippage allowed
     *
     * @return . estimated total assets
     */
    function estimatedTotalAssetsNoSlippage() external view returns (uint256) {
        (uint256 _debt, uint256 _collateral, , ) = _positionInfo();
        // increase debt by max slippage, since we must swap all debt to exit our position
        uint256 _idle = _looseAssets();
        return
            _calculateNetPosition(_debt, _collateral, _getAssetPerWeth()) +
            _idle;
    }

    /*******************************************
     *          MANAGEMENT FUNCTIONS           *
     *******************************************/

    /**
     * @notice Sets the ltv configuration. Can only be called by management
     * @param _ltvs The LTV configuration
     */
    function setLtvConfig(LTVConfig memory _ltvs) external onlyManagement {
        require(_ltvs.warningThreshold < _ltvs.emergencyThreshold); // dev: warning must be less than emergency threshold
        require(_ltvs.minAdjustThreshold < _ltvs.warningThreshold); // dev: minAdjust must be less than warning threshold
        ltvs = _ltvs;
    }

    /**
     * @notice Sets the uniswap fee tier. Can only be called by management
     * @param _fee The uniswap fee tier to use for Asset<->Weth swaps
     */
    function setUniswapFee(uint24 _fee) external onlyManagement {
        _setUniswapFee(_fee);
    }

    /**
     * @notice Sets the deposit limit. Can only be called by management
     * @param _depositLimit The deposit limit
     */
    function setDepositLimit(uint256 _depositLimit) external onlyManagement {
        depositLimit = _depositLimit;
    }

    /**
     * @notice Sets the slippage allowed on swaps. Can only be called by management
     * @param _slippageAllowedBps The slippage allowed in basis points
     */
    function setSlippageAllowedBps(uint16 _slippageAllowedBps)
        external
        onlyManagement
    {
        require(_slippageAllowedBps <= MAX_BPS); // dev: cannot be more than 100%
        slippageAllowedBps = _slippageAllowedBps;
    }

    /**
     * @notice Sets the max base fee for tends. Can only be called by management
     * @param _maxTendBasefee The maximum base fee allowed in non-emergency tends
     */
    function setMaxTendBasefee(uint64 _maxTendBasefee) external onlyManagement {
        maxTendBasefee = _maxTendBasefee;
    }

    //function setMinAjnaToAuction(uint96 _minAjnaToAuction)
    //    external
    //    onlyManagement
    //{
    //    minAjnaToAuction = _minAjnaToAuction;
    //}

    //function setAuction(address _auction) external onlyEmergencyAuthorized {
    //    if (_auction != address(0)) {
    //        require(Auction(_auction).want() == address(asset)); // dev: wrong want
    //    }
    //    auction = _auction;
    //}

    /***********************************************
     *      BASE STRATEGY OVERRIDE FUNCTIONS       *
     ***********************************************/

    /**
     * @dev Should deploy up to '_amount' of 'asset' in the yield source.
     *
     * This function is called at the end of a {deposit} or {mint}
     * call. Meaning that unless a whitelist is implemented it will
     * be entirely permissionless and thus can be sandwiched or otherwise
     * manipulated.
     *
     * @param _amount The amount of 'asset' that the strategy should attempt
     * to deposit in the yield source.
     */
    function _deployFunds(uint256 _amount) internal override {
        if (!positionOpen) {
            return;
        }

        _depositAndDraw(0, _amount, 0, false); // deposit as collateral
    }

    /**
     * @dev Will attempt to free the '_amount' of 'asset'.
     *
     * The amount of 'asset' that is already loose has already
     * been accounted for.
     *
     * This function is called during {withdraw} and {redeem} calls.
     * Meaning that unless a whitelist is implemented it will be
     * entirely permissionless and thus can be sandwiched or otherwise
     * manipulated.
     *
     * Should not rely on asset.balanceOf(address(this)) calls other than
     * for diff accounting purposes.
     *
     * Any difference between `_amount` and what is actually freed will be
     * counted as a loss and passed on to the withdrawer. This means
     * care should be taken in times of illiquidity. It may be better to revert
     * if withdraws are simply illiquid so not to realize incorrect losses.
     *
     * @param _amount, The amount of 'asset' to be freed.
     */
    function _freeFunds(uint256 _amount) internal override {
        (uint256 _debt, uint256 _collateral, , ) = _positionInfo();
        uint256 _price = _getAssetPerWeth();
        uint256 _positionValue = _calculateNetPosition(
            _debt,
            _collateral,
            _price
        );
        uint256 _totalAssets = TokenizedStrategy.totalAssets();
        uint256 _deployed = _deployedAssets(_totalAssets);
        if (_amount != _deployed && _positionValue < _totalAssets) {
            _amount = (_amount * _positionValue) / _totalAssets;
        }

        LTVConfig memory _ltvs = ltvs;

        _leverDown(_debt, _collateral, _amount, _ltvs, _price, _deployed);

        (_debt, _collateral, , ) = _positionInfo();
        require(
            _calculateLTV(_debt, _collateral, _price) <
                _ltvs.targetLTV + _ltvs.minAdjustThreshold,
            "!ltv"
        ); // dev: ltv in target
    }

    /**
     * @dev Internal function to harvest all rewards, redeploy any idle
     * funds and return an accurate accounting of all funds currently
     * held by the Strategy.
     *
     * This should do any needed harvesting, rewards selling, accrual,
     * redepositing etc. to get the most accurate view of current assets.
     *
     * NOTE: All applicable assets including loose assets should be
     * accounted for in this function.
     *
     * Care should be taken when relying on oracles or swap values rather
     * than actual amounts as all Strategy profit/loss accounting will
     * be done based on this returned value.
     *
     * This can still be called post a shutdown, a strategist can check
     * `TokenizedStrategy.isShutdown()` to decide if funds should be
     * redeployed or simply realize any profits/losses.
     *
     * @return _totalAssets A trusted and accurate account for the total
     * amount of 'asset' the strategy currently holds including idle funds.
     */
    function _harvestAndReport()
        internal
        override
        returns (uint256 _totalAssets)
    {
        uint256 _idle = _looseAssets();
        _adjustPosition(_idle);
        (uint256 _debt, uint256 _collateral, , ) = _positionInfo();
        _totalAssets =
            _calculateNetPositionWithMaxSlippage(
                _debt,
                _collateral,
                _getAssetPerWeth()
            ) +
            _idle;
    }

    /*//////////////////////////////////////////////////////////////
                    OPTIONAL TO OVERRIDE BY STRATEGIST
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Optional function for strategist to override that can
     *  be called in between reports.
     *
     * If '_tend' is used tendTrigger() will also need to be overridden.
     *
     * This call can only be called by a permissioned role so may be
     * through protected relays.
     *
     * This can be used to harvest and compound rewards, deposit idle funds,
     * perform needed position maintenance or anything else that doesn't need
     * ssda full report for.
     *
     *   EX: A strategy that can not deposit funds without getting
     *       sandwiched can use the tend when a certain threshold
     *       of idle to totalAssets has been reached.
     *
     * The TokenizedStrategy contract will do all needed debt and idle updates
     * after this has finished and will have no effect on PPS of the strategy
     * till report() is called.
     *
     * @param _idle The current amount of idle funds that are available to deploy.
     *
     */
    function _tend(uint256 _idle) internal override {
        _adjustPosition(_idle);
    }

    /**
     * @dev Optional trigger to override if tend() will be used by the strategy.
     * This must be implemented if the strategy hopes to invoke _tend().
     *
     * @return . Should return true if tend() should be called by keeper or false if not.
     *
     */
    function _tendTrigger() internal view override returns (bool) {
        if (TokenizedStrategy.totalAssets() == 0 || !positionOpen) {
            return false;
        }

        (
            uint256 _debt,
            uint256 _collateral,
            ,
            uint256 _thresholdPrice
        ) = _positionInfo();
        LTVConfig memory _ltvs = ltvs;
        uint256 _assetPerWeth = _getAssetPerWeth();
        uint256 _wethPerAsset = (ONE_WAD**2) / _assetPerWeth;
        uint256 _currentLtv = _calculateLTV(_debt, _collateral, _assetPerWeth);

        // We need to lever down if the LTV is past the emergencyThreshold
        // or the price is below the threshold price
        if (
            _currentLtv >= _ltvs.targetLTV + _ltvs.emergencyThreshold ||
            _wethPerAsset <= _thresholdPrice
        ) {
            return true;
        }

        // All other checks can wait for low gas
        if (block.basefee >= maxTendBasefee) {
            return false;
        }

        // Tend if ltv is higher than the target range
        if (_currentLtv >= _ltvs.targetLTV + _ltvs.warningThreshold) {
            return true;
        }

        if (TokenizedStrategy.isShutdown()) {
            return false;
        }

        // Tend if ltv is lower than target range
        if (
            _currentLtv != 0 &&
            _currentLtv <= _ltvs.targetLTV - _ltvs.minAdjustThreshold
        ) {
            return true;
        }

        return false;
    }

    /**
     * @notice Gets the max amount of `asset` that an address can deposit.
     * @dev Defaults to an unlimited amount for any address. But can
     * be overridden by strategists.
     *
     * This function will be called before any deposit or mints to enforce
     * any limits desired by the strategist. This can be used for either a
     * traditional deposit limit or for implementing a whitelist etc.
     *
     *   EX:
     *      if(isAllowed[_owner]) return super.availableDepositLimit(_owner);
     *
     * This does not need to take into account any conversion rates
     * from shares to assets. But should know that any non max uint256
     * amounts may be converted to shares. So it is recommended to keep
     * custom amounts low enough as not to cause overflow when multiplied
     * by `totalSupply`.
     *
     * @param . The address that is depositing into the strategy.
     * @return . The available amount the `_owner` can deposit in terms of `asset`
     *
     */
    function availableDepositLimit(
        address /*_owner */
    ) public view override returns (uint256) {
        uint256 _totalAssets = TokenizedStrategy.totalAssets();
        return _totalAssets >= depositLimit ? 0 : depositLimit - _totalAssets;
    }

    /**
     * @dev Optional function for a strategist to override that will
     * allow management to manually withdraw deployed funds from the
     * yield source if a strategy is shutdown.
     *
     * This should attempt to free `_amount`, noting that `_amount` may
     * be more than is currently deployed.
     *
     * NOTE: This will not realize any profits or losses. A separate
     * {report} will be needed in order to record any profit/loss. If
     * a report may need to be called after a shutdown it is important
     * to check if the strategy is shutdown during {_harvestAndReport}
     * so that it does not simply re-deploy all funds that had been freed.
     *
     * EX:
     *   if(freeAsset > 0 && !TokenizedStrategy.isShutdown()) {
     *       depositFunds...
     *    }
     *
     * @param _amount The amount of asset to attempt to free.
     *
     */
    function _emergencyWithdraw(uint256 _amount) internal override {
        (uint256 _debt, uint256 _collateral, , ) = _positionInfo();
        uint256 _price = _getAssetPerWeth();

        LTVConfig memory _ltvs = ltvs;

        _leverDown(
            _debt,
            _collateral,
            _amount,
            _ltvs,
            _price,
            _deployedAssets()
        );

        (_debt, _collateral, , ) = _positionInfo();
        require(
            _calculateLTV(_debt, _collateral, _price) <
                _ltvs.targetLTV + _ltvs.minAdjustThreshold,
            "!ltv"
        ); // dev: ltv in target
    }

    //function _auctionKicked(address _token)
    //    internal
    //    virtual
    //    override
    //    returns (uint256 _kicked)
    //{
    //    require(_token == AJNA_TOKEN); // dev: only sell ajna
    //    _kicked = super._auctionKicked(_token);
    //    require(_kicked >= minAjnaToAuction); // dev: too little
    //}

    /**************************************************
     *      EXTERNAL POSTION MANAGMENT FUNCTIONS      *
     **************************************************/

    /**
     * @notice Allows emergency authorized to manually lever down
     *
     * @param _toLoose the amount of assets to attempt to loose
     * @param _targetLTV the LTV ratio to target
     * @param _force Ignore safety checks
     */
    function manualLeverDown(
        uint256 _toLoose,
        uint64 _targetLTV,
        bool _force
    ) external onlyEmergencyAuthorized {
        (uint256 _debt, uint256 _collateral, , ) = _positionInfo();
        uint256 _price = _getAssetPerWeth();

        LTVConfig memory _ltvs = ltvs;
        require(_force || _targetLTV <= ltvs.targetLTV); // dev: _targetLTV too high
        _ltvs.targetLTV = _targetLTV;

        _leverDown(
            _debt,
            _collateral,
            _toLoose,
            _ltvs,
            _price,
            _deployedAssets()
        );

        (_debt, _collateral, , ) = _positionInfo();
        require(
            _force ||
                _calculateLTV(_debt, _collateral, _price) <
                _ltvs.targetLTV + _ltvs.minAdjustThreshold,
            "!ltv"
        ); // dev: ltv in target
    }

    /**
     * @notice Allows emergency authorized to manually repay and/or withdrwa
     *
     * @param  _debtAmount       Amount of debt to repay
     * @param  _collateralAmount Amount of collateral to withdraw
     * @param  _stamp            Whether to stamp the loan or not
     */
    function manualRepayWithdraw(
        uint256 _debtAmount,
        uint256 _collateralAmount,
        bool _stamp
    ) external onlyEmergencyAuthorized {
        _repayWithdraw(_debtAmount, _collateralAmount, _stamp);
    }

    /**
     * @notice Allows emergency authorized to manually swap asset<->weth or vice versa
     *
     * @param  _amountIn        Amount of input token
     * @param  _minOut          Minimum output token acceptable
     * @param  _assetForWeth    Whether to swap asset for weth or weth for asset
     */
    function manualSwap(
        uint256 _amountIn,
        uint64 _minOut,
        bool _assetForWeth
    ) external onlyEmergencyAuthorized {
        bool zeroForOne = uniswapAsset0Weth1 ? _assetForWeth : !_assetForWeth;
        bytes memory _data = abi.encode(
            LeverData(LeverAction.ManualSwap, 0, 0, 0)
        );

        (int256 amount0, int256 amount1) = uniswapPool.swap(
            address(this),
            zeroForOne,
            int256(_amountIn),
            (
                zeroForOne
                    ? UNISWAP_MIN_SQRT_RATIO + 1
                    : UNISWAP_MAX_SQRT_RATIO - 1
            ),
            _data
        );

        require(uint256(zeroForOne ? amount1 : amount0) >= _minOut); // dev: !minOut
    }

    ///**
    // * @notice Claims summerfi ajna rewards
    // *
    // * Unguarded because there is no risk claiming
    // *
    // * @param _weeks An array of week numbers for which to claim rewards.
    // * @param _amounts An array of reward amounts to claim.
    // * @param _proofs An array of Merkle proofs, one for each corresponding week and amount given.
    // */
    //function redeemSummerAjnaRewards(
    //    uint256[] calldata _weeks,
    //    uint256[] calldata _amounts,
    //    bytes32[][] calldata _proofs
    //) external {
    //    SUMMERFI_REWARDS.claimMultiple(_weeks, _amounts, _proofs);
    //}

    /**************************************************
     *      INTERNAL POSTION MANAGMENT FUNCTIONS      *
     **************************************************/

    /**
     * @notice Adjusts the leveraged position
     */
    function _adjustPosition(uint256 _idle) internal {
        (
            uint256 _debt,
            uint256 _collateral,
            ,
            uint256 _thresholdPrice
        ) = _positionInfo();
        LTVConfig memory _ltvs = ltvs;
        uint256 _assetPerWeth = _getAssetPerWeth();
        uint256 _wethPerAsset = ONE_WAD**2 / _assetPerWeth;
        uint256 _currentLtv = _calculateLTV(_debt, _collateral, _assetPerWeth);

        if (
            positionOpen &&
            (_wethPerAsset <= _thresholdPrice ||
                _currentLtv >= _ltvs.targetLTV + _ltvs.minAdjustThreshold)
        ) {
            _leverDown(
                _debt,
                _collateral,
                0,
                _ltvs,
                _assetPerWeth,
                _deployedAssets()
            );
        } else if (_currentLtv + _ltvs.minAdjustThreshold <= _ltvs.targetLTV) {
            _leverUp(_debt, _collateral, _idle, _ltvs, _assetPerWeth);
        } else {
            return; // bail out if we are doing nothing
        }

        (_debt, _collateral, , _thresholdPrice) = _positionInfo();

        _currentLtv = _calculateLTV(_debt, _collateral, _assetPerWeth);
        require(
            _currentLtv < _ltvs.targetLTV + _ltvs.minAdjustThreshold,
            "!ltv"
        ); // dev: not safe
    }

    enum LeverAction {
        LeverUp,
        LeverDown,
        ClosePosition,
        ManualSwap
    }

    struct LeverData {
        LeverAction action;
        uint256 assetToFree;
        uint256 assetPerWeth;
        uint256 totalCollateral;
    }

    /**
     * @notice Levers up
     */
    function _leverUp(
        uint256 _debt,
        uint256 _collateral,
        uint256 _idle,
        LTVConfig memory _ltvs,
        uint256 _assetPerWeth
    ) internal {
        uint256 _supply = _calculateNetPosition(
            _debt,
            _collateral,
            _assetPerWeth
        );

        uint256 _targetBorrow = _getBorrowFromSupply(
            _supply + _idle,
            _ltvs.targetLTV,
            _assetPerWeth
        );

        if (_targetBorrow < _minLoanSize()) {
            return;
        }

        require(_targetBorrow > _debt); // dev: something is very wrong

        uint256 _toBorrow = _targetBorrow - _debt;
        uint256 _availableBorrow = _availableWethBorrow();
        if (_availableBorrow < _toBorrow) {
            _toBorrow = _availableBorrow;
        }

        _swapAndLeverUp(_toBorrow, _assetPerWeth);
    }

    /**
     * @notice Levers down
     */
    function _leverDown(
        uint256 _debt,
        uint256 _collateral,
        uint256 _assetToFree,
        LTVConfig memory _ltvs,
        uint256 _assetPerWeth,
        uint256 _deployedAssets
    ) internal {
        uint256 _supply = _calculateNetPosition(
            _debt,
            _collateral,
            _assetPerWeth
        );

        uint256 _targetBorrow;
        if (_supply > _assetToFree) {
            _targetBorrow = _getBorrowFromSupply(
                _supply - _assetToFree,
                _ltvs.targetLTV,
                _assetPerWeth
            );

            if (_targetBorrow < _minLoanSize()) {
                _targetBorrow = 0;
            }
        } else {
            _assetToFree = _supply;
        }

        if (_debt <= _targetBorrow) {
            if (_assetToFree > DUST_THRESHOLD) {
                _repayWithdraw(0, _assetToFree, false);
            }
            return;
        }

        uint256 _repaymentAmount;
        unchecked {
            _repaymentAmount = _debt - _targetBorrow;
        }

        bool _closePosition = _repaymentAmount == _debt &&
            (_assetToFree == 0 ||
                _assetToFree == _supply ||
                _assetToFree >= _deployedAssets);

        _swapAndLeverDown(
            _repaymentAmount,
            _assetToFree,
            _closePosition,
            _assetPerWeth,
            _collateral
        );
    }

    /**************************************************
     *               UNISWAP FUNCTIONS                *
     **************************************************/

    function _swapAndLeverUp(uint256 _borrowAmount, uint256 _assetPerWeth)
        private
    {
        bool zeroForOne = !uniswapAsset0Weth1;

        bytes memory _data = abi.encode(
            LeverData(
                LeverAction.LeverUp,
                uint256(0),
                _assetPerWeth,
                uint256(0)
            )
        );

        /* (int256 amount0, int256 amount1) = */
        uniswapPool.swap(
            address(this),
            zeroForOne,
            int256(_borrowAmount),
            (
                zeroForOne
                    ? UNISWAP_MIN_SQRT_RATIO + 1
                    : UNISWAP_MAX_SQRT_RATIO - 1
            ),
            _data
        );
    }

    function _swapAndLeverDown(
        uint256 _repaymentAmount,
        uint256 _assetToLoose,
        bool _close,
        uint256 _assetPerWeth,
        uint256 _totalCollateral
    ) private {
        bool zeroForOne = uniswapAsset0Weth1;

        bytes memory _data = abi.encode(
            LeverData(
                _close ? LeverAction.ClosePosition : LeverAction.LeverDown,
                _assetToLoose,
                _assetPerWeth,
                _totalCollateral
            )
        );

        (int256 amount0Delta, int256 amount1Delta) = uniswapPool.swap(
            address(this),
            zeroForOne,
            -int256(_repaymentAmount),
            (
                zeroForOne
                    ? UNISWAP_MIN_SQRT_RATIO + 1
                    : UNISWAP_MAX_SQRT_RATIO - 1
            ),
            _data
        );

        uint256 _wethOut = uint256(zeroForOne ? -amount1Delta : -amount0Delta);

        // it's technically possible to not receive the full output amount
        // require this possibility away
        require(_wethOut == _repaymentAmount); // dev: wethOut != _repaymentAmount
    }

    /// @inheritdoc IUniswapV3SwapCallback
    function uniswapV3SwapCallback(
        int256 _amount0Delta,
        int256 _amount1Delta,
        bytes calldata _data
    ) external {
        require(msg.sender == address(uniswapPool)); // dev: callback only called by pool
        require(_amount0Delta > 0 || _amount1Delta > 0); // dev: swaps entirely within 0-liquidity regions are not supported

        (
            bool _isExactInput,
            uint256 _amountToPay,
            uint256 _amountReceived
        ) = _amount0Delta > 0
                ? (
                    !uniswapAsset0Weth1,
                    uint256(_amount0Delta),
                    uint256(-_amount1Delta)
                )
                : (
                    uniswapAsset0Weth1,
                    uint256(_amount1Delta),
                    uint256(-_amount0Delta)
                );

        LeverData memory _leverData = abi.decode(_data, (LeverData));

        if (_leverData.action == LeverAction.LeverUp) {
            require(_isExactInput); // dev: WTF

            uint256 _leastAssetReceived = (((_amountToPay *
                (MAX_BPS - slippageAllowedBps)) / MAX_BPS) *
                _leverData.assetPerWeth) / ONE_WAD;
            require(_amountReceived >= _leastAssetReceived, "!slippage"); // dev: too much slippage

            uint256 _collateralToAdd = _looseAssets();
            if (!positionOpen) {
                positionOpen = true;
                _openPosition(_amountToPay, _collateralToAdd, ONE_WAD); // TODO: set real price
            } else {
                _depositAndDraw(_amountToPay, _collateralToAdd, ONE_WAD, false);
            }

            ERC20(WETH).transfer(msg.sender, _amountToPay);
        } else if (
            _leverData.action == LeverAction.LeverDown ||
            _leverData.action == LeverAction.ClosePosition
        ) {
            require(!_isExactInput); // dev: WTF
            uint256 _expectedAssetToPay = (_amountReceived *
                _leverData.assetPerWeth) / ONE_WAD;
            uint256 _mostAssetToPay = (_expectedAssetToPay *
                (MAX_BPS + slippageAllowedBps)) / MAX_BPS;

            require(_amountToPay <= _mostAssetToPay, "!slippage"); // dev: too much slippage

            if (_amountToPay > _expectedAssetToPay) {
                // pass slippage onto the asset to free amount
                uint256 _slippage = _amountToPay - _expectedAssetToPay;
                if (_leverData.assetToFree > _slippage) {
                    _leverData.assetToFree -= _slippage;
                } else {
                    _leverData.assetToFree = 0;
                }
            }

            if (_leverData.action == LeverAction.LeverDown) {
                _repayWithdraw(
                    _amountReceived,
                    Math.min(
                        _amountToPay + _leverData.assetToFree,
                        _leverData.totalCollateral
                    ),
                    false
                );
            } else if (_leverData.action == LeverAction.ClosePosition) {
                positionOpen = false;
                _repayAndClose(_amountReceived);
            }
            asset.transfer(msg.sender, _amountToPay);
        } else if (_leverData.action == LeverAction.ManualSwap) {
            //require(_isExactInput, "!wtf"); // dev: WTF

            if (
                (_amount0Delta > 0 && uniswapAsset0Weth1) ||
                (_amount1Delta > 0 && !uniswapAsset0Weth1)
            ) {
                asset.transfer(msg.sender, _amountToPay);
            } else {
                ERC20(WETH).transfer(msg.sender, _amountToPay);
            }
        }
    }

    /**************************************************
     *               INTERNAL VIEWS                   *
     **************************************************/

    /**
     *  @notice Returns the strategy assets which are held as loose asset
     *  @return . The strategy's loose asset
     */
    function _looseAssets() internal view returns (uint256) {
        return asset.balanceOf(address(this));
    }

    /**
     *  @notice Returns the strategy assets which are not idle
     *  @return . The strategy's total debt
     */
    function _deployedAssets() internal view returns (uint256) {
        return _deployedAssets(TokenizedStrategy.totalAssets());
    }

    /**
     *  @notice Returns the strategy assets which are not idle
     *  @return . The strategy's total debt
     */
    function _deployedAssets(uint256 _totalAssets)
        internal
        view
        returns (uint256)
    {
        uint256 _idle = _looseAssets();
        if (_idle >= _totalAssets) return 0;
        return _totalAssets - _idle;
    }

    /**
     *  @notice Retrieves info related to our debt position
     *  @return _debt             Current debt owed (`WAD`).
     *  @return _collateral       Pledged collateral, including encumbered (`WAD`).
     *  @return _t0Np             `Neutral price` (`WAD`).
     *  @return _thresholdPrice   Borrower's `Threshold Price` (`WAD`).
     */
    function _positionInfo()
        internal
        view
        returns (
            uint256 _debt,
            uint256 _collateral,
            uint256 _t0Np,
            uint256 _thresholdPrice
        )
    {
        //return
        //    POOL_INFO_UTILS.borrowerInfo(
        //        address(ajnaPool),
        //        address(summerfiAccount)
        //    );

        // TODO: copied from BUSL, am i going to open source jail?
        (uint256 inflator, uint256 lastInflatorUpdate) = ajnaPool
            .inflatorInfo();

        (uint256 interestRate, ) = ajnaPool.interestRateInfo();

        uint256 pendingInflator = PoolCommons.pendingInflator(
            inflator,
            lastInflatorUpdate,
            interestRate
        );

        uint256 t0Debt;
        uint256 npTpRatio;
        (t0Debt, _collateral, npTpRatio) = ajnaPool.borrowerInfo(
            address(summerfiAccount)
        );

        _t0Np = _collateral == 0
            ? 0
            : Math.mulDiv(
                Maths.wmul(t0Debt, COLLATERALIZATION_FACTOR),
                npTpRatio,
                _collateral
            );
        _debt = Maths.ceilWmul(t0Debt, pendingInflator);
        _thresholdPrice = _collateral == 0
            ? 0
            : Maths.wmul(
                Maths.wdiv(_debt, _collateral),
                COLLATERALIZATION_FACTOR
            );
    }

    /**
     *  @notice Returns the amount of quote token available for borrowing or removing from pool.
     *  @dev    Calculated as the difference between pool balance and escrowed amounts locked in
     *  pool (auction bons + unclaimed reserves).
     *  @return _amount   The total quote token amount available to borrow or to be removed from pool, in `WAD` units.
     */
    function _availableWethBorrow() internal view returns (uint256 _amount) {
        //return POOL_INFO_UTILS.availableQuoteTokenAmount(address(ajnaPool));
        // TODO: copied from BUSL, am i going to open source jail?
        (uint256 bondEscrowed, uint256 unclaimedReserve, , , ) = ajnaPool
            .reservesInfo();
        uint256 escrowedAmounts = bondEscrowed + unclaimedReserve;

        uint256 poolBalance = ERC20(WETH).balanceOf(address(ajnaPool)) *
            ajnaPool.quoteTokenScale();

        if (poolBalance > escrowedAmounts)
            _amount = poolBalance - escrowedAmounts;
    }

    /**
     *  @notice Retrieves the oracle rate asset/quoteToken
     *  @return Conversion rate
     */
    function _getAssetPerWeth() internal view returns (uint256) {
        uint256 _answer = (ONE_WAD**2) /
            uint256(chainlinkOracle.latestAnswer());
        if (oracleWrapped) {
            return _answer;
        }
        return _unwrappedToWrappedAsset(_answer);
    }

    /**************************************************
     *               INTERNAL SETTERS                 *
     **************************************************/

    function _setUniswapFee(uint24 _fee) internal {
        IUniswapV3Pool _uniswapPool = IUniswapV3Pool(
            UNISWAP_FACTORY.getPool(address(asset), WETH, _fee)
        );
        require(
            _uniswapPool.token0() == address(asset) ||
                _uniswapPool.token1() == address(asset)
        ); // dev: pool must contain asset
        require(
            _uniswapPool.token0() == address(WETH) ||
                _uniswapPool.token1() == address(WETH)
        ); // dev: pool must contain weth
        uniswapPool = _uniswapPool;
    }

    /**************************************************
     *          POSITION HELPER FUNCTIONS             *
     **************************************************/

    /**
     *  @notice Open position via account proxy
     *  @param  _debtAmount     Amount of debt to borrow
     *  @param  _collateralAmount Amount of collateral to deposit
     *  @param  _price          Price of the bucket
     */
    function _openPosition(
        uint256 _debtAmount,
        uint256 _collateralAmount,
        uint256 _price
    ) internal {
        summerfiAccount.execute(
            address(SUMMERFI_AJNA_PROXY_ACTIONS),
            abi.encodeCall(
                SUMMERFI_AJNA_PROXY_ACTIONS.openPosition,
                (ajnaPool, _debtAmount, _collateralAmount, _price)
            )
        );
        IWETH(WETH).deposit{value: address(this).balance}(); // summer contracts use Ether not WETH
    }

    /**
     *  @notice Deposit collateral and draw debt via account proxy
     *  @param  _debtAmount     Amount of debt to borrow
     *  @param  _collateralAmount Amount of collateral to deposit
     *  @param  _price          Price of the bucket
     *  @param  _stamp      Whether to stamp the loan or not
     */
    function _depositAndDraw(
        uint256 _debtAmount,
        uint256 _collateralAmount,
        uint256 _price,
        bool _stamp
    ) internal {
        summerfiAccount.execute(
            address(SUMMERFI_AJNA_PROXY_ACTIONS),
            abi.encodeCall(
                SUMMERFI_AJNA_PROXY_ACTIONS.depositAndDraw,
                (ajnaPool, _debtAmount, _collateralAmount, _price, _stamp)
            )
        );
        IWETH(WETH).deposit{value: address(this).balance}(); // summer contracts use Ether not WETH
    }

    /**
     *  @notice Repay debt and withdraw collateral via account proxy
     *  @param  _debtAmount     Amount of debt to repay
     *  @param  _collateralAmount Amount of collateral to withdraw
     *  @param  _stamp      Whether to stamp the loan or not
     */
    function _repayWithdraw(
        uint256 _debtAmount,
        uint256 _collateralAmount,
        bool _stamp
    ) internal {
        if (_debtAmount != 0) {
            IWETH(WETH).withdraw(_debtAmount); // summer contracts use Ether not WETH
        }
        summerfiAccount.execute{value: _debtAmount}(
            address(SUMMERFI_AJNA_PROXY_ACTIONS),
            abi.encodeCall(
                SUMMERFI_AJNA_PROXY_ACTIONS.repayWithdraw,
                (ajnaPool, _debtAmount, _collateralAmount, _stamp)
            )
        );
    }

    /**
     *  @notice Repay debt and close position via account proxy
     */
    function _repayAndClose(uint256 _debtAmount) internal {
        if (_debtAmount != 0) {
            IWETH(WETH).withdraw(_debtAmount); // summer contracts use Ether not WETH
        }
        summerfiAccount.execute{value: _debtAmount}(
            address(SUMMERFI_AJNA_PROXY_ACTIONS),
            abi.encodeCall(
                SUMMERFI_AJNA_PROXY_ACTIONS.repayAndClose,
                (ajnaPool)
            )
        );
        uint256 _balance = address(this).balance;
        if (_balance != 0) {
            IWETH(WETH).deposit{value: _balance}();
        }
    }

    function _unwrappedToWrappedAsset(uint256 _amount)
        internal
        view
        returns (uint256)
    {
        (bool success, bytes memory data) = address(asset).staticcall(
            abi.encodeWithSelector(unwrappedToWrappedSelector, _amount)
        );
        require(success, "!success"); // dev: static call failed
        return abi.decode(data, (uint256));
    }

    function _minLoanSize() internal view returns (uint256 _minDebtAmount) {
        IERC20Pool _ajnaPool = ajnaPool;
        (uint256 _poolDebt, , , ) = _ajnaPool.debtInfo();
        (, , uint256 _noOfLoans) = _ajnaPool.loansInfo();

        if (_noOfLoans != 0) {
            // minimum debt is 10% of the average loan size
            _minDebtAmount = (_poolDebt / _noOfLoans) / 10;
        }
    }

    /************************************************************************
     *                      Position Math Functions                         *
     ************************************************************************/

    function _getBorrowFromSupply(
        uint256 _supply,
        uint256 _collatRatio,
        uint256 _assetPerWeth
    ) internal pure returns (uint256) {
        if (_collatRatio == 0) {
            return 0;
        }
        return
            (((_supply * _collatRatio) / (ONE_WAD - _collatRatio)) * ONE_WAD) /
            _assetPerWeth;
    }

    function _calculateLTV(
        uint256 _debt,
        uint256 _collateral,
        uint256 _assetPerWeth
    ) internal pure returns (uint256) {
        if (_debt == 0 || _collateral == 0) {
            return 0;
        }
        return (_debt * _assetPerWeth) / _collateral;
    }

    function _calculateNetPositionWithMaxSlippage(
        uint256 _debt,
        uint256 _collateral,
        uint256 _assetPerWeth
    ) internal view returns (uint256) {
        // inflate debt by max slippage value
        _debt = (_debt * (MAX_BPS + slippageAllowedBps)) / MAX_BPS;
        return _calculateNetPosition(_debt, _collateral, _assetPerWeth);
    }

    function _calculateNetPosition(
        uint256 _debt,
        uint256 _collateral,
        uint256 _assetPerWeth
    ) internal pure returns (uint256) {
        _debt = (_debt * _assetPerWeth) / ONE_WAD;
        if (_debt >= _collateral || _collateral == 0) {
            return 0;
        }
        unchecked {
            return _collateral - _debt;
        }
    }

    // Needed to receive ETH
    receive() external payable {}
}

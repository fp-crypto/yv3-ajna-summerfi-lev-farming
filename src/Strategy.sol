// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.18;

import {BaseStrategy, ERC20} from "@tokenized-strategy/BaseStrategy.sol";
import {IStrategyInterface} from "./interfaces/IStrategyInterface.sol";
import {UniswapV3Swapper} from "@periphery/swappers/UniswapV3Swapper.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IWETH} from "./interfaces/IWeth.sol";
import {IERC20Pool} from "@ajna-core/interfaces/pool/erc20/IERC20Pool.sol";
import {PoolInfoUtils} from "@ajna-core/PoolInfoUtils.sol";
import {AjnaProxyActions} from "./interfaces/summerfi/AjnaProxyActions.sol";
import {IAjnaRedeemer} from "./interfaces/summerfi/IAjnaRedeemer.sol";
import {IBalancer} from "./interfaces/balancer/IBalancer.sol";
import {IChainlinkAggregator} from "./interfaces/chainlink/IChainlinkAggregator.sol";

interface IAccountFactory {
    function createAccount() external returns (address);

    function createAccount(address user) external returns (address);
}

interface IAccount {
    function send(address _target, bytes calldata _data) external payable;

    function execute(
        address _target,
        bytes memory _data
    ) external payable returns (bytes32);
}

contract Strategy is BaseStrategy, UniswapV3Swapper {
    using SafeERC20 for ERC20;

    IAccountFactory private constant SUMMERFI_ACCOUNT_FACTORY =
        IAccountFactory(0xF7B75183A2829843dB06266c114297dfbFaeE2b6);
    AjnaProxyActions private constant SUMMERFI_AJNA_PROXY_ACTIONS =
        AjnaProxyActions(0x3637DF43F938b05A71bb828f13D9f14498E6883c);
    PoolInfoUtils private constant POOL_INFO_UTILS =
        PoolInfoUtils(0x30c5eF2997d6a882DE52c4ec01B6D0a5e5B4fAAE);
    IAjnaRedeemer private constant SUMMERFI_REWARDS =
        IAjnaRedeemer(0xf309EE5603bF05E5614dB930E4EAB661662aCeE6);
    IBalancer private constant BALANCER_VAULT =
        IBalancer(0xBA12222222228d8Ba445958a75a0704d566BF2C8);

    address public WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address public AJNA_TOKEN = 0x9a96ec9B57Fb64FbC60B423d1f4da7691Bd35079;

    IAccount public immutable summerfiAccount;
    IERC20Pool public immutable ajnaPool;
    IChainlinkAggregator public immutable chainlinkOracle;
    bool public immutable oracleWrapped;

    bytes4 private immutable unwrappedToWrappedSelector;

    bool private flashloanActive;
    bool private positionOpen;

    struct LTVConfig {
        uint64 targetLTV;
        uint64 minAdjustThreshold;
        uint64 warningThreshold;
        uint64 emergencyThreshold;
    }
    LTVConfig public ltvs;

    uint256 public depositLimit;
    uint256 public expectedFlashloanFee;
    uint256 public slippageAllowedBps = 50;

    uint256 private constant ONE_WAD = 1e18;
    uint256 private constant MAX_BPS = 1e4; // 100% in basis points
    uint64 internal constant DEFAULT_MIN_ADJUST_THRESHOLD = 0.005e18;
    uint64 internal constant DEFAULT_WARNING_THRESHOLD = 0.02e18;
    uint64 internal constant DEFAULT_EMERGENCY_THRESHOLD = 0.01e18;

    constructor(
        address _asset,
        string memory _name,
        IERC20Pool _ajnaPool,
        bytes4 _unwrappedToWrappedSelector,
        IChainlinkAggregator _chainlinkOracle,
        bool _oracleWrapped
    ) BaseStrategy(_asset, _name) {
        require(_asset == _ajnaPool.collateralAddress(), "!collat"); // dev: asset must be collateral

        address _quoteToken = _ajnaPool.quoteTokenAddress();
        require(WETH == _ajnaPool.quoteTokenAddress(), "!weth"); // dev: quoteToken must be WETH

        address _summerfiAccount = SUMMERFI_ACCOUNT_FACTORY.createAccount();

        ajnaPool = _ajnaPool;
        summerfiAccount = IAccount(_summerfiAccount);
        unwrappedToWrappedSelector = _unwrappedToWrappedSelector;
        chainlinkOracle = _chainlinkOracle;
        oracleWrapped = _oracleWrapped;

        ERC20(_asset).safeApprove(_summerfiAccount, type(uint256).max);
        ERC20(WETH).safeApprove(address(BALANCER_VAULT), type(uint256).max);

        LTVConfig memory _ltvs;
        _ltvs.targetLTV = 0.5e18; // TODO: delete this
        _ltvs.minAdjustThreshold = DEFAULT_MIN_ADJUST_THRESHOLD;
        _ltvs.warningThreshold = DEFAULT_WARNING_THRESHOLD;
        _ltvs.emergencyThreshold = DEFAULT_EMERGENCY_THRESHOLD;
        ltvs = _ltvs;

        depositLimit = 2 ** 256 - 1; // TODO: delete this

        _setUniFees(_asset, WETH, 100);
        _setUniFees(AJNA_TOKEN, WETH, 10000);
    }

    function setLtvConfig(LTVConfig memory _ltvs) external onlyManagement {
        require(_ltvs.warningThreshold < _ltvs.emergencyThreshold); // dev: warning must be less then emergency threshold
        ltvs = _ltvs;
    }

    function setUniFee(address _token, uint24 _fee) external onlyManagement {
        require(_token == address(asset) || _token == AJNA_TOKEN); // dev: must be asset or ajna token
        _setUniFees(_token, WETH, _fee);
    }

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
        // TODO: implement withdraw logic EX:
        //
        //      lendingPool.withdraw(address(asset), _amount);
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
        _adjustPosition();
        (uint256 _debt, uint256 _collateral, , ) = _positionInfo();
        _totalAssets =
            asset.balanceOf(address(this)) +
            _collateral -
            _unwrappedToWrappedAsset(_debt); // TODO: Better conversion from quote to asset
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
     * a full report for.
     *
     *   EX: A strategy that can not deposit funds without getting
     *       sandwiched can use the tend when a certain threshold
     *       of idle to totalAssets has been reached.
     *
     * The TokenizedStrategy contract will do all needed debt and idle updates
     * after this has finished and will have no effect on PPS of the strategy
     * till report() is called.
     *
     * @param _totalIdle The current amount of idle funds that are available to deploy.
     *
     */
    function _tend(uint256 _totalIdle) internal override {
        _adjustPosition();
    }

    /**
     * @dev Optional trigger to override if tend() will be used by the strategy.
     * This must be implemented if the strategy hopes to invoke _tend().
     *
     * @return . Should return true if tend() should be called by keeper or false if not.
     *
    function _tendTrigger() internal view override returns (bool) {}
    */

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
        address _owner
    ) public view override returns (uint256) {
        uint256 _totalAssets = TokenizedStrategy.totalAssets();
        return _totalAssets >= depositLimit ? 0 : depositLimit - _totalAssets;
    }

    /**
     * @dev Claims summerfi ajna rewards
     *
     * Unguarded because there is no risk claiming
     *
     * @param _weeks An array of week numbers for which to claim rewards.
     * @param _amounts An array of reward amounts to claim.
     * @param _proofs An array of Merkle proofs, one for each corresponding week and amount given.
     */
    function redeemSummerAjnaRewards(
        uint256[] calldata _weeks,
        uint256[] calldata _amounts,
        bytes32[][] calldata _proofs
    ) external {
        SUMMERFI_REWARDS.claimMultiple(_weeks, _amounts, _proofs);
    }

    /**
     * @notice Gets the max amount of `asset` that can be withdrawn.
     * @dev Defaults to an unlimited amount for any address. But can
     * be overridden by strategists.
     *
     * This function will be called before any withdraw or redeem to enforce
     * any limits desired by the strategist. This can be used for illiquid
     * or sandwichable strategies. It should never be lower than `totalIdle`.
     *
     *   EX:
     *       return TokenIzedStrategy.totalIdle();
     *
     * This does not need to take into account the `_owner`'s share balance
     * or conversion rates from shares to assets.
     *
     * @param . The address that is withdrawing from the strategy.
     * @return . The available amount that can be withdrawn in terms of `asset`
     *
    function availableWithdrawLimit(
        address _owner
    ) public view override returns (uint256) {
        TODO: If desired Implement withdraw limit logic and any needed state variables.
        
        EX:    
            return TokenizedStrategy.totalIdle();
    }
    */

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
    function _emergencyWithdraw(uint256 _amount) internal override {
        TODO: If desired implement simple logic to free deployed funds.

        EX:
            _amount = min(_amount, aToken.balanceOf(address(this)));
            _freeFunds(_amount);
    }

    **/

    /**
     * @notice Adjusts the leveraged position
     */
    function _adjustPosition() internal {
        uint256 _totalIdle = asset.balanceOf(address(this));
        (
            uint256 _debt,
            uint256 _collateral,
            ,
            uint256 _thresholdPrice
        ) = _positionInfo();
        LTVConfig memory _ltvs = ltvs;
        uint256 _price = _assetPerWeth();
        uint256 _currentLtv = _calculateLTV(_collateral, _debt, _price);

        if (
            positionOpen &&
            (_price <= _thresholdPrice ||
                _currentLtv >= _ltvs.targetLTV + _ltvs.minAdjustThreshold)
        ) {
            //_leverDown(_debt, _collateral, 0, _ltvs);
        } else if (_currentLtv <= _ltvs.targetLTV - _ltvs.minAdjustThreshold) {
            _leverUp(_debt, _collateral, _totalIdle, _ltvs, _price);
        } else {
            return; // bail out if we are doing nothing
        }

        (_debt, _collateral, , _thresholdPrice) = _positionInfo();
        _currentLtv = _calculateLTV(_collateral, _debt, _price);
        // TODO: consider what the best check would be
        //require(_currentLtv < _ltvs.targetLTV + _ltvs.minAdjustThreshold); // dev: not safe
    }

    // TODO: delete this
    event LeverUp(uint256 borrow, uint256 collateral, uint256 targetLTV);

    /**
     * @notice Levers up
     */
    function _leverUp(
        uint256 _debt,
        uint256 _collateral,
        uint256 _totalIdle,
        LTVConfig memory _ltvs,
        uint256 _assetPerWeth
    ) internal {
        uint256 _targetBorrow = _getBorrowFromSupply(
            _collateral + _totalIdle,
            _ltvs.targetLTV,
            _assetPerWeth
        );
        require(_targetBorrow > _debt); // dev: something is very wrong
        uint256 _toBorrow = _targetBorrow - _debt;
        bytes memory _flashLoanData = abi.encode(true, uint256(0));
        emit LeverUp(_totalIdle, _collateral + _totalIdle, _ltvs.targetLTV);
        _initFlashLoan(_toBorrow, _flashLoanData);
    }

    /**
     * @notice Levers down
     */
    function _leverDown(
        uint256 _debt,
        uint256 _collateral,
        uint256 _collateralToFree,
        LTVConfig memory _ltvs
    ) internal {
        uint256 _repaymentAmount;
        if (_collateralToFree > _collateral) {
            _collateralToFree = _collateral;
        }

        uint256 _targetBorrow = _getBorrowFromSupply(
            _collateral - _collateralToFree,
            _ltvs.targetLTV,
            _assetPerWeth()
        );

        require(_targetBorrow <= _debt); // dev: something is very wrong
        _repaymentAmount = _debt - _targetBorrow;
        uint256 _collateralToWithdraw = _collateralToFree +
            ((_unwrappedToWrappedAsset(_repaymentAmount) *
                (MAX_BPS + slippageAllowedBps)) / MAX_BPS); // TODO: This calculation is wrong
        bytes memory _flashLoanData = abi.encode(false, _collateralToWithdraw);
        _initFlashLoan(_repaymentAmount, _flashLoanData);
    }

    // ----------------- FLASHLOAN -----------------
    /**
     *  @notice Initiate flash loan via balancer
     *  @param  _amount     Amount to flashloan
     *  @param  _data       Byte array to send with the flashloan
     */
    function _initFlashLoan(uint256 _amount, bytes memory _data) internal {
        address[] memory _tokens = new address[](1);
        _tokens[0] = address(WETH);
        uint256[] memory _amounts = new uint256[](1);
        _amounts[0] = _amount;
        flashloanActive = true;
        IBalancer(BALANCER_VAULT).flashLoan(
            address(this),
            _tokens,
            _amounts,
            _data
        );
    }

    // ----------------- FLASHLOAN CALLBACK -----------------
    function receiveFlashLoan(
        ERC20[] calldata,
        uint256[] calldata _amounts,
        uint256[] calldata _fees,
        bytes calldata _data
    ) external {
        require(msg.sender == address(BALANCER_VAULT));
        require(flashloanActive == true);
        flashloanActive = false;
        uint256 _fee = _fees[0];
        require(_fee <= expectedFlashloanFee); // dev: flashloan fee too high
        (bool _leverUp, uint256 _collateralAmount) = abi.decode(
            _data,
            (bool, uint256)
        );
        uint256 _debtAmount = _amounts[0];
        if (_leverUp) {
            // Exact input swap
            _swapFrom(WETH, address(asset), _debtAmount, 0); // TODO: set minOut to a slippage value
            uint256 _collateralToAdd = asset.balanceOf(address(this));
            if (!positionOpen) {
                positionOpen = true;
                _openPosition(_debtAmount + ONE_WAD, _collateralToAdd, ONE_WAD); // TODO: set real price
            } else {
                _depositAndDraw(_debtAmount, _collateralToAdd, ONE_WAD, false);
            }
        }
        /* leverDown */
        else {
            // TODO: lever down logic
            _repayWithdraw(_debtAmount, _collateralAmount, false);
            // Exact output swap
            _swapTo(address(asset), WETH, _debtAmount, 0); // TODO: set maxIn to a slippage value
        }
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
        return
            POOL_INFO_UTILS.borrowerInfo(
                address(ajnaPool),
                address(summerfiAccount)
            );
    }

    /**
     *  @notice Retrieves the oracle rate asset/quoteToken
     *  @return Conversion rate
     */
    function _assetPerWeth() internal view returns (uint256) {
        uint256 _answer = (ONE_WAD ** 2) /
            uint256(chainlinkOracle.latestAnswer());
        if (oracleWrapped) {
            return _answer;
        }
        return _unwrappedToWrappedAsset(_answer);
    }

    /***************************************
     *      POSITION HELPER FUNCTIONS      *
     ***************************************/

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
        IWETH(WETH).withdraw(_debtAmount); // summer contracts use Ether not WETH
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
    function _repayAndClose() internal {
        // TODO: Consider how to handle Ether <-> WETH Conversion
        //IWETH(WETH).withdraw(_debtAmount); // summer contracts use Ether not WETH
        summerfiAccount.execute(
            address(SUMMERFI_AJNA_PROXY_ACTIONS),
            abi.encodeCall(
                SUMMERFI_AJNA_PROXY_ACTIONS.repayAndClose,
                (ajnaPool)
            )
        );
    }

    function _unwrappedToWrappedAsset(
        uint256 _amount
    ) internal view returns (uint256) {
        (bool success, bytes memory data) = address(asset).staticcall(
            abi.encodeWithSelector(unwrappedToWrappedSelector, _amount)
        );
        require(success, "!success"); // dev: static call failed
        return abi.decode(data, (uint256));
    }

    /************************************************************************
     *                          LTV Math Functions                          *
     ************************************************************************/

    // function getBorrowFromDeposit(uint256 _deposit, uint256 _collatRatio)
    //     internal
    //     pure
    //     returns (uint256)
    // {
    //     return deposit.mul(collatRatio).div(COLLATERAL_RATIO_PRECISION);
    // }

    // function getDepositFromBorrow(uint256 _borrow, uint256 _collatRatio)
    //     internal
    //     pure
    //     returns (uint256)
    // {
    //     return borrow.mul(COLLATERAL_RATIO_PRECISION).div(collatRatio);
    // }

    function _getBorrowFromSupply(
        uint256 _supply,
        uint256 _collatRatio,
        uint256 _assetPerWeth
    ) internal pure returns (uint256) {
        if (_collatRatio == 0) {
            return 0;
        }
        //return (((_supply * _collatRatio) / (ONE_WAD - _collatRatio)));
        return
            (((_supply * _collatRatio) / (ONE_WAD - _collatRatio)) * ONE_WAD) /
            _assetPerWeth;
    }

    function _calculateLTV(
        uint256 _collateralAmount,
        uint256 _debtAmount,
        uint256 _assetPerWeth
    ) internal pure returns (uint256) {
        if (_collateralAmount == 0 || _debtAmount == 0) {
            return 0;
        }
        return (_debtAmount * _assetPerWeth) / _collateralAmount;
    }

    // Needed to receive ETH
    receive() external payable {}
}

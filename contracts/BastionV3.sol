//SPDX-License-Identifier: MIT

pragma solidity 0.8.17;

import {IBastionV3} from "./interfaces/IBastionV3.sol";
import {IFlashLiquidityFactory} from "./interfaces/IFlashLiquidityFactory.sol";
import {IFlashLiquidityRouter} from "./interfaces/IFlashLiquidityRouter.sol";
import {IFlashLiquidityPair} from "./interfaces/IFlashLiquidityPair.sol";
import {ILiquidFarm} from "./interfaces/ILiquidFarm.sol";
import {ILiquidFarmFactory} from "./interfaces/ILiquidFarmFactory.sol";
import {IWETH} from "./interfaces/IWETH.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {IERC20, ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Governable} from "./types/Guardable.sol";
import {Guardable} from "./types/Guardable.sol";
import {FullMath} from "./libraries/FullMath.sol";

contract BastionV3 is IBastionV3, Governable, Guardable {
    using SafeERC20 for IERC20;

    address public immutable factory;
    address public immutable router;
    address public immutable farmFactory;
    IWETH public immutable weth;
    uint256 public maxDeviationFactor;
    uint256 public maxStaleness;
    uint256 public whitelistDelay = 3 days;
    mapping(address => bool) public isExtManagerSetter;
    mapping(address => bool) public isWhitelisted;
    mapping(address => uint256) public whitelistReqTimestamp;
    mapping(address => AggregatorV3Interface) internal priceFeeds;
    mapping(address => uint256) internal tokenDecimals;

    error AlreadyWhitelisted();
    error AlreadyRequested();
    error WhitelistingNotRequested();
    error NotWhitelisted();
    error NotManagerSetter();
    error CannotConvert();
    error ZeroAmount();
    error InvalidPrice();
    error InvalidPair();
    error InvalidFarm();
    error AmountOutTooLow();
    error ReservesValuesMismatch();
    error MissingPriceFeed();
    error DecimalsMismatch();
    error StalenessToHigh();

    event DeviatonFactorChanged(uint256 indexed newFactor);
    event StalenessChanged(uint256 indexed newStaleness);
    event ExtManagerSettersChanged(address[] indexed setters, bool[] indexed isSetter);
    event PriceFeedsChanged(address[] indexed tokens, address[] indexed priceFeeds);
    event TokensDecimalsChanged(address[] indexed tokens, uint256[] indexed decimals);
    event TokensTransferred(
        address indexed recipient,
        address[] indexed tokens,
        uint256[] indexed amounts
    );

    event Swapped(address indexed tokenA, address indexed tokenB, uint256 amountA, uint256 amountB);

    event Liquefied(
        address indexed token0,
        address indexed token1,
        uint256 token0Amount,
        uint256 token1Amount
    );

    event Solidified(
        address indexed token0,
        address indexed token1,
        uint256 token0Amount,
        uint256 token1Amount
    );

    event Staked(address indexed lpToken, uint256 indexed amount);
    event Unstaked(address indexed lpToken, uint256 indexed amount);
    event ClaimedRewards(address indexed farm, address indexed lpToken);
    event UnstakedAndClaimed(address indexed farm, address indexed lpToken);

    constructor(
        address _governor,
        address _guardian,
        address _factory,
        address _router,
        address _farmFactory,
        IWETH _weth,
        uint256 _maxDeviationFactor,
        uint256 _maxStaleness,
        uint256 _transferGovernanceDelay
    ) Governable(_governor, _transferGovernanceDelay) Guardable(_guardian) {
        factory = _factory;
        router = _router;
        farmFactory = _farmFactory;
        weth = _weth;
        maxDeviationFactor = _maxDeviationFactor;
        maxStaleness = _maxStaleness;
    }

    receive() external payable {}

    function requestWhitelisting(address[] calldata _recipients)
        external
        onlyGuardian
        whenNotPaused
    {
        for (uint256 i = 0; i < _recipients.length; ) {
            if (isWhitelisted[_recipients[i]]) {
                revert AlreadyWhitelisted();
            }
            if (whitelistReqTimestamp[_recipients[i]] != 0) {
                revert AlreadyRequested();
            }
            whitelistReqTimestamp[_recipients[i]] = block.timestamp;
            unchecked {
                i++;
            }
        }
    }

    function abortWhitelisting(address[] calldata _recipients) external onlyGuardian {
        for (uint256 i = 0; i < _recipients.length; ) {
            if (isWhitelisted[_recipients[i]]) {
                revert AlreadyWhitelisted();
            }
            if (whitelistReqTimestamp[_recipients[i]] == 0) {
                revert WhitelistingNotRequested();
            }
            whitelistReqTimestamp[_recipients[i]] = 0;
            unchecked {
                i++;
            }
        }
    }

    function executeWhitelisting(address[] calldata _recipients)
        external
        onlyGovernor
        whenNotPaused
    {
        uint256 _whitelistDelay = whitelistDelay;
        for (uint256 i = 0; i < _recipients.length; ) {
            uint256 _timestamp = whitelistReqTimestamp[_recipients[i]];
            if (isWhitelisted[_recipients[i]]) {
                revert AlreadyWhitelisted();
            }
            if (whitelistReqTimestamp[_recipients[i]] == 0) {
                revert WhitelistingNotRequested();
            }
            if (block.timestamp - _timestamp < _whitelistDelay) {
                revert TooEarly();
            }
            isWhitelisted[_recipients[i]] = true;
            whitelistReqTimestamp[_recipients[i]] = 0;
            unchecked {
                i++;
            }
        }
    }

    function removeFromWhitelist(address[] calldata _recipients) external onlyGuardian {
        for (uint256 i = 0; i < _recipients.length; ) {
            if (!isWhitelisted[_recipients[i]]) {
                revert NotWhitelisted();
            }
            isWhitelisted[_recipients[i]] = false;
            unchecked {
                i++;
            }
        }
    }

    function transferToWhitelisted(
        address _recipient,
        address[] calldata _tokens,
        uint256[] calldata _amounts
    ) external onlyGovernor whenNotPaused {
        if (!isWhitelisted[_recipient]) {
            revert NotWhitelisted();
        }
        for (uint256 i = 0; i < _tokens.length; ) {
            IERC20(_tokens[i]).safeTransfer(_recipient, _amounts[i]);
            unchecked {
                i++;
            }
        }
        emit TokensTransferred(_recipient, _tokens, _amounts);
    }

    function setMaxDeviationFactor(uint256 _maxDeviationFactor) external onlyGovernor {
        maxDeviationFactor = _maxDeviationFactor;
        emit DeviatonFactorChanged(_maxDeviationFactor);
    }

    function setMaxStaleness(uint256 _maxStaleness) external onlyGovernor {
        maxStaleness = _maxStaleness;
        emit StalenessChanged(_maxStaleness);
    }

    function setPairManager(address _pair, address _manager) public {
        if (!isExtManagerSetter[msg.sender]) {
            revert NotManagerSetter();
        }
        IFlashLiquidityFactory(factory).setPairManager(_pair, _manager);
    }

    function setMainManagerSetter(address _managerSetter) external onlyGovernor {
        IFlashLiquidityFactory(factory).setPairManagerSetter(_managerSetter);
    }

    function setExtManagerSetters(address[] calldata _extManagerSetters, bool[] calldata _enabled)
        external
        onlyGovernor
    {
        for (uint256 i = 0; i < _extManagerSetters.length; ) {
            isExtManagerSetter[_extManagerSetters[i]] = _enabled[i];
            unchecked {
                i++;
            }
        }
        emit ExtManagerSettersChanged(_extManagerSetters, _enabled);
    }

    function setPriceFeeds(address[] calldata _tokens, address[] calldata _priceFeeds)
        external
        onlyGovernor
    {
        for (uint256 i = 0; i < _tokens.length; ) {
            priceFeeds[_tokens[i]] = AggregatorV3Interface(_priceFeeds[i]);
            unchecked {
                i++;
            }
        }
        emit PriceFeedsChanged(_tokens, _priceFeeds);
    }

    function setTokensDecimals(address[] calldata _tokens, uint256[] calldata _decimals)
        external
        onlyGovernor
    {
        for (uint256 i = 0; i < _tokens.length; ) {
            tokenDecimals[_tokens[i]] = _decimals[i];
            unchecked {
                i++;
            }
        }
        emit TokensDecimalsChanged(_tokens, _decimals);
    }

    function wrapETH(uint256 _amount) external onlyGovernor {
        weth.deposit{value: _amount}();
    }

    function swap(
        address _tokenIn,
        address _tokenOut,
        uint256 _amountIn
    ) external onlyGovernor whenNotPaused {
        IFlashLiquidityFactory _factory = IFlashLiquidityFactory(factory);
        IFlashLiquidityPair _pair = IFlashLiquidityPair(_factory.getPair(_tokenIn, _tokenOut));
        if (address(_pair) == address(0)) {
            revert CannotConvert();
        }
        address _manager = _pair.manager();
        if (_manager != address(0)) {
            _swapOnSelfBalancingPool(_factory, _pair, _manager, _tokenIn, _tokenOut, _amountIn);
        } else {
            _swapOnOpenPool(_pair, _tokenIn, _tokenOut, _amountIn);
        }
    }

    function liquefy(
        address _token0,
        address _token1,
        uint256 _token0Amount,
        uint256 _token1Amount
    ) external onlyGovernor whenNotPaused {
        address manager = IFlashLiquidityPair(
            IFlashLiquidityFactory(factory).getPair(_token0, _token1)
        ).manager();
        if (manager != address(0)) {
            _liquefyOnSelfBalancingPool(_token0, _token1, _token0Amount, _token1Amount);
        } else {
            _liquefyOnOpenPool(_token0, _token1, _token0Amount, _token1Amount);
        }
    }

    function solidify(address _lpToken, uint256 _lpAmount) external onlyGovernor whenNotPaused {
        address _router = router;
        IFlashLiquidityPair _pair = IFlashLiquidityPair(_lpToken);
        _pair.approve(_router, _lpAmount);
        if (_pair.manager() != address(0)) {
            _solidifyFromSelfBalancingPool(_pair, _router, _lpAmount);
        } else {
            _solidifyFromOpenPool(_pair, _router, _lpAmount);
        }
        _pair.approve(_router, 0);
    }

    function stakeLpTokens(address _lpToken, uint256 _amount) external onlyGovernor whenNotPaused {
        ILiquidFarmFactory _arbFarmFactory = ILiquidFarmFactory(farmFactory);
        address _farm = _arbFarmFactory.lpTokenFarm(_lpToken);
        if (_farm == address(0)) {
            revert InvalidFarm();
        }
        IERC20 lpToken_ = IERC20(_lpToken);
        lpToken_.approve(_farm, _amount);
        ILiquidFarm(_farm).stake(_amount);
        lpToken_.approve(_farm, 0);
        emit Staked(_lpToken, _amount);
    }

    function unstakeLpTokens(address _lpToken, uint256 _amount)
        external
        onlyGovernor
        whenNotPaused
    {
        ILiquidFarmFactory _arbFarmFactory = ILiquidFarmFactory(farmFactory);
        address _farm = _arbFarmFactory.lpTokenFarm(_lpToken);
        if (_farm == address(0)) {
            revert InvalidFarm();
        }
        ILiquidFarm(_farm).withdraw(_amount);
        emit Unstaked(_lpToken, _amount);
    }

    function exitStaking(address _lpToken) external onlyGovernor whenNotPaused {
        ILiquidFarmFactory _arbFarmFactory = ILiquidFarmFactory(farmFactory);
        address _farm = _arbFarmFactory.lpTokenFarm(_lpToken);
        if (_farm == address(0)) {
            revert InvalidFarm();
        }
        ILiquidFarm(_farm).exit();
        emit UnstakedAndClaimed(_farm, _lpToken);
    }

    function claimStakingRewards(address _lpToken) external onlyGovernor whenNotPaused {
        ILiquidFarmFactory _arbFarmFactory = ILiquidFarmFactory(farmFactory);
        address _farm = _arbFarmFactory.lpTokenFarm(_lpToken);
        if (_farm == address(0)) {
            revert InvalidFarm();
        }
        ILiquidFarm(_farm).getReward();
        emit ClaimedRewards(_farm, _lpToken);
    }

    function _swapOnOpenPool(
        IFlashLiquidityPair _pair,
        address _tokenIn,
        address _tokenOut,
        uint256 _amountIn
    ) internal {
        uint256 _amountInWithFee = _amountIn * 9970;
        (uint256 _reserve0, uint256 _reserve1, ) = _pair.getReserves();
        uint256 _amountOutCheck;
        // avoid stack too deep
        {
            (
                uint256 _priceIn,
                uint256 _priceOut,
                uint256 _tokenInDecimals,
                uint256 _tokenOutDecimals
            ) = _getPricesAndDecimals(_tokenIn, _tokenOut);
            _amountOutCheck = FullMath.mulDiv(
                _amountIn,
                FullMath.mulDiv(_priceIn, _tokenOutDecimals, _priceOut),
                _tokenInDecimals
            );
        }
        uint256 _amountOut;
        if (_tokenIn == _pair.token0()) {
            _amountOut = FullMath.mulDiv(
                _amountInWithFee,
                _reserve1,
                (_reserve0 * 10000) + _amountInWithFee
            );
            if (_amountOut < _amountOutCheck - (_amountOutCheck / maxDeviationFactor)) {
                revert AmountOutTooLow();
            }
            IERC20(_tokenIn).safeTransfer(address(_pair), _amountIn);
            _pair.swap(0, _amountOut, address(this), new bytes(0));
        } else {
            _amountOut = FullMath.mulDiv(
                _amountInWithFee,
                _reserve0,
                (_reserve1 * 10000) + _amountInWithFee
            );
            if (_amountOut < _amountOutCheck - (_amountOutCheck / maxDeviationFactor)) {
                revert AmountOutTooLow();
            }
            IERC20(_tokenIn).safeTransfer(address(_pair), _amountIn);
            _pair.swap(_amountOut, 0, address(this), new bytes(0));
        }
        emit Swapped(_tokenIn, _tokenOut, _amountIn, _amountOut);
    }

    function _swapOnSelfBalancingPool(
        IFlashLiquidityFactory _factory,
        IFlashLiquidityPair _pair,
        address _manager,
        address _tokenIn,
        address _tokenOut,
        uint256 _amountIn
    ) internal {
        uint256 _amountInWithFee = _amountIn * 9994;
        _factory.setPairManager(address(_pair), address(this));
        (uint256 _reserve0, uint256 _reserve1, ) = _pair.getReserves();
        uint256 _amountOut;
        if (_tokenIn == _pair.token0()) {
            _amountOut = FullMath.mulDiv(
                _amountInWithFee,
                _reserve1,
                (_reserve0 * 10000) + _amountInWithFee
            );
            IERC20(_tokenIn).safeTransfer(address(_pair), _amountIn);
            _pair.swap(0, _amountOut, address(this), new bytes(0));
        } else {
            _amountOut = FullMath.mulDiv(
                _amountInWithFee,
                _reserve0,
                (_reserve1 * 10000) + _amountInWithFee
            );
            IERC20(_tokenIn).safeTransfer(address(_pair), _amountIn);
            _pair.swap(_amountOut, 0, address(this), new bytes(0));
        }
        _factory.setPairManager(address(_pair), _manager);
        emit Swapped(_tokenIn, _tokenOut, _amountIn, _amountOut);
    }

    function _liquefyOnOpenPool(
        address _token0,
        address _token1,
        uint256 _amountToken0,
        uint256 _amountToken1
    ) internal {
        address _router = router;
        uint256 _maxDeviationFactor = maxDeviationFactor;
        IERC20 token0_ = IERC20(_token0);
        IERC20 token1_ = IERC20(_token1);
        // avoid stack to deep
        {
            (
                uint256 _price0,
                uint256 _price1,
                uint256 _token0Decimals,
                uint256 _token1Decimals
            ) = _getPricesAndDecimals(_token0, _token1);
            (uint256 rate1to0, uint256 rate0to1) = (
                FullMath.mulDiv(uint256(_price1), _token0Decimals, uint256(_price0)),
                FullMath.mulDiv(uint256(_price0), _token1Decimals, uint256(_price1))
            );
            uint256 _zeroToOneAmount = FullMath.mulDiv(_amountToken1, rate1to0, _token1Decimals);
            if (_zeroToOneAmount != 0 && _zeroToOneAmount <= _amountToken0) {
                _amountToken0 = _zeroToOneAmount;
            } else {
                _amountToken1 = FullMath.mulDiv(_amountToken0, rate0to1, _token0Decimals);
            }
            if (_amountToken0 == 0 || _amountToken1 == 0) {
                revert ZeroAmount();
            }
        }
        token0_.approve(_router, _amountToken0);
        token1_.approve(_router, _amountToken1);
        (uint256 _amount0, uint256 _amount1, ) = IFlashLiquidityRouter(_router).addLiquidity(
            _token0,
            _token1,
            _amountToken0,
            _amountToken1,
            _amountToken0 - (_amountToken0 / _maxDeviationFactor),
            _amountToken1 - (_amountToken1 / _maxDeviationFactor),
            address(this),
            block.timestamp
        );
        token0_.approve(_router, 0);
        token1_.approve(_router, 0);
        emit Liquefied(_token0, _token1, _amount0, _amount1);
    }

    function _liquefyOnSelfBalancingPool(
        address _token0,
        address _token1,
        uint256 _amountToken0,
        uint256 _amountToken1
    ) internal {
        address _router = router;
        IERC20 token0_ = IERC20(_token0);
        IERC20 token1_ = IERC20(_token1);
        token0_.approve(_router, _amountToken0);
        token1_.approve(_router, _amountToken1);
        (uint256 _amount0, uint256 _amount1, ) = IFlashLiquidityRouter(_router).addLiquidity(
            _token0,
            _token1,
            _amountToken0,
            _amountToken1,
            1,
            1,
            address(this),
            block.timestamp
        );
        token0_.approve(_router, 0);
        token1_.approve(_router, 0);
        emit Liquefied(_token0, _token1, _amount0, _amount1);
    }

    function _solidifyFromOpenPool(
        IFlashLiquidityPair _pair,
        address _router,
        uint256 _lpTokenAmount
    ) internal {
        (address _token0, address _token1) = (_pair.token0(), _pair.token1());
        (uint256 _reserve0, uint256 _reserve1, ) = _pair.getReserves();
        // avoid stack too deep
        {
            (
                uint256 _price0,
                uint256 _price1,
                uint256 _token0Decimals,
                uint256 _token1Decimals
            ) = _getPricesAndDecimals(_token0, _token1);
            uint256 _reserve0Value = FullMath.mulDiv(_reserve0, uint256(_price0), _token0Decimals);
            uint256 _reserve1Value = FullMath.mulDiv(_reserve1, uint256(_price1), _token1Decimals);
            if (_reserve0Value > _reserve1Value) {
                if (_reserve0Value - _reserve1Value > _reserve0Value / maxDeviationFactor) {
                    revert ReservesValuesMismatch();
                }
            } else {
                if (_reserve1Value - _reserve0Value > _reserve1Value / maxDeviationFactor) {
                    revert ReservesValuesMismatch();
                }
            }
        }
        _pair.approve(_router, _lpTokenAmount);
        (uint256 _amount0, uint256 _amount1) = IFlashLiquidityRouter(_router).removeLiquidity(
            _token0,
            _token1,
            _lpTokenAmount,
            1,
            1,
            address(this),
            block.timestamp
        );
        _pair.approve(_router, 0);
        emit Solidified(_token0, _token1, _amount0, _amount1);
    }

    function _solidifyFromSelfBalancingPool(
        IFlashLiquidityPair _pair,
        address _router,
        uint256 _lpTokenAmount
    ) internal {
        (address _token0, address _token1) = (_pair.token0(), _pair.token1());
        (uint256 _amount0, uint256 _amount1) = IFlashLiquidityRouter(_router).removeLiquidity(
            _token0,
            _token1,
            _lpTokenAmount,
            1,
            1,
            address(this),
            block.timestamp
        );
        emit Solidified(_token0, _token1, _amount0, _amount1);
    }

    function _getPricesAndDecimals(address _token0, address _token1)
        internal
        returns (
            uint256,
            uint256,
            uint256,
            uint256
        )
    {
        uint256 _maxStaleness = maxStaleness;
        (, int256 _price0, , uint256 _price0UpdatedAt, ) = priceFeeds[_token0].latestRoundData();
        (, int256 _price1, , uint256 _price1UpdateAt, ) = priceFeeds[_token1].latestRoundData();
        uint256 _token0Decimals = tokenDecimals[_token0];
        uint256 _token1Decimals = tokenDecimals[_token1];
        if (_price0 <= int256(0) || _price1 <= int256(0)) {
            revert InvalidPrice();
        }
        if (block.timestamp - _price0UpdatedAt > _maxStaleness) {
            revert StalenessToHigh();
        }
        if (block.timestamp - _price1UpdateAt > _maxStaleness) {
            revert StalenessToHigh();
        }
        if (_token0Decimals == 0) {
            _token0Decimals = 10**ERC20(_token0).decimals();
            tokenDecimals[_token0] = _token0Decimals;
        }
        if (_token1Decimals == 0) {
            _token1Decimals = 10**ERC20(_token1).decimals();
            tokenDecimals[_token1] = _token1Decimals;
        }
        if (_token0Decimals == 0 || _token1Decimals == 0) {
            revert DecimalsMismatch();
        }
        return (uint256(_price0), uint256(_price1), _token0Decimals, _token1Decimals);
    }
}

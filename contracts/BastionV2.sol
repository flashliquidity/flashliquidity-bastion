//SPDX-License-Identifier: MIT

pragma solidity 0.8.17;

import {SafeMath} from "@openzeppelin/contracts/utils/math/SafeMath.sol";
import {IBastionV2} from "./interfaces/IBastionV2.sol";
import {IFlashLiquidityFactory} from "./interfaces/IFlashLiquidityFactory.sol";
import {IFlashLiquidityRouter} from "./interfaces/IFlashLiquidityRouter.sol";
import {IFlashLiquidityPair} from "./interfaces/IFlashLiquidityPair.sol";
import {ILiquidFarm} from "./interfaces/ILiquidFarm.sol";
import {ILiquidFarmFactory} from "./interfaces/ILiquidFarmFactory.sol";
import {IPegSwap} from "./interfaces/IPegSwap.sol";
import {Recoverable, IERC20, SafeERC20} from "./types/Recoverable.sol";

contract BastionV2 is IBastionV2, Recoverable {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    address public immutable factory;
    address public immutable router;
    address public immutable farmFactory;
    address private immutable linkTokenERC20;
    address private immutable linkTokenERC667;
    address private immutable pegSwap;
    uint256 public immutable whitelistDelay = 3 days;
    mapping(address => bool) public isWhitelisted;
    mapping(address => uint256) public whitelistReqTimestamp;
    mapping(address => bool) public isExtManagerSetter;

    constructor(
        address _governor,
        address _factory,
        address _router,
        address _farmFactory,
        address _linkTokenERC20,
        address _linkTokenERC667,
        address _pegSwap,
        uint256 _transferGovernanceDelay,
        uint256 _withdrawalDelay
    ) Recoverable(_governor, _transferGovernanceDelay, _withdrawalDelay) {
        factory = _factory;
        router = _router;
        farmFactory = _farmFactory;
        linkTokenERC20 = _linkTokenERC20;
        linkTokenERC667 = _linkTokenERC667;
        pegSwap = _pegSwap;
    }

    function requestWhitelisting(address[] calldata _recipients) external onlyGovernor whenNotPaused {
        for(uint256 i = 0; i < _recipients.length; i++) {
            if(isWhitelisted[_recipients[i]]) revert AlreadyWhitelisted();
            whitelistReqTimestamp[_recipients[i]] = block.timestamp;
        }
    }

    function executeWhitelisting(address[] calldata _recipients) external onlyGovernor whenNotPaused {
        uint256 _whitelistDelay = whitelistDelay;
        for(uint256 i = 0; i < _recipients.length; i++) {
            uint256 _timestamp = whitelistReqTimestamp[_recipients[i]];
            if(whitelistReqTimestamp[_recipients[i]] == 0) revert NotRequested();
            if(block.timestamp - _timestamp < _whitelistDelay) revert TooEarly();
            isWhitelisted[_recipients[i]] = true;
            whitelistReqTimestamp[_recipients[i]] = 0;
        }
    }

    function removeFromWhitelist(address[] calldata _recipients) external onlyGovernor {
        for(uint256 i = 0; i < _recipients.length; i++) {
            if(!isWhitelisted[_recipients[i]]) revert NotWhitelisted();
            isWhitelisted[_recipients[i]] = false;
        }
    }

    function setPairManager(address _pair, address _manager) public {
        if(!isExtManagerSetter[msg.sender]) revert NotManagerSetter();
        IFlashLiquidityFactory(factory).setPairManager(_pair, _manager);
    }

    function setMainManagerSetter(address _managerSetter) external onlyGovernor {
        IFlashLiquidityFactory(factory).setPairManagerSetter(_managerSetter);
    }

    function setExtManagerSetter(address _extManagerSetter, bool _enabled) external onlyGovernor {
        isExtManagerSetter[_extManagerSetter] = _enabled;
        emit ExtManagerSetterChanged(_extManagerSetter  , _enabled);
    }

    function transferToWhitelisted(
        address _recipient, 
        address[] calldata _tokens, 
        uint256[] calldata _amounts
    ) external onlyGovernor whenNotPaused {
        if(!isWhitelisted[_recipient]) revert NotWhitelisted();
        for (uint256 i = 0; i < _tokens.length; i++) {
            IERC20(_tokens[i]).safeTransfer(
                _recipient,
                _amounts[i]
            );
        }
        emit TransferredToWhitelisted(_recipient, _tokens, _amounts);
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOut,
        address[] calldata _path
    ) external onlyGovernor whenNotPaused {
        IERC20 _token1 = IERC20(_path[0]);
        _token1.safeIncreaseAllowance(router, amountIn);
        uint256[] memory amounts = IFlashLiquidityRouter(router).swapExactTokensForTokens(
            amountIn,
            amountOut,
            _path,
            address(this),
            block.timestamp
        );
        _token1.approve(router, 0);
        emit Swapped(_path[0], _path[_path.length - 1], amounts[0], amounts[amounts.length - 1]);
    }

    function swapOnLockedPair(
        uint256 amountIn,
        uint256 amountOut,
        address fromToken,
        address toToken
    ) external onlyGovernor whenNotPaused {
        IFlashLiquidityFactory _factory = IFlashLiquidityFactory(factory);
        IFlashLiquidityPair pair = IFlashLiquidityPair(_factory.getPair(fromToken, toToken));
        address _manager = pair.manager();
        if(address(pair) == address(0) || _manager == address(0)) revert CannotConvert();
        (uint256 reserve0, uint256 reserve1, ) = pair.getReserves();
        uint256 amountInWithFee = amountIn.mul(9994);
        _factory.setPairManager(address(pair), address(this));
        if (fromToken == pair.token0()) {
            amountOut = amountInWithFee.mul(reserve1) / reserve0.mul(10000).add(amountInWithFee);
            IERC20(fromToken).safeTransfer(address(pair), amountIn);
            pair.swap(0, amountOut, address(this), new bytes(0));
        } else {
            amountOut = amountInWithFee.mul(reserve0) / reserve1.mul(10000).add(amountInWithFee);
            IERC20(fromToken).safeTransfer(address(pair), amountIn);
            pair.swap(amountOut, 0, address(this), new bytes(0));
        }

        _factory.setPairManager(address(pair), _manager);
        emit Swapped(fromToken, toToken, amountIn, amountOut);
    }

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin
    )
        external
        onlyGovernor
        whenNotPaused
    {
        IERC20(tokenA).safeIncreaseAllowance(router, amountADesired);
        IERC20(tokenB).safeIncreaseAllowance(router, amountBDesired);
        (uint256 amountA, uint256 amountB, ) = IFlashLiquidityRouter(router).addLiquidity(
            tokenA,
            tokenB,
            amountADesired,
            amountBDesired,
            amountAMin,
            amountBMin,
            address(this),
            block.timestamp
        );
        IERC20(tokenA).approve(router, 0);
        IERC20(tokenB).approve(router, 0);
        emit AddedLiquidity(tokenA, tokenB, amountA, amountB);
    }

    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin
    ) external onlyGovernor whenNotPaused {
        IFlashLiquidityFactory _factory = IFlashLiquidityFactory(factory);
        IERC20 pair = IERC20(_factory.getPair(tokenA, tokenB));
        pair.safeIncreaseAllowance(router, liquidity);
        (uint256 amountA, uint256 amountB) = IFlashLiquidityRouter(router).removeLiquidity(
            tokenA,
            tokenB,
            liquidity,
            amountAMin,
            amountBMin,
            address(this),
            block.timestamp
        );
        pair.approve(router, 0);
        emit RemovedLiquidity(tokenA, tokenB, amountA, amountB);
    }

    function stakeLpTokens(address lpToken, uint256 amount)
        external
        onlyGovernor
        whenNotPaused
    {
        ILiquidFarmFactory _arbFarmFactory = ILiquidFarmFactory(farmFactory);
        address _farm = _arbFarmFactory.lpTokenFarm(lpToken);
        if(_farm == address(0)) revert FarmNotDeployed();
        IERC20 _lpToken = IERC20(lpToken);
        _lpToken.safeIncreaseAllowance(_farm, amount);
        ILiquidFarm(_farm).stake(amount);
        _lpToken.approve(_farm, 0);
        emit Staked(lpToken, amount);
    }

    function unstakeLpTokens(address lpToken, uint256 amount) external onlyGovernor whenNotPaused {
        ILiquidFarmFactory _arbFarmFactory = ILiquidFarmFactory(farmFactory);
        address _farm = _arbFarmFactory.lpTokenFarm(lpToken);
        if(_farm == address(0)) revert FarmNotDeployed();
        ILiquidFarm(_farm).withdraw(amount);
        emit Unstaked(lpToken, amount);
    }

    function claimStakingRewards(address lpToken) external onlyGovernor whenNotPaused {
        ILiquidFarmFactory _arbFarmFactory = ILiquidFarmFactory(farmFactory);
        address _farm = _arbFarmFactory.lpTokenFarm(lpToken);
        if(_farm == address(0)) revert FarmNotDeployed();
        ILiquidFarm(_farm).getReward();
        emit ClaimedRewards(lpToken);
    }

    function swapLinkToken(bool toERC667, uint256 amount) external onlyGovernor whenNotPaused {
        address source;
        address dest;
        if (toERC667) {
            source = linkTokenERC20;
            dest = linkTokenERC667;
        } else {
            source = linkTokenERC667;
            dest = linkTokenERC20;
        }
        IERC20(source).safeIncreaseAllowance(pegSwap, amount);
        IPegSwap(pegSwap).swap(amount, source, dest);
        IERC20(source).approve(pegSwap, 0);
    }
}

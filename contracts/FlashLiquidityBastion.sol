//SPDX-License-Identifier: MIT

pragma solidity 0.8.16;

import {SafeMath} from "@openzeppelin/contracts/utils/math/SafeMath.sol";
import {IFlashLiquidityBastion} from "./interfaces/IFlashLiquidityBastion.sol";
import {IFlashLiquidityFactory} from "./interfaces/IFlashLiquidityFactory.sol";
import {IFlashLiquidityRouter} from "./interfaces/IFlashLiquidityRouter.sol";
import {IFlashLiquidityPair} from "./interfaces/IFlashLiquidityPair.sol";
import {IFlashBotFactory} from "./interfaces/IFlashBotFactory.sol";
import {IUpkeepsStationFactory} from "./interfaces/IUpkeepsStationFactory.sol";
import {IStakingRewards} from "./interfaces/IStakingRewards.sol";
import {IStakingRewardsFactory} from "./interfaces/IStakingRewardsFactory.sol";
import {IPegSwap} from "./interfaces/IPegSwap.sol";
import {Recoverable, IERC20, SafeERC20} from "./types/Recoverable.sol";

contract FlashLiquidityBastion is IFlashLiquidityBastion, Recoverable {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    address public immutable router;
    address public immutable fliqPropulsionSystem;
    address public immutable stakingFactory;
    address public immutable flashBotFactory;
    address public immutable upkeepsStationFactory;
    address private immutable linkTokenERC20;
    address private immutable linkTokenERC667;
    address private immutable pegSwap;
    uint256 public nextExecAllocationId = 0;
    uint256 private nextAllocationId = 0;
    uint256 public immutable allocExecDelay;

    mapping(uint256 => Allocation) public allocations;
    mapping(address => uint256) private tokensAllocated;
    mapping(address => bool) public isExtFlashBotSetter;

    constructor(
        address _governor,
        address _guardian,
        address _router,
        address _fliqPropulsionSystem,
        address _stakingFactory,
        address _flashBotFactory,
        address _upkeepsStationFactory,
        address _linkTokenERC20,
        address _linkTokenERC667,
        address _pegSwap,
        uint256 _allocExecDelay,
        uint256 _transferGovernanceDelay,
        uint256 _withdrawalDelay
    ) Recoverable(_governor, _guardian, _transferGovernanceDelay, _withdrawalDelay) {
        router = _router;
        fliqPropulsionSystem = _fliqPropulsionSystem;
        stakingFactory = _stakingFactory;
        flashBotFactory = _flashBotFactory;
        upkeepsStationFactory = _upkeepsStationFactory;
        linkTokenERC20 = _linkTokenERC20;
        linkTokenERC667 = _linkTokenERC667;
        pegSwap = _pegSwap;
        allocExecDelay = _allocExecDelay;
    }

    function getUnallocatedAmount(address _token) public view returns (uint256) {
        return IERC20(_token).balanceOf(address(this)) - tokensAllocated[_token];
    }

    function isNextAllocationExecutable() public view returns (bool) {
        Allocation storage _allocation = allocations[nextExecAllocationId];
        if (_allocation.state == AllocationState.PENDING) {
            return
                block.timestamp - allocations[nextExecAllocationId].requestTimestamp >
                allocExecDelay;
        }
        return false;
    }

    function setFlashbot(address _pair, address _flashbot) public onlyFlashBotSetters {
        IFlashLiquidityFactory factory = IFlashLiquidityFactory(
            IFlashLiquidityRouter(router).factory()
        );
        factory.setFlashbot(_pair, _flashbot);
    }

    function setMainFlashbotSetter(address _flashbotSetter) external onlyGovernor {
        IFlashLiquidityFactory factory = IFlashLiquidityFactory(
            IFlashLiquidityRouter(router).factory()
        );
        factory.setFlashbotSetter(_flashbotSetter);
    }

    function setExtFlashbotSetter(address setter, bool enabled) external onlyGovernor {
        isExtFlashBotSetter[setter] = enabled;
        emit ExtBotSetterChanged(setter, enabled);
    }

    function enableAutomatedArbitrage(
        string calldata name,
        address _rewardToken,
        address _flashSwapFarm,
        address _flashPool,
        address[] calldata _extPools,
        address _fastGasFeed,
        address _wethPriceFeed,
        address _rewardTokenPriceFeed,
        uint256 _reserveProfitRatio,
        uint96 _toUpkeepAmount,
        uint32 _gasLimit,
        bytes calldata checkData
    ) external onlyGovernor whenNotPaused {
        IFlashBotFactory _botFactory = IFlashBotFactory(flashBotFactory);
        IUpkeepsStationFactory _stationFactory = IUpkeepsStationFactory(upkeepsStationFactory);
        address _poolBot = _botFactory.poolFlashbot(_flashPool);
        require(
            _poolBot == address(0) || _stationFactory.getFlashBotUpkeepId(_poolBot) == 0,
            "Must disable the old bot first"
        );
        address _flashbot = _botFactory.deployFlashbot(
            _rewardToken,
            _flashSwapFarm,
            _flashPool,
            _extPools,
            _fastGasFeed,
            _wethPriceFeed,
            _rewardTokenPriceFeed,
            _reserveProfitRatio,
            50,
            _gasLimit
        );
        address factory = IFlashLiquidityRouter(router).factory();
        IFlashLiquidityFactory(factory).setFlashbot(_flashPool, _flashbot);
        _stationFactory.automateFlashBot(name, _flashbot, _gasLimit, checkData, _toUpkeepAmount);
        emit AutomatedArbitrageEnabled(_flashPool);
    }

    function requestAllocation(
        address _recipient,
        address[] calldata _tokens,
        uint256[] calldata _amounts
    ) external onlyGovernor whenNotPaused {
        uint256 _nextAllocationId = nextAllocationId;
        Allocation storage _allocation = allocations[_nextAllocationId];
        require(_allocation.state == AllocationState.EMPTY, "Wrong Allocation State");
        _allocation.state = AllocationState.PENDING;
        _allocation.requestTimestamp = block.timestamp;
        _allocation.recipient = _recipient;
        nextAllocationId += 1;
        for (uint256 i = 0; i < _tokens.length; i++) {
            require(
                getUnallocatedAmount(_tokens[i]) >= _amounts[i],
                "Amount Exceeds Unallocated Balance"
            );
            tokensAllocated[_tokens[i]] += _amounts[i];
        }
        allocations[_nextAllocationId].tokens = _tokens;
        allocations[_nextAllocationId].amounts = _amounts;
        emit AllocationRequested(_nextAllocationId, _allocation.recipient);
    }

    function abortAllocation(uint256 _allocationId) external onlyGuardian {
        Allocation storage _allocation = allocations[_allocationId];
        require(_allocationId < nextAllocationId, "Not Exists");
        require(_allocationId >= nextExecAllocationId, "Already Executed");
        require(_allocation.state == AllocationState.PENDING, "Not Pending");
        _allocation.state = AllocationState.ABORTED;
        for (uint256 i = 0; i < _allocation.tokens.length; i++) {
            tokensAllocated[_allocation.tokens[i]] -= _allocation.amounts[i];
        }
        emit AllocationAborted(_allocationId);
    }

    function executeAllocation() external onlyGuardian whenNotPaused {
        skipAbortedAllocations();
        uint256 _nextExecAllocationId = nextExecAllocationId;
        Allocation storage _allocation = allocations[_nextExecAllocationId];
        require(_nextExecAllocationId < nextAllocationId, "No Pending Allocation");
        require(_allocation.state == AllocationState.PENDING, "Already Executed");
        require(block.timestamp - _allocation.requestTimestamp > allocExecDelay, "Too Early");
        _allocation.state = AllocationState.EXECUTED;
        nextExecAllocationId += 1;
        for (uint256 i = 0; i < _allocation.tokens.length; i++) {
            IERC20(_allocation.tokens[i]).safeTransfer(
                _allocation.recipient,
                _allocation.amounts[i]
            );
        }
        emit AllocationCompleted(_nextExecAllocationId, _allocation.tokens, _allocation.amounts);
    }

    function skipAbortedAllocation() external onlyGuardian whenNotPaused {
        Allocation storage _allocation = allocations[nextExecAllocationId];
        require(_allocation.state == AllocationState.ABORTED, "Not Aborted");
        nextExecAllocationId += 1;
    }

    function skipAbortedAllocations() internal {
        uint256 _nextExecAllocationId = nextExecAllocationId;
        Allocation storage _nextAllocation = allocations[_nextExecAllocationId];
        uint256 _count = 0;
        while (_nextAllocation.state == AllocationState.ABORTED) {
            _count += 1;
            _nextAllocation = allocations[_nextExecAllocationId + _count];
        }
        nextExecAllocationId += _count;
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOut,
        address[] calldata _path
    ) external onlyGovernor whenNotPaused {
        require(amountIn <= getUnallocatedAmount(_path[0]), "AmountIn exceeds unallocated balance");
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
    ) external onlyGovernor whenNotPaused balanceCheck(fromToken, amountIn) {
        IFlashLiquidityFactory factory = IFlashLiquidityFactory(
            IFlashLiquidityRouter(router).factory()
        );
        IFlashLiquidityPair pair = IFlashLiquidityPair(factory.getPair(fromToken, toToken));
        address _flashbot = pair.flashbot();
        require(address(pair) != address(0), "Cannot convert");
        require(_flashbot != address(0), "Cannot use swapOnLockedPair with open pairs");
        (uint256 reserve0, uint256 reserve1, ) = pair.getReserves();
        uint256 amountInWithFee = amountIn.mul(997);
        factory.setFlashbot(address(pair), address(this));
        if (fromToken == pair.token0()) {
            amountOut = amountInWithFee.mul(reserve1) / reserve0.mul(1000).add(amountInWithFee);
            IERC20(fromToken).safeTransfer(address(pair), amountIn);
            pair.swap(0, amountOut, address(this), new bytes(0));
        } else {
            amountOut = amountInWithFee.mul(reserve0) / reserve1.mul(1000).add(amountInWithFee);
            IERC20(fromToken).safeTransfer(address(pair), amountIn);
            pair.swap(amountOut, 0, address(this), new bytes(0));
        }

        factory.setFlashbot(address(pair), _flashbot);
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
        balanceCheck(tokenA, amountAMin)
        balanceCheck(tokenB, amountBMin)
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
        IFlashLiquidityFactory factory = IFlashLiquidityFactory(
            IFlashLiquidityRouter(router).factory()
        );
        IERC20 pair = IERC20(factory.getPair(tokenA, tokenB));
        require(
            liquidity <= getUnallocatedAmount(address(pair)),
            "Removed liquidity exceeds unallocated balance"
        );
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
        balanceCheck(lpToken, amount)
    {
        IStakingRewardsFactory _stakingFactory = IStakingRewardsFactory(stakingFactory);
        address _farm = _stakingFactory.stakingRewardsAddress(lpToken);
        require(_farm != address(0), "Farm not deployed");
        require(amount <= getUnallocatedAmount(lpToken), "Amount exceeds unallocated balance");
        IERC20 _lpToken = IERC20(lpToken);
        _lpToken.safeIncreaseAllowance(_farm, amount);
        IStakingRewards(_farm).stake(amount);
        _lpToken.approve(_farm, 0);
        emit Staked(lpToken, amount);
    }

    function unstakeLpTokens(address lpToken, uint256 amount) external onlyGovernor whenNotPaused {
        IStakingRewardsFactory _stakingFactory = IStakingRewardsFactory(stakingFactory);
        address _farm = _stakingFactory.stakingRewardsAddress(lpToken);
        require(_farm != address(0), "Farm not deployed");
        IStakingRewards(_farm).withdraw(amount);
        emit Unstaked(lpToken, amount);
    }

    function claimStakingRewards(address lpToken) external onlyGovernor whenNotPaused {
        IStakingRewardsFactory _stakingFactory = IStakingRewardsFactory(stakingFactory);
        address _farm = _stakingFactory.stakingRewardsAddress(lpToken);
        require(_farm != address(0), "Farm not deployed");
        IStakingRewards(_farm).getReward();
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
        require(amount <= getUnallocatedAmount(source), "Amount exceeds unallocated balance");
        IERC20(source).safeIncreaseAllowance(pegSwap, amount);
        IPegSwap(pegSwap).swap(amount, source, dest);
        IERC20(source).approve(pegSwap, 0);
    }

    function sendToPropulsionSystem(address[] calldata tokens, uint256[] calldata amounts)
        external
        onlyGovernor
        whenNotPaused
    {
        for (uint256 i = 0; i < tokens.length; i++) {
            require(
                amounts[i] <= getUnallocatedAmount(tokens[i]),
                "Amount exceeds unallocated balance"
            );
            IERC20(tokens[i]).safeTransfer(fliqPropulsionSystem, amounts[i]);
        }
    }

    function sendLinkToUpkeepsStationFactory(uint256 amount)
        external
        onlyGovernor
        whenNotPaused
        balanceCheck(linkTokenERC667, amount)
    {
        IERC20(linkTokenERC667).safeTransfer(upkeepsStationFactory, amount);
        emit TransferredToStationFactory(amount);
    }

    modifier onlyFlashBotSetters() {
        require(isExtFlashBotSetter[msg.sender], "Not Authorized");
        _;
    }

    modifier balanceCheck(address _token, uint256 _amount) {
        require(_amount <= getUnallocatedAmount(_token), "Amount exceeds unallocated balance");
        _;
    }
}

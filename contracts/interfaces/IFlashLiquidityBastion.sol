// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

interface IFlashLiquidityBastion {
    enum AllocationState {
        EMPTY,
        PENDING,
        EXECUTED,
        ABORTED
    }

    struct Allocation {
        uint256 requestTimestamp;
        AllocationState state;
        address recipient;
        address[] tokens;
        uint256[] amounts;
    }

    event AutomatedArbitrageEnabled(address indexed _pair);
    event AllocationRequested(uint256 indexed _id, address indexed _recipient);
    event AllocationCompleted(
        uint256 indexed _id,
        address[] indexed _tokens,
        uint256[] indexed _amounts
    );
    event AllocationAborted(uint256 indexed _id);
    event AddedLiquidity(
        address indexed tokenA,
        address indexed tokenB,
        uint256 amountA,
        uint256 amountB
    );
    event RemovedLiquidity(
        address indexed tokenA,
        address indexed tokenB,
        uint256 amountA,
        uint256 amountB
    );
    event Swapped(address indexed tokenA, address indexed tokenB, uint256 amountA, uint256 amountB);
    event Staked(address indexed stakingToken, uint256 indexed amount);
    event Unstaked(address indexed stakingToken, uint256 indexed amount);
    event ClaimedRewards(address indexed stakingToken);
    event TransferredToStationFactory(uint256 indexed amount);
    event ExtBotSetterChanged(address indexed setter, bool indexed isSetter);

    function router() external view returns (address);

    function stakingFactory() external view returns (address);

    function flashBotFactory() external view returns (address);

    function upkeepsStationFactory() external view returns (address);

    function nextExecAllocationId() external view returns (uint256);

    function allocExecDelay() external view returns (uint256);

    function getUnallocatedAmount(address _token) external view returns (uint256);

    function isNextAllocationExecutable() external view returns (bool);

    function setFlashbot(address _pair, address _flashbot) external;

    function setMainFlashbotSetter(address _flashbotSetter) external;

    function setExtFlashbotSetter(address _setter, bool isSetter) external;

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
    ) external;

    function requestAllocation(
        address _recipient,
        address[] calldata _tokens,
        uint256[] calldata _amounts
    ) external;

    function executeAllocation() external;

    function skipAbortedAllocation() external;

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOut,
        address[] calldata _path
    ) external;

    function swapOnLockedPair(
        uint256 amountIn,
        uint256 amountOut,
        address fromToken,
        address toToken
    ) external;

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin
    ) external;

    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin
    ) external;

    function stakeLpTokens(address lpToken, uint256 amount) external;

    function unstakeLpTokens(address lpToken, uint256 amount) external;

    function claimStakingRewards(address lpToken) external;

    function swapLinkToken(bool toERC667, uint256 amount) external;

    function sendToPropulsionSystem(address[] calldata tokens, uint256[] calldata amounts) external;

    function sendLinkToUpkeepsStationFactory(uint256 amount) external;
}

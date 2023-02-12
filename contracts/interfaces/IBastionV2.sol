// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

interface IBastionV2 {
    error CannotConvert();
    error FarmNotDeployed();
    error NotWhitelisted();
    error AlreadyWhitelisted();
    error NotManagerSetter();
    
    event TransferredToWhitelisted(
        address indexed _recipient,
        address[] indexed _tokens,
        uint256[] indexed _amounts
    );
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
    event ExtManagerSetterChanged(address indexed setter, bool indexed isSetter);

    function router() external view returns (address);
    function farmFactory() external view returns (address);
    function requestWhitelisting(address[] calldata _recipients) external;
    function executeWhitelisting(address[] calldata _recipients) external;
    function removeFromWhitelist(address[] calldata _recipients) external;
    function setPairManager(address _pair, address _manager) external;
    function setMainManagerSetter(address _mainManagerSetter) external;
    function setExtManagerSetter(address _extManagerSetter, bool _enabled) external;

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
}

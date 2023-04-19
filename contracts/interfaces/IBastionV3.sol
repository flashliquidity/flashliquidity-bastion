// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

interface IBastionV3 {
    function factory() external view returns (address);

    function router() external view returns (address);

    function farmFactory() external view returns (address);

    function maxDeviationFactor() external view returns (uint256);

    function whitelistDelay() external view returns (uint256);

    function isExtManagerSetter(address) external view returns (bool);

    function isWhitelisted(address) external view returns (bool);

    function whitelistReqTimestamp(address) external view returns (uint256);

    function requestWhitelisting(address[] calldata _recipients) external;

    function abortWhitelisting(address[] calldata _recipients) external;

    function executeWhitelisting(address[] calldata _recipients) external;

    function removeFromWhitelist(address[] calldata _recipients) external;

    function setMaxDeviationFactor(uint256 _maxDeviationFactor) external;

    function setPairManager(address _pair, address _manager) external;

    function setMainManagerSetter(address _managerSetter) external;

    function setExtManagerSetters(address[] calldata _extManagerSetter, bool[] calldata _enabled)
        external;

    function setPriceFeeds(address[] calldata _tokens, address[] calldata _priceFeeds) external;

    function setTokensDecimals(address[] calldata _tokens, uint256[] calldata _decimals) external;

    function transferToWhitelisted(
        address _recipient,
        address[] calldata _tokens,
        uint256[] calldata _amounts
    ) external;

    function swap(
        address _tokenIn,
        address _tokenOut,
        uint256 _amountIn
    ) external;

    function liquefy(
        address _token0,
        address _token1,
        uint256 _token0Amount,
        uint256 _token1Amount
    ) external;

    function solidify(address _lpToken, uint256 _lpAmount) external;

    function stakeLpTokens(address _lpToken, uint256 _amount) external;

    function unstakeLpTokens(address _lpToken, uint256 _amount) external;

    function exitStaking(address _lpToken) external;

    function claimStakingRewards(address _lpToken) external;
}

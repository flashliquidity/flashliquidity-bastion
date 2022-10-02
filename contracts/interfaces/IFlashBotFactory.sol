// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

interface IFlashBotFactory {
    event FlashBotDeployed(address indexed _flashPool, address indexed _bot);

    function poolFlashbot(address) external view returns (address);

    function deployFlashbot(
        address _rewardToken,
        address _flashSwapFarm,
        address _flashPool,
        address[] calldata _extPools,
        address _fastGasFeed,
        address _wethPriceFeed,
        address _rewardTokenPriceFeed,
        uint256 _reserveProfitRatio,
        uint256 _gasProfitMultiplier,
        uint32 _gasLimit
    ) external returns (address _flashbot);
}

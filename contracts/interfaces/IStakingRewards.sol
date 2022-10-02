// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "./IFlashBorrower.sol";

interface IStakingRewards {
    function rewardsFactory() external view returns (address);

    function stakingToken() external view returns (address);

    function rewardsToken() external view returns (uint256);

    function rewardPerToken() external view returns (uint256);

    function earned(address account) external view returns (uint256);

    function totalSupply() external view returns (uint256);

    function balanceOf(address account) external view returns (uint256);

    function stake(uint256 amount) external;

    function withdraw(uint256 amount) external;

    function getReward() external;

    function exit() external;

    function flashLoan(
        IFlashBorrower borrower,
        address receiver,
        uint256 amount,
        bytes memory data
    ) external;
}

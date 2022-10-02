// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

interface IStakingRewardsFactory {
    function stakingRewardsAddress(address) external view returns (address);

    function deploy(
        address,
        address,
        address
    ) external;
}

//SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import {Governable} from "./Governable.sol";

abstract contract Guardable is Governable {
    address public guardian;

    event GuardianChanged(address indexed _oldGuardian, address indexed _newGuardian);

    constructor(
        address _governor,
        address _guardian,
        uint256 _transferGovernanceDelay
    ) Governable(_governor, _transferGovernanceDelay) {
        guardian = _guardian;
        emit GuardianChanged(address(0), _guardian);
    }

    function setGuardian(address _guardian) external onlyGovernor {
        address _oldGuardian = guardian;
        guardian = _guardian;
        emit GuardianChanged(_oldGuardian, _guardian);
    }

    modifier onlyGuardian() {
        require(msg.sender == guardian, "Only Guardian");
        _;
    }
}

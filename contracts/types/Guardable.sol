//SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import {Governable} from "./Governable.sol";

abstract contract Guardable is Governable {
    bool public isPaused;
    mapping(address => bool) public isGuardian;

    error NotGuardian();
    error NotPaused();
    error AlreadyPaused();

    event PausedStateChanged(address indexed seneder, bool indexed isPaused);
    event GuardiansChanged(address[] indexed _guardians, bool[] indexed _enabled);

    constructor(address _governor, uint256 _transferGovernanceDelay)
        Governable(_governor, _transferGovernanceDelay)
    {
        isGuardian[_governor] = true;
    }

    function setGuardians(address[] calldata _guardians, bool[] calldata _enabled)
        external
        onlyGovernor
    {
        for (uint256 i = 0; i < _guardians.length; ) {
            isGuardian[_guardians[i]] = _enabled[i];
            unchecked {
                i++;
            }
        }
        emit GuardiansChanged(_guardians, _enabled);
    }

    function pause() external onlyGuardian whenNotPaused {
        isPaused = true;
        emit PausedStateChanged(msg.sender, true);
    }

    function unpause() external onlyGovernor whenPaused {
        isPaused = false;
        emit PausedStateChanged(msg.sender, false);
    }

    modifier onlyGuardian() {
        if (!isGuardian[msg.sender]) {
            revert NotGuardian();
        }
        _;
    }

    modifier whenPaused() {
        if (!isPaused) {
            revert NotPaused();
        }
        _;
    }

    modifier whenNotPaused() {
        if (isPaused) {
            revert AlreadyPaused();
        }
        _;
    }
}

//SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import {Governable} from "./Governable.sol";

abstract contract Guardable is Governable {
    bool public isPaused;
    address public guardian;

    error NotGuardian();
    error NotPaused();
    error AlreadyPaused();

    event PausedStateChanged(address indexed seneder, bool indexed isPaused);
    event GuardianChanged(address _newGuardian);

    constructor(address _guardian) {
        guardian = _guardian;
    }

    function setGuardian(address _guardian) external onlyGuardian {
        guardian = _guardian;
        emit GuardianChanged(_guardian);
    }

    function pause() external onlyGuardian whenNotPaused {
        isPaused = true;
        emit PausedStateChanged(msg.sender, true);
    }

    function unpause() external onlyGuardian whenPaused {
        isPaused = false;
        emit PausedStateChanged(msg.sender, false);
    }

    modifier onlyGuardian() {
        if (msg.sender != guardian) {
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

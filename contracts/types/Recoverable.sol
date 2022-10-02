//SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import {Guardable} from "./Guardable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

abstract contract Recoverable is Guardable {
    using SafeERC20 for IERC20;
    bool public paused;
    uint256 public withdrawalRequestTimestamp;
    uint256 public immutable withdrawalDelay;
    address public withdrawalRecipient;

    event Paused(address indexed _guardian);
    event Unpaused(address indexed _guardian);
    event EmergencyWithdrawalRequested(address indexed _recipient);
    event EmergencyWithdrawalCompleted(address indexed _recipient);
    event EmergencyWithdrawalAborted(address indexed _recipient);
    event WithdrawalRecipientChanged(address indexed _recipient);

    constructor(
        address _governor,
        address _guardian,
        uint256 _transferGovernanceDelay,
        uint256 _withdrawalDelay
    ) Guardable(_governor, _guardian, _transferGovernanceDelay) {
        withdrawalDelay = _withdrawalDelay;
    }

    function pause() external onlyGuardian whenNotPaused {
        paused = true;
        emit Paused(guardian);
    }

    function unpause() external onlyGuardian whenPaused {
        paused = false;
        withdrawalRequestTimestamp = 0;
        emit Unpaused(guardian);
    }

    function requestEmergencyWithdrawal(address _withdrawalRecipient)
        external
        onlyGovernor
        whenPaused
        whenNotEmergency
    {
        require(_withdrawalRecipient != address(0), "Zero Address");
        withdrawalRecipient = _withdrawalRecipient;
        withdrawalRequestTimestamp = block.timestamp;
        emit EmergencyWithdrawalRequested(_withdrawalRecipient);
    }

    function abortEmergencyWithdrawal() external onlyGovernor whenPaused whenEmergency {
        withdrawalRequestTimestamp = 0;
        emit EmergencyWithdrawalAborted(withdrawalRecipient);
    }

    function emergencyWithdraw(address[] calldata _tokens, uint256[] calldata _amounts)
        external
        onlyGovernor
        whenPaused
        whenEmergency
    {
        require(block.timestamp - withdrawalRequestTimestamp > withdrawalDelay, "Too Early");
        address _recipient = withdrawalRecipient;
        for (uint256 i = 0; i < _tokens.length; i++) {
            IERC20(_tokens[i]).safeTransfer(_recipient, _amounts[i]);
        }
        emit EmergencyWithdrawalCompleted(_recipient);
    }

    modifier whenPaused() {
        require(paused, "Not Paused");
        _;
    }

    modifier whenNotPaused() {
        require(!paused, "Paused");
        _;
    }

    modifier whenEmergency() {
        require(withdrawalRequestTimestamp != 0, "Withdrawal Not Requested");
        _;
    }

    modifier whenNotEmergency() {
        require(withdrawalRequestTimestamp == 0, "Withdrawal Already Requested");
        _;
    }
}

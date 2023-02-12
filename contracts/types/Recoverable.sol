//SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import {Governable} from "./Governable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

abstract contract Recoverable is Governable {
    using SafeERC20 for IERC20;
    bool public paused;
    uint256 public withdrawalRequestTimestamp;
    uint256 public immutable withdrawalDelay;
    address public withdrawalRecipient;

    error NotPaused();
    error Paused();
    error NotRequested();
    error AlreadyRequested(); 

    event EmergencyWithdrawalRequested(address indexed _recipient);
    event EmergencyWithdrawalCompleted(address indexed _recipient);
    event EmergencyWithdrawalAborted(address indexed _recipient);
    event WithdrawalRecipientChanged(address indexed _recipient);

    constructor(
        address _governor,
        uint256 _transferGovernanceDelay,
        uint256 _withdrawalDelay
    ) Governable(_governor, _transferGovernanceDelay) {
        withdrawalDelay = _withdrawalDelay;
    }

    function pause() external onlyGovernor whenNotPaused {
        paused = true;
    }

    function unpause() external onlyGovernor whenPaused {
        paused = false;
        withdrawalRequestTimestamp = 0;
    }

    function requestEmergencyWithdrawal(address _withdrawalRecipient)
        external
        onlyGovernor
        whenPaused
        whenNotEmergency
    {
        if(_withdrawalRecipient == address(0)) revert ZeroAddress();
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
        if(block.timestamp - withdrawalRequestTimestamp < withdrawalDelay) revert TooEarly();
        address _recipient = withdrawalRecipient;
        for (uint256 i = 0; i < _tokens.length; i++) {
            IERC20(_tokens[i]).safeTransfer(_recipient, _amounts[i]);
        }
        emit EmergencyWithdrawalCompleted(_recipient);
    }

    modifier whenPaused() {
        if(!paused) revert NotPaused();
        _;
    }

    modifier whenNotPaused() {
        if(paused) revert Paused();
        _;
    }

    modifier whenEmergency() {
        if(withdrawalRequestTimestamp == 0) revert NotRequested();
        _;
    }

    modifier whenNotEmergency() {
        if(withdrawalRequestTimestamp != 0) revert AlreadyRequested();
        _;
    }
}

//SPDX-License-Identifier: MIT

pragma solidity 0.8.17;

import {IPegSwap} from "./interfaces/IPegSwap.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {BastionConnector} from "./types/BastionConnector.sol";
import {FullMath} from "./libraries/FullMath.sol";

contract LinkPegSwap is BastionConnector {
    using SafeERC20 for IERC20;

    address public immutable pegSwap;
    address public immutable linkERC20;
    address public immutable linkERC667;

    constructor(
        address _governor,
        address _bastion,
        address _pegSwap,
        address _linkERC20,
        address _linkERC667,
        uint256 _transferGovernanceDelay
    ) BastionConnector(_governor, _bastion, _transferGovernanceDelay) {
        pegSwap = _pegSwap;
        linkERC20 = _linkERC20;
        linkERC667 = _linkERC667;
    }

    function swapLinkToken(bool toERC667, uint256 amount) external onlyGovernor {
        address source;
        address dest;
        if (toERC667) {
            source = linkERC20;
            dest = linkERC667;
        } else {
            source = linkERC667;
            dest = linkERC20;
        }
        IERC20(source).approve(pegSwap, amount);
        IPegSwap(pegSwap).swap(amount, source, dest);
        IERC20(dest).safeTransfer(bastion, amount);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IStakingRegistry} from "../../src/frame/IStakingRegistry.sol";

/// @notice EntryPoint-style stake registry for tests: records stake per caller, "staked" when the
///         amount and delay clear the thresholds.
contract MockStakingRegistry is IStakingRegistry {
    uint256 public constant MIN_STAKE_VALUE = 1 ether; // stand-in for the devnet's ~$1,000
    uint32 public constant MIN_DELAY = 86_400;

    mapping(address => uint256) public stakeOf;
    mapping(address => uint32) public delayOf;

    function addStake(uint32 unstakeDelaySec) external payable {
        stakeOf[msg.sender] += msg.value;
        delayOf[msg.sender] = unstakeDelaySec;
    }

    function unlockStake() external {}

    function withdrawStake(address payable recipient) external {
        uint256 s = stakeOf[msg.sender];
        stakeOf[msg.sender] = 0;
        (bool ok,) = recipient.call{value: s}("");
        require(ok);
    }

    function getDepositInfo(address account) external view returns (uint256 stake, bool staked, uint32 delay) {
        stake = stakeOf[account];
        delay = delayOf[account];
        staked = stake >= MIN_STAKE_VALUE && delay >= MIN_DELAY;
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IStakingRegistry} from "../../src/frame/IStakingRegistry.sol";

/// @notice Test stand-in with the devnet NaiveStakingRegistry's ABI and bookkeeping (stake per caller,
///         delay may not decrease, unlock starts the delay, withdraw after it). `isStaked` applies the
///         sidecar's rule (stake >= 0.01 ETH, delay >= 86,400, no withdrawal in progress).
contract MockStakingRegistry is IStakingRegistry {
    uint256 public constant MIN_STAKE_VALUE = 0.01 ether; // the devnet sidecar's minStake
    uint32 public constant MIN_DELAY = 86_400;

    struct Deposit {
        uint256 stake;
        uint32 unstakeDelaySec;
        uint64 withdrawTime;
    }

    mapping(address => Deposit) internal deposits;

    function addStake(uint32 unstakeDelaySec) external payable {
        Deposit storage d = deposits[msg.sender];
        require(unstakeDelaySec >= d.unstakeDelaySec, "cannot decrease unstake delay");
        d.stake += msg.value;
        d.unstakeDelaySec = unstakeDelaySec;
        d.withdrawTime = 0;
    }

    function unlockStake() external {
        Deposit storage d = deposits[msg.sender];
        require(d.stake > 0, "no stake");
        require(d.withdrawTime == 0, "already unlocking");
        d.withdrawTime = uint64(block.timestamp) + d.unstakeDelaySec;
    }

    function withdrawStake(address payable recipient) external {
        Deposit storage d = deposits[msg.sender];
        require(d.withdrawTime != 0 && block.timestamp >= d.withdrawTime, "not withdrawable");
        uint256 amount = d.stake;
        d.stake = 0;
        d.withdrawTime = 0;
        (bool ok,) = recipient.call{value: amount}("");
        require(ok);
    }

    function getDepositInfo(address account)
        external
        view
        returns (uint256 stake, uint32 unstakeDelaySec, uint64 withdrawTime)
    {
        Deposit storage d = deposits[account];
        return (d.stake, d.unstakeDelaySec, d.withdrawTime);
    }

    function isStaked(address account) external view returns (bool) {
        Deposit storage d = deposits[account];
        return d.stake >= MIN_STAKE_VALUE && d.unstakeDelaySec >= MIN_DELAY && d.withdrawTime == 0;
    }
}

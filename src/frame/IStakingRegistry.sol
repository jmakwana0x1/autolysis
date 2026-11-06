// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title IStakingRegistry
/// @notice The ERC-8421 staking registry, ABI-exact with the devnet's `NaiveStakingRegistry`
///         (lib/mempool-workshop-sidecar/deploy/predeploy/src/contracts/NaiveStakingRegistry.sol) at
///         0xd51c…2d2f. A sender stakes itself with `addStake`; the sidecar counts it as staked when
///         stake >= 0.01 ETH, delay >= 86,400 s and no withdrawal is in progress (withdrawTime == 0,
///         STAKING-010). On this sidecar staking lifts storage-access limits; MAX_VERIFY_GAS stays 100k.
interface IStakingRegistry {
    /// @notice Stake `msg.value`, locking it behind `unstakeDelaySec`. Called by the entity itself.
    function addStake(uint32 unstakeDelaySec) external payable;

    /// @notice Begin unlocking the stake (starts the delay).
    function unlockStake() external;

    /// @notice Withdraw the unlocked stake to `recipient`.
    function withdrawStake(address payable recipient) external;

    /// @notice Stake info for `account`. `withdrawTime != 0` means a withdrawal began (not staked).
    function getDepositInfo(address account)
        external
        view
        returns (uint256 stake, uint32 unstakeDelaySec, uint64 withdrawTime);
}

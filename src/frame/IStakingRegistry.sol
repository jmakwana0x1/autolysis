// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title IStakingRegistry
/// @notice The ERC-8421 staking registry (EntryPoint-style). A sender stakes itself by calling
///         `addStake` with value and an unstake delay; it counts as STAKED once its stake is at least
///         MIN_STAKE_VALUE and the delay is at least 86,400s. A staked sender gets ~1,000,000 validation
///         gas (vs 100,000) and read-only access to outside contracts in VERIFY (STORAGE-032). The
///         registry address on chain 1337 and MIN_STAKE_VALUE are devnet constants (to be confirmed with
///         the sidecar maintainer); it is read from deployments/1337.json.
interface IStakingRegistry {
    /// @notice Stake `msg.value`, locking it behind `unstakeDelaySec`. Called by the entity itself.
    function addStake(uint32 unstakeDelaySec) external payable;

    /// @notice Begin unlocking the stake (starts the delay).
    function unlockStake() external;

    /// @notice Withdraw the unlocked stake to `recipient`.
    function withdrawStake(address payable recipient) external;

    /// @notice Stake info for `account`: amount staked, whether it is locked (staked), and the delay.
    function getDepositInfo(address account) external view returns (uint256 stake, bool staked, uint32 unstakeDelaySec);
}

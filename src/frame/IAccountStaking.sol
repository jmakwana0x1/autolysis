// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title IAccountStaking
/// @notice The sidecar's staking surface. Under ERC-8421 (STORAGE-032) only a STAKED sender gets
///         read-only access to outside contracts during validation, and AutolysisAccount.verifyLiquidation
///         reads the market, the RoundFeed and the frame env. The account MUST be staked before it can
///         validate; the deploy script and `just reset` stake it, and probe 3 confirms staked vs
///         unstaked reads on chain. The exact staking contract address is read from deployments/1337.json.
interface IAccountStaking {
    function stake(address account) external payable;
    function isStaked(address account) external view returns (bool);
    function unstake(address account) external;
}

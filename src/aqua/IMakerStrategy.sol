// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title IMakerStrategy
/// @notice A maker strategy is the on-chain "script" a maker registers with the Aqua router. It is only
///         ever run from an allowlisted template, under a gas stipend, and only during a gated
///         liquidation. It answers how much USDC the maker will provide for a collateral slice at a
///         router-supplied price, and performs the wallet pull on commit.
/// @dev Models the SwapVM program: the router executes it with a capped gas stipend, so a strategy that
///      burns gas is cut off and its maker skipped. Templates are allowlisted by code hash.
interface IMakerStrategy {
    /// @notice Max USDC this maker is willing to provide right now (view; may read the maker wallet).
    function available() external view returns (uint256);

    /// @notice Pull `usdcAmount` USDC from the maker wallet to `to`. Returns the amount actually moved
    ///         (0 if the maker is empty / unwilling). MUST NOT revert on an empty wallet; return 0.
    function commit(address to, uint256 usdcAmount) external returns (uint256 moved);
}

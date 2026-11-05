// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title ISelfLiquidatingMarket
/// @notice Minimal surface a market exposes so the account (and future collateral adapters) can drive
///         a self-liquidation without knowing the market's internals.
interface ISelfLiquidatingMarket {
    function executeLiquidation(uint256 positionId, uint256 roundId, uint256 feeCap)
        external
        returns (uint256 debtRepaid, uint256 collateralSold, uint256 feeBilled);

    function healthFactor(uint256 positionId) external view returns (uint256);
    function liquidationCount(uint256 positionId) external view returns (uint256);
}

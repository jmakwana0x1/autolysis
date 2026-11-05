// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title ISwapVenue
/// @notice Where the market sells a slice of collateral during a liquidation. Phase 1 uses a plain
///         constant-price curve; phase 3 swaps in the Uniswap v4 BackstopHook; phase 4 adds the Aqua
///         waterfall behind the same call. The market always passes a minOut it computed itself.
interface ISwapVenue {
    /// @notice Set the cited round's oracle price (WAD) for the next sale, so the backstop prices against
    ///         the liquidation's round, not the latest round. Called by the market before sellCollateral.
    function setRoundPrice(uint256 price) external;

    /// @notice Sell exactly `collateralIn` collateral for at least `minDebtOut` debt token.
    /// @dev The market transfers `collateralIn` to the venue before calling (settle-before-swap), so
    ///      the venue pulls nothing; it returns the debt token to the market.
    function sellCollateral(uint256 collateralIn, uint256 minDebtOut) external returns (uint256 debtOut);
}

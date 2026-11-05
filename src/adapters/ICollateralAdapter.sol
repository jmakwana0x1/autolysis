// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title ICollateralAdapter
/// @notice Plugs an additional collateral type into an Autolysis market without the market knowing its
///         specifics. The adapter answers the market's valuation and sale questions; the market keeps
///         the health and step math in `LiquidationMath`. This is the seam the plan's "second-collateral
///         adapter skeleton" fills so a second asset can be added later without touching the core.
interface ICollateralAdapter {
    /// @notice The collateral token this adapter manages.
    function collateralToken() external view returns (address);

    /// @notice Price of one unit of this collateral in debt-token units (WAD), for health math.
    function priceWad(uint256 roundId) external view returns (uint256);

    /// @notice Sell `collateralIn` of this collateral for at least `minDebtOut` debt token, routing
    ///         through the configured venue (v4 pool + backstop hook). Returns debt raised.
    function sell(uint256 collateralIn, uint256 minDebtOut, bytes calldata routeData) external returns (uint256 debtOut);
}

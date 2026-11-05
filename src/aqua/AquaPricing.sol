// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title AquaPricing
/// @notice Pure oracle pricing for the Aqua tier: effective collateral price = oracle price − base
///         spread + volatility add-on (all WAD). One guarantee: the same function backs quote() and
///         swap(), so a quote always equals the fill.
library AquaPricing {
    uint256 internal constant WAD = 1e18;

    /// @param oraclePrice collateral price in USDC, WAD
    /// @param baseSpreadBps maker's base spread, bps of price (lowers the price the taker receives)
    /// @param volAddonBps volatility add-on, bps of price (raises it — makers demand more in calm, less
    ///        in stress; modeled as an additive surcharge the taker pays, i.e. a lower effective price)
    function effectivePrice(uint256 oraclePrice, uint256 baseSpreadBps, uint256 volAddonBps)
        internal
        pure
        returns (uint256)
    {
        uint256 cut = baseSpreadBps + volAddonBps;
        if (cut >= 10_000) return 0;
        return oraclePrice * (10_000 - cut) / 10_000;
    }

    /// @notice USDC out for selling `collateralIn` at the effective price (rounds down, protocol-safe).
    function usdcForCollateral(uint256 collateralIn, uint256 effPrice) internal pure returns (uint256) {
        return collateralIn * effPrice / WAD;
    }

    /// @notice Collateral needed to raise `usdcOut` at the effective price (rounds up).
    function collateralForUsdc(uint256 usdcOut, uint256 effPrice) internal pure returns (uint256) {
        if (effPrice == 0) return type(uint256).max;
        uint256 c = usdcOut * WAD / effPrice;
        if (c * effPrice / WAD < usdcOut) c += 1;
        return c;
    }
}

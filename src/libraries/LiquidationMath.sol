// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title LiquidationMath
/// @notice Pure liquidation arithmetic. One guarantee: a step never lowers the health factor, and it
///         sells no more collateral than the step needs.
/// @dev All ratios are WAD (1e18). Prices are collateral price in debt units, WAD. Close factor rises
///      from 10% at HF 1.00 to 100% at HF 0.95, linearly, and is 0 above 1.00 (healthy: nothing to do).
library LiquidationMath {
    uint256 internal constant WAD = 1e18;

    uint256 internal constant HF_RAMP_TOP = 1e18; // 1.00 -> 10%
    uint256 internal constant HF_RAMP_BOTTOM = 0.95e18; // 0.95 -> 100%
    uint256 internal constant CF_AT_TOP = 0.1e18;
    uint256 internal constant CF_AT_BOTTOM = 1e18;

    error TargetUnreachable();

    /// @notice health factor = collateral * price * liqThreshold / debt  (WAD); debt 0 => max.
    function healthFactor(uint256 collateral, uint256 price, uint256 liqThreshold, uint256 debt)
        internal
        pure
        returns (uint256)
    {
        if (debt == 0) return type(uint256).max;
        uint256 collateralValue = Math.mulDiv(collateral, price, WAD);
        uint256 weighted = Math.mulDiv(collateralValue, liqThreshold, WAD);
        return Math.mulDiv(weighted, WAD, debt);
    }

    /// @notice Close factor at a given health factor (WAD fraction of debt eligible this step).
    function closeFactor(uint256 hf) internal pure returns (uint256) {
        if (hf > HF_RAMP_TOP) return 0;
        if (hf <= HF_RAMP_BOTTOM) return CF_AT_BOTTOM;
        uint256 span = HF_RAMP_TOP - HF_RAMP_BOTTOM; // 0.05e18
        uint256 into = HF_RAMP_TOP - hf;
        uint256 extra = Math.mulDiv(into, CF_AT_BOTTOM - CF_AT_TOP, span);
        return CF_AT_TOP + extra;
    }

    struct Step {
        uint256 debtToRepay; // debt units, rounded down (<= eligible)
        uint256 collateralToSell; // collateral units, rounded up (protocol-favoring)
    }

    /// @notice Collateral to sell to repay `debtToRepay` at `price`, no bonus (self-liquidation). Rounds up.
    function collateralForDebt(uint256 debtToRepay, uint256 price) internal pure returns (uint256) {
        if (price == 0) revert TargetUnreachable();
        return Math.mulDivUp(debtToRepay, WAD, price);
    }

    /// @notice The step for an unhealthy position: repay the minimum to reach targetHf, capped at
    ///         closeFactor*debt and at what the position can cover.
    function computeStep(uint256 collateral, uint256 price, uint256 liqThreshold, uint256 debt, uint256 targetHf)
        internal
        pure
        returns (Step memory s)
    {
        uint256 hf = healthFactor(collateral, price, liqThreshold, debt);
        if (hf >= HF_RAMP_TOP || debt == 0) return s;

        uint256 eligible = Math.mulDiv(debt, closeFactor(hf), WAD);
        uint256 repayForTarget = _repayToReachTarget(collateral, price, liqThreshold, debt, targetHf);

        uint256 repay = repayForTarget < eligible ? repayForTarget : eligible;
        if (repay > debt) repay = debt;

        // The market must obtain enough USDC to clear `repay`, so collateral sold is rounded UP to
        // cover it (protocol-favoring: the borrower sells a hair more, never a hair less). Because a
        // liquidatable position operates over-collateralized by value (V > D, i.e. HF > liqThreshold),
        // the debt cleared per collateral unit (the price) exceeds the position's average, so the step
        // raises the health factor; the only erosion is sub-wei rounding, absorbed by that margin.
        s.debtToRepay = repay;
        s.collateralToSell = collateralForDebt(repay, price); // ceil
        if (s.collateralToSell > collateral) {
            s.collateralToSell = collateral;
            s.debtToRepay = Math.mulDiv(collateral, price, WAD); // only what the capped collateral covers
        }
    }

    /// @dev Debt x to repay so HF(C - x/price, D - x) >= targetHf, closed form, rounded UP.
    function _repayToReachTarget(
        uint256 collateral,
        uint256 price,
        uint256 liqThreshold,
        uint256 debt,
        uint256 targetHf
    ) private pure returns (uint256) {
        uint256 cv = Math.mulDiv(Math.mulDiv(collateral, price, WAD), liqThreshold, WAD);
        if (targetHf <= liqThreshold) return debt;
        uint256 rhs = Math.mulDiv(targetHf, debt, WAD);
        if (rhs <= cv) return 0;
        uint256 num = rhs - cv;
        uint256 denom = targetHf - liqThreshold;
        return Math.mulDivUp(num, WAD, denom);
    }
}

/// @dev Full-width mulDiv (OpenZeppelin algorithm) inlined to keep the math dependency-free for fuzzing.
library Math {
    function mulDiv(uint256 x, uint256 y, uint256 d) internal pure returns (uint256 result) {
        unchecked {
            uint256 prod0;
            uint256 prod1;
            assembly {
                let mm := mulmod(x, y, not(0))
                prod0 := mul(x, y)
                prod1 := sub(sub(mm, prod0), lt(mm, prod0))
            }
            if (prod1 == 0) {
                require(d != 0, "div by zero");
                return prod0 / d;
            }
            require(d > prod1, "mulDiv overflow");
            uint256 remainder;
            assembly {
                remainder := mulmod(x, y, d)
                prod1 := sub(prod1, gt(remainder, prod0))
                prod0 := sub(prod0, remainder)
            }
            uint256 twos = d & (0 - d);
            assembly {
                d := div(d, twos)
                prod0 := div(prod0, twos)
                twos := add(div(sub(0, twos), twos), 1)
            }
            prod0 |= prod1 * twos;
            uint256 inv = (3 * d) ^ 2;
            inv *= 2 - d * inv;
            inv *= 2 - d * inv;
            inv *= 2 - d * inv;
            inv *= 2 - d * inv;
            inv *= 2 - d * inv;
            inv *= 2 - d * inv;
            result = prod0 * inv;
        }
    }

    function mulDivUp(uint256 x, uint256 y, uint256 d) internal pure returns (uint256 r) {
        r = mulDiv(x, y, d);
        if (mulmod(x, y, d) != 0) r += 1;
    }
}

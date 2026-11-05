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
        uint256 debtToRepay; // debt the step intends to clear (reduced by USDC actually received)
        uint256 collateralToSell; // collateral units to sell (rounded up to cover the sale at the haircut)
        uint256 minOut; // minimum debt token out the venue must return (floor of the haircut price)
        bool insolvent; // true when the position is bad debt (HF <= L/(1-s)): sell everything
    }

    /// @notice Collateral to sell to repay `debtToRepay` at `price`, no bonus (self-liquidation). Rounds up.
    function collateralForDebt(uint256 debtToRepay, uint256 price) internal pure returns (uint256) {
        if (price == 0) revert TargetUnreachable();
        return Math.mulDivUp(debtToRepay, WAD, price);
    }

    /// @notice Effective sale price after the slippage/haircut `s` (WAD): price * (1 - s).
    function effectivePrice(uint256 price, uint256 s) internal pure returns (uint256) {
        return Math.mulDiv(price, WAD - s, WAD);
    }

    /// @notice The step for an unhealthy position, accounting for a sale haircut `s` (WAD). Repays the
    ///         minimum to reach targetHf, capped at closeFactor*debt and at what the position can cover,
    ///         and sells collateral at the haircut price so a real venue (pool fee, maker/hook spread)
    ///         still clears `minOut`. When the position is underwater past L/(1-s) it is bad debt: the
    ///         step sells all collateral and flags `insolvent` for the market to record.
    function computeStep(
        uint256 collateral,
        uint256 price,
        uint256 liqThreshold,
        uint256 debt,
        uint256 targetHf,
        uint256 s
    ) internal pure returns (Step memory step) {
        if (price == 0) revert TargetUnreachable();
        uint256 hf = healthFactor(collateral, price, liqThreshold, debt);
        if (hf >= HF_RAMP_TOP || debt == 0) return step;

        uint256 ps = effectivePrice(price, s); // haircut price
        // Insolvency threshold HF <= L/(1-s): below it no fair-value sale can reach the target, so the
        // close factor is 100% and the whole position is wound down.
        uint256 insolvencyHf = Math.mulDiv(liqThreshold, WAD, WAD - s);
        if (hf <= insolvencyHf) {
            step.collateralToSell = collateral;
            step.minOut = Math.mulDiv(collateral, ps, WAD);
            step.debtToRepay = step.minOut < debt ? step.minOut : debt; // can't clear more than owed
            step.insolvent = step.debtToRepay < debt; // bad debt if the sale can't cover the debt
            return step;
        }

        uint256 eligible = Math.mulDiv(debt, closeFactor(hf), WAD);
        uint256 repay = _repayToReachTarget(collateral, price, liqThreshold, debt, targetHf, s);
        if (repay > eligible) repay = eligible;
        if (repay > debt) repay = debt;

        // Sell collateral at the haircut price, rounded up so the sale covers `repay`; minOut floors it.
        uint256 x = Math.mulDivUp(repay, WAD, ps);
        if (x > collateral) {
            x = collateral;
            repay = Math.mulDiv(x, ps, WAD); // capped collateral only covers this much
        }
        step.collateralToSell = x;
        step.minOut = Math.mulDiv(x, ps, WAD);
        step.debtToRepay = repay;
    }

    /// @dev Debt r to repay so HF after selling r/(P(1-s)) collateral reaches targetHf:
    ///      r = (T*D - C*P*L) / (T - L/(1-s)). Requires T*(1-s) > L (caller guards via the insolvency
    ///      branch). Rounded up so the target is met.
    function _repayToReachTarget(
        uint256 collateral,
        uint256 price,
        uint256 liqThreshold,
        uint256 debt,
        uint256 targetHf,
        uint256 s
    ) private pure returns (uint256) {
        uint256 weightedV = Math.mulDiv(Math.mulDiv(collateral, price, WAD), liqThreshold, WAD); // C*P*L
        uint256 td = Math.mulDiv(targetHf, debt, WAD); // T*D
        if (td <= weightedV) return 0; // already at/above target
        uint256 num = td - weightedV;
        uint256 lOverOneMinusS = Math.mulDiv(liqThreshold, WAD, WAD - s); // L/(1-s), WAD
        // denominator T - L/(1-s) is positive here because the insolvency branch handled hf <= L/(1-s)
        uint256 denom = targetHf - lOverOneMinusS;
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

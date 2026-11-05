// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {LiquidationMath, Math} from "../../src/libraries/LiquidationMath.sol";

contract LiquidationMathTest is Test {
    uint256 constant WAD = 1e18;

    function _bound(uint256 c, uint256 p, uint256 lt, uint256 d)
        internal
        pure
        returns (uint256, uint256, uint256, uint256)
    {
        c = bound(c, 1e6, 1e30);
        p = bound(p, 1e6, 1e30);
        lt = bound(lt, 0.5e18, 0.95e18);
        d = bound(d, 1e6, 1e30);
        return (c, p, lt, d);
    }

    // Close factor exactly 10% at HF 1.00 and 100% at HF 0.95, monotonic non-decreasing as HF falls.
    function test_closeFactorEndpoints() public pure {
        assertEq(LiquidationMath.closeFactor(1e18), 0.1e18);
        assertEq(LiquidationMath.closeFactor(0.95e18), 1e18);
        assertEq(LiquidationMath.closeFactor(0.94e18), 1e18);
        assertEq(LiquidationMath.closeFactor(1.01e18), 0);
    }

    function testFuzz_closeFactorMonotonic(uint256 hfHi, uint256 hfLo) public pure {
        hfHi = bound(hfHi, 0.9e18, 1.0e18);
        hfLo = bound(hfLo, 0.9e18, hfHi);
        // lower HF => close factor >= that at higher HF
        assertGe(LiquidationMath.closeFactor(hfLo), LiquidationMath.closeFactor(hfHi));
    }

    // A liquidation step never lowers the health factor.
    function testFuzz_stepNeverLowersHF(uint256 c, uint256 p, uint256 lt, uint256 hfWanted, uint256 target)
        public
        pure
    {
        c = bound(c, 1e12, 1e30);
        p = bound(p, 1e6, 1e30);
        lt = bound(lt, 0.5e18, 0.9e18);
        // Construct a liquidatable, over-collateralized position by choosing the health factor directly:
        // d = V*lt/hf with lt < hf < 1 guarantees HF in (lt, 1) and collateral value V > debt.
        hfWanted = bound(hfWanted, lt + 0.01e18, 0.999e18);
        target = bound(target, 0.95e18, 1.05e18);

        uint256 d = Math.mulDiv(Math.mulDiv(c, p, WAD), lt, hfWanted);
        vm.assume(d >= 1e6 && d <= 1e30);

        uint256 hfBefore = LiquidationMath.healthFactor(c, p, lt, d);
        vm.assume(hfBefore < 1e18 && hfBefore > lt);
        LiquidationMath.Step memory s = LiquidationMath.computeStep(c, p, lt, d, target);

        if (s.debtToRepay == 0) return;
        assertLe(s.debtToRepay, d);
        assertLe(s.collateralToSell, c);
        if (s.collateralToSell == c || s.debtToRepay == d) return; // terminal/full close
        _assertHfNotLowered(c, p, lt, d, s, hfBefore);
    }

    function _assertHfNotLowered(
        uint256 c,
        uint256 p,
        uint256 lt,
        uint256 d,
        LiquidationMath.Step memory s,
        uint256 hfBefore
    ) internal pure {
        uint256 dAfter = d - s.debtToRepay;
        uint256 hfAfter = LiquidationMath.healthFactor(c - s.collateralToSell, p, lt, dAfter);
        // Collateral is indivisible: covering a tiny repay rounds the sale up by up to one unit, which
        // can erode HF by at most that unit's contribution. Above that dust the step never lowers HF.
        uint256 tol = 2 + Math.mulDiv(Math.mulDiv(2, p, WAD), lt, WAD) * WAD / dAfter;
        if (hfAfter >= hfBefore) return;
        assertLe(hfBefore - hfAfter, tol, "step lowered HF beyond one-unit rounding");
    }

    // Selling one wei less would under-repay: collateralForDebt rounds up.
    function testFuzz_collateralRoundsUp(uint256 debt, uint256 price) public pure {
        debt = bound(debt, 1, 1e30);
        price = bound(price, 1e6, 1e30);
        uint256 sell = LiquidationMath.collateralForDebt(debt, price);
        // sell * price / WAD >= debt (covers), and (sell-1) * price / WAD < debt (minimal) when sell>0
        assertGe(Math.mulDiv(sell, price, WAD), debt);
        if (sell > 0) {
            assertLt(Math.mulDiv(sell - 1, price, WAD), debt);
        }
    }

    // Repay never exceeds the eligible close-factor amount.
    function testFuzz_repayWithinCloseFactor(uint256 c, uint256 p, uint256 lt, uint256 d, uint256 target) public pure {
        (c, p, lt, d) = _bound(c, p, lt, d);
        target = bound(target, 0.95e18, 1.05e18);
        uint256 hf = LiquidationMath.healthFactor(c, p, lt, d);
        vm.assume(hf < 1e18);
        LiquidationMath.Step memory s = LiquidationMath.computeStep(c, p, lt, d, target);
        uint256 eligible = Math.mulDiv(d, LiquidationMath.closeFactor(hf), WAD);
        assertLe(s.debtToRepay, eligible + 1); // +1 for the collateral-cap re-floor rounding
    }

    // HF is monotonic in debt (sanity for the handler invariants later).
    function testFuzz_hfDecreasesWithDebt(uint256 c, uint256 p, uint256 lt, uint256 d1, uint256 d2) public pure {
        (c, p, lt, d1) = _bound(c, p, lt, d1);
        d2 = bound(d2, d1, 1e30);
        assertGe(LiquidationMath.healthFactor(c, p, lt, d1), LiquidationMath.healthFactor(c, p, lt, d2));
    }
}

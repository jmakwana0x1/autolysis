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
        lt = bound(lt, 0.5e18, 0.9e18);
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
        assertGe(LiquidationMath.closeFactor(hfLo), LiquidationMath.closeFactor(hfHi));
    }

    // A solvent liquidation step never lowers the health factor. "Solvent" means HF before the step is
    // above the insolvency threshold L/(1-s); below that the position is bad debt (its own branch).
    // With a real sale haircut and a target T > 1, a non-terminal step raises HF with no rounding slack.
    function testFuzz_stepNeverLowersHF(uint256 c, uint256 p, uint256 lt, uint256 hfWanted, uint256 target, uint256 s)
        public
        pure
    {
        c = bound(c, 1e12, 1e30);
        p = bound(p, 1e6, 1e30);
        lt = bound(lt, 0.5e18, 0.9e18);
        s = bound(s, 0, 0.03e18);
        uint256 insolvencyHf = Math.mulDiv(lt, WAD, WAD - s);
        // Construct an over-collateralized, liquidatable, SOLVENT position: HF in (L/(1-s), 1).
        hfWanted = bound(hfWanted, insolvencyHf + 0.005e18, 0.999e18);
        vm.assume(hfWanted < 1e18);
        target = bound(target, 1.01e18, 1.1e18);

        uint256 d = Math.mulDiv(Math.mulDiv(c, p, WAD), lt, hfWanted);
        vm.assume(d >= 1e6 && d <= 1e30);

        uint256 hfBefore = LiquidationMath.healthFactor(c, p, lt, d);
        vm.assume(hfBefore < 1e18 && hfBefore > insolvencyHf);
        LiquidationMath.Step memory step = LiquidationMath.computeStep(c, p, lt, d, target, s);

        if (step.debtToRepay == 0) return;
        assertLe(step.debtToRepay, d);
        assertLe(step.collateralToSell, c);
        if (step.collateralToSell == c || step.debtToRepay == d) return; // terminal/full close
        uint256 hfAfter = LiquidationMath.healthFactor(c - step.collateralToSell, p, lt, d - step.debtToRepay);
        assertGe(hfAfter, hfBefore, "solvent step lowered HF");
    }

    // minOut rounds DOWN (protocol-favoring): a venue selling at the oracle price always clears it, and
    // the step sells enough collateral at the haircut price to cover what it intends to repay.
    function testFuzz_minOutIsCovered(uint256 c, uint256 p, uint256 lt, uint256 d, uint256 target, uint256 s)
        public
        pure
    {
        (c, p, lt, d) = _bound(c, p, lt, d);
        target = bound(target, 1.01e18, 1.1e18);
        s = bound(s, 0, 0.03e18);
        uint256 hf = LiquidationMath.healthFactor(c, p, lt, d);
        vm.assume(hf < 1e18);
        LiquidationMath.Step memory step = LiquidationMath.computeStep(c, p, lt, d, target, s);
        if (step.collateralToSell == 0) return;
        // Selling at the full oracle price (no haircut) yields at least minOut.
        assertGe(Math.mulDiv(step.collateralToSell, p, WAD), step.minOut, "oracle sale below minOut");
        // minOut is the floor of the haircut sale of the collateral actually sold.
        assertEq(step.minOut, Math.mulDiv(step.collateralToSell, LiquidationMath.effectivePrice(p, s), WAD));
    }

    // Repay never exceeds the eligible close-factor amount (solvent branch).
    function testFuzz_repayWithinCloseFactor(
        uint256 c,
        uint256 p,
        uint256 lt,
        uint256 hfWanted,
        uint256 target,
        uint256 s
    ) public pure {
        c = bound(c, 1e12, 1e30);
        p = bound(p, 1e6, 1e30);
        lt = bound(lt, 0.5e18, 0.9e18);
        s = bound(s, 0, 0.03e18);
        uint256 insolvencyHf = Math.mulDiv(lt, WAD, WAD - s);
        hfWanted = bound(hfWanted, insolvencyHf + 0.005e18, 0.999e18);
        vm.assume(hfWanted < 1e18);
        target = bound(target, 1.01e18, 1.1e18);
        uint256 d = Math.mulDiv(Math.mulDiv(c, p, WAD), lt, hfWanted);
        vm.assume(d >= 1e6 && d <= 1e30);
        uint256 hf = LiquidationMath.healthFactor(c, p, lt, d);
        vm.assume(hf < 1e18 && hf > insolvencyHf);
        LiquidationMath.Step memory step = LiquidationMath.computeStep(c, p, lt, d, target, s);
        uint256 eligible = Math.mulDiv(d, LiquidationMath.closeFactor(hf), WAD);
        assertLe(step.debtToRepay, eligible + 1); // +1 for the collateral-cap re-floor rounding
    }

    // Insolvency branch: at HF <= L/(1-s) the whole position is sold and flagged as bad debt when the
    // sale cannot cover the debt.
    function testFuzz_insolventSellsAll(uint256 c, uint256 p, uint256 lt, uint256 d, uint256 s) public pure {
        c = bound(c, 1e12, 1e30);
        p = bound(p, 1e6, 1e30);
        lt = bound(lt, 0.5e18, 0.9e18);
        s = bound(s, 0, 0.03e18);
        uint256 insolvencyHf = Math.mulDiv(lt, WAD, WAD - s);
        // Force HF <= insolvencyHf by choosing a large debt.
        d = Math.mulDiv(Math.mulDiv(c, p, WAD), lt, insolvencyHf) + 1e18;
        vm.assume(d <= 1e36);
        uint256 hf = LiquidationMath.healthFactor(c, p, lt, d);
        vm.assume(hf > 0 && hf <= insolvencyHf);
        LiquidationMath.Step memory step = LiquidationMath.computeStep(c, p, lt, d, 1.05e18, s);
        assertEq(step.collateralToSell, c, "insolvent step should sell all collateral");
    }

    function testFuzz_hfDecreasesWithDebt(uint256 c, uint256 p, uint256 lt, uint256 d1, uint256 d2) public pure {
        (c, p, lt, d1) = _bound(c, p, lt, d1);
        d2 = bound(d2, d1, 1e30);
        assertGe(LiquidationMath.healthFactor(c, p, lt, d1), LiquidationMath.healthFactor(c, p, lt, d2));
    }
}

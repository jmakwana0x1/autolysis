import { describe, it, expect } from "vitest";
import { simulate, bounceTrace, replacementTrace, throttledAt, START, THROTTLE } from "../src/sim/exo010.js";

describe("EXO-010 reputation simulator", () => {
  it("is reproducible: same trace -> same numbers", () => {
    const a = simulate(bounceTrace(150));
    const b = simulate(bounceTrace(150));
    expect(a.baselineFinal).toBe(b.baselineFinal);
    expect(a.proposedFinal).toBe(b.proposedFinal);
  });

  it("oracle bounce: proposed rule keeps honest carriers above the throttle, baseline does not", () => {
    const { series, baselineFinal, proposedFinal } = simulate(bounceTrace(150));
    expect(baselineFinal).toBeLessThan(THROTTLE); // baseline throttles after a bounce
    expect(proposedFinal).toBeGreaterThanOrEqual(THROTTLE); // proposed forgives the bounce
    expect(throttledAt(series, "proposed").length).toBe(0);
    expect(throttledAt(series, "baseline").length).toBeGreaterThan(0);
  });

  it("replacement never moves reputation under either rule", () => {
    const { series } = simulate(replacementTrace(20));
    // before the single inclusion at the end, reputation is unchanged from START
    const beforeInclusion = series[series.length - 2];
    expect(beforeInclusion.baseline).toBe(START);
    expect(beforeInclusion.proposed).toBe(START);
  });

  it("genuine misses (not a bounce) still penalize under both rules", () => {
    const r = simulate([{ t: 1, kind: "miss", bounce: false }]);
    expect(r.baselineFinal).toBeLessThan(START);
    expect(r.proposedFinal).toBeLessThan(START);
    expect(r.baselineFinal).toBe(r.proposedFinal);
  });
});

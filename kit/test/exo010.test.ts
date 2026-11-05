import { describe, it, expect } from "vitest";
import { simulate, bounceTrace, replacementTrace, status } from "../src/sim/exo010.js";

describe("EXO-010 reputation simulator (ERC-8421 rules)", () => {
  it("is reproducible: same trace -> same counters", () => {
    const a = simulate(bounceTrace(600));
    const b = simulate(bounceTrace(600));
    expect(a.baseline).toEqual(b.baseline);
    expect(a.proposed).toEqual(b.proposed);
  });

  it("oracle bounce: baseline is BANNED/THROTTLED, proposed stays ACTIVE", () => {
    // Enough external misses that baseline max_seen (seen/10) exceeds included+50.
    const r = simulate(bounceTrace(600));
    expect(r.baselineStatus).not.toBe("ACTIVE");
    expect(r.proposedStatus).toBe("ACTIVE");
  });

  it("REPUTATION-040: a replacement changes no counter", () => {
    const r = simulate(replacementTrace(30));
    // only the single inclusion at the end moved the counters
    expect(r.baseline).toEqual({ seen: 1, included: 1 });
    expect(r.proposed).toEqual({ seen: 1, included: 1 });
  });

  it("REPUTATION-330: a staked sender absorbs external misses", () => {
    const trace = bounceTrace(600);
    const unstaked = simulate(trace, { staked: false });
    const stakedRun = simulate(trace, { staked: true });
    expect(stakedRun.baseline.seen).toBeLessThan(unstaked.baseline.seen);
    expect(stakedRun.baselineStatus).toBe("ACTIVE");
  });

  it("a genuine (non-external) miss still raises seen under both rules", () => {
    const r = simulate([{ kind: "miss", external: false }]);
    expect(r.baseline.seen).toBe(1);
    expect(r.proposed.seen).toBe(1);
  });

  it("hourly decay shrinks the counters", () => {
    const grow = Array.from({ length: 240 }, () => ({ kind: "miss", external: false }) as const);
    const r = simulate([...grow, { kind: "hour" }]);
    // after 240 misses seen=240; one hour of decay -> floor(240*23/24)=230
    expect(r.baseline.seen).toBe(230);
  });

  it("status thresholds", () => {
    expect(status({ seen: 100, included: 0 })).toBe("ACTIVE"); // max_seen 10 <= 10
    expect(status({ seen: 300, included: 0 })).toBe("THROTTLED"); // 30 <= 50
    expect(status({ seen: 600, included: 0 })).toBe("BANNED"); // 60 > 50
  });
});

import { describe, it, expect } from "vitest";
import { simulate, bounceTrace, replacementTrace, status } from "../src/sim/exo010.js";

describe("EXO-010 reputation simulator (ERC-8421 rules)", () => {
  it("reproducible", () => {
    expect(simulate(bounceTrace(150)).baseline).toEqual(simulate(bounceTrace(150)).baseline);
  });

  it("the canonical bounce: baseline THROTTLED (seen 153), proposed ACTIVE (seen 3)", () => {
    const r = simulate(bounceTrace(150)); // 3 inclusions, then 150 outside-caused misses
    expect(r.baseline).toEqual({ seen: 153, included: 3 }); // admission counts every tx
    expect(r.baselineStatus).toBe("THROTTLED"); // max_seen 15 > included+10, <= included+50
    expect(r.proposed).toEqual({ seen: 3, included: 3 }); // bounce admissions cancelled
    expect(r.proposedStatus).toBe("ACTIVE");
  });

  it("proposed is never worse than if the misses had not happened", () => {
    const withBounce = simulate(bounceTrace(150)).proposed.seen;
    const noBounce = simulate(bounceTrace(0)).proposed.seen; // just the 3 inclusions
    expect(withBounce).toBe(noBounce);
  });

  it("a genuine (non-external) miss raises seen under both rules (+1 admission, kept)", () => {
    const r = simulate([{ kind: "miss", external: false }]);
    expect(r.baseline.seen).toBe(1);
    expect(r.proposed.seen).toBe(1);
  });

  it("REPUTATION-040: a replacement changes no counter", () => {
    const r = simulate(replacementTrace(30));
    expect(r.baseline).toEqual({ seen: 1, included: 1 });
  });

  it("hourly decay shrinks the counters", () => {
    const grow = Array.from({ length: 240 }, () => ({ kind: "miss", external: false }) as const);
    expect(simulate([...grow, { kind: "hour" }]).baseline.seen).toBe(230);
  });

  it("status thresholds", () => {
    expect(status({ seen: 100, included: 0 })).toBe("ACTIVE");
    expect(status({ seen: 300, included: 0 })).toBe("THROTTLED");
    expect(status({ seen: 600, included: 0 })).toBe("BANNED");
  });
});

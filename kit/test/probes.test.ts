import { describe, it, expect } from "vitest";
import { probes, mayPin, REQUIRED_FOR_PIN, type ProbeCtx } from "../src/probes/probes.js";
import { readProbes } from "../src/registry.js";

const ACCOUNT = "0x000000000000000000000000000000000000A11c" as `0x${string}`;

function ctx(call: ProbeCtx["call"]): ProbeCtx {
  return { call, probes: structuredClone(readProbes()), account: ACCOUNT, probeOpcodes: ACCOUNT };
}

describe("devnet probes", () => {
  it("records works:false when the node rejects a simulate (opcode support)", async () => {
    const c = ctx(async () => {
      throw new Error("opcode 0xaa not supported");
    });
    await probes[0].run(c);
    expect(Object.values(c.probes.opcodes).every((o) => o.works === false)).toBe(true);
  });

  it("records works:true when a simulate succeeds", async () => {
    const c = ctx(async () => ({}));
    await probes[0].run(c);
    expect(Object.values(c.probes.opcodes).every((o) => o.works === true)).toBe(true);
  });

  it("fee probe records the matching formula and throws on neither", async () => {
    const total = ctx(async () => ({ maxCost: "1000", totalGas: "100", maxFeePerGas: "10" }));
    await probes[1].run(total);
    expect(total.probes.feeFormat).toBe("total_cost");
    const neither = ctx(async () => ({ maxCost: "7", totalGas: "100", maxFeePerGas: "10" }));
    await expect(probes[1].run(neither)).rejects.toThrow();
  });

  it("never pins while any required field is unconfirmed (probes 4-8 unimplemented)", () => {
    // Even if 1-3 confirmed, the removed probes' fields are never in the set.
    const partial = new Set(["opcodes", "feeFormat", "stakedExternalReads"]);
    expect(mayPin(partial)).toBe(false);
    // Only a full confirmation set pins.
    expect(mayPin(new Set(REQUIRED_FOR_PIN))).toBe(true);
  });
});

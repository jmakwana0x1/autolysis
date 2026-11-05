import { describe, it, expect } from "vitest";
import { probes, mayPin, REQUIRED_FOR_PIN, type ProbeCtx } from "../src/probes/probes.js";
import { readProbes } from "../src/registry.js";

const ACCOUNT = "0x000000000000000000000000000000000000A11c" as `0x${string}`;

function ctx(call: ProbeCtx["call"], extra: Partial<ProbeCtx> = {}): ProbeCtx {
  return { call, probes: structuredClone(readProbes()), account: ACCOUNT, probeOpcodes: ACCOUNT, ...extra };
}

describe("devnet probes", () => {
  it("opcode support: confirmed only when every frame reports success", async () => {
    const c = ctx(async () => ({ frames: [{ status: 0 }] }));
    await probes[0].run(c);
    expect(Object.values(c.probes.opcodes).every((o) => o.works === true)).toBe(true);
    expect(c.probes.rawSimulateResponse).toBeDefined(); // raw response recorded on first run
  });

  it("opcode support: a non-success frame status leaves it unconfirmed (throws, opcodes stay null)", async () => {
    const c = ctx(async () => ({ frames: [{ status: 1 }] }));
    await expect(probes[0].run(c)).rejects.toThrow();
    expect(Object.values(c.probes.opcodes).every((o) => o.works === null)).toBe(true);
  });

  it("fee format: matches the receipt log against total vs per-gas", async () => {
    const total = ctx(async () => ({}), {
      sendFeeProbe: async () => ({ maxCost: 1000n, totalGas: 100n, maxFeePerGas: 10n }),
    });
    await probes[1].run(total);
    expect(total.probes.feeFormat).toBe("total_cost");
    const neither = ctx(async () => ({}), {
      sendFeeProbe: async () => ({ maxCost: 7n, totalGas: 100n, maxFeePerGas: 10n }),
    });
    await expect(probes[1].run(neither)).rejects.toThrow();
  });

  it("never pins while any required field is unconfirmed", () => {
    expect(mayPin(new Set(["opcodes", "feeFormat", "stakedExternalReads"]))).toBe(false);
    expect(mayPin(new Set(REQUIRED_FOR_PIN))).toBe(true);
  });
});

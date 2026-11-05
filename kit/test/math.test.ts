import { describe, it, expect } from "vitest";
import { healthFactor, closeFactor, computeStep, WAD, mulDivUp } from "../src/math.js";
import { nonceKeyFor } from "../src/frameTx.js";

describe("LiquidationMath (kit)", () => {
  it("close factor endpoints", () => {
    expect(closeFactor(WAD)).toBe(10n ** 17n);
    expect(closeFactor(95n * 10n ** 16n)).toBe(WAD);
    expect(closeFactor(101n * 10n ** 16n)).toBe(0n);
  });
  it("healthy position yields empty step", () => {
    const s = computeStep(100n * WAD, 2n * WAD, 8n * 10n ** 17n, 100n * WAD, 105n * 10n ** 16n, 10n ** 16n);
    expect(s.debtToRepay).toBe(0n);
  });
  it("unhealthy position produces a covering sale", () => {
    // 100 col @1.5, lt 0.9, debt 150 -> HF 0.9
    const s = computeStep(100n * WAD, 15n * 10n ** 17n, 8n * 10n ** 17n, 150n * WAD, 105n * 10n ** 16n, 10n ** 16n);
    expect(s.debtToRepay).toBeGreaterThan(0n);
    expect(s.minOut).toBeGreaterThan(0n);
    // the venue selling at the oracle price (no haircut) always clears minOut
    expect((s.collateralToSell * 15n * 10n ** 17n) / WAD).toBeGreaterThanOrEqual(s.minOut);
  });
  it("nonce key clears the top byte", () => {
    const k = nonceKeyFor("0x000000000000000000000000000000000000dEaD" as `0x${string}`, 42n);
    expect(k >> 248n).toBe(0n);
  });
});

import { describe, it, expect, beforeEach } from "vitest";
import { Carrier } from "../src/carrier.js";
import type { Address, Hex } from "viem";

const ACCOUNT = "0x000000000000000000000000000000000000A11c" as Address;
const MARKET = "0x0000000000000000000000000000000000Ma0000".replace("Ma", "aa") as Address;

function makeCarrier(headroom: () => bigint) {
  const submitted: Hex[] = [];
  const c = new Carrier({
    chainId: 1337,
    account: ACCOUNT,
    market: MARKET,
    client: {} as never,
    submit: async (raw) => {
      submitted.push(raw);
      return ("0x" + "11".repeat(32)) as Hex;
    },
    tankHeadroom: async () => headroom(),
  });
  return { c, submitted };
}

const base = {
  positionId: 1n,
  roundId: 5n,
  sequence: 0n,
  baseFeePerGas: 1_000_000_000n,
  verifyGas: 200_000n,
  verifyStateLimit: 150_000n,
  executeGas: 300_000n,
};

describe("Carrier (replacement + tank-aware concurrency)", () => {
  it("submits a fresh liquidation when the tank has headroom", async () => {
    const { c, submitted } = makeCarrier(() => 3n);
    const r = await c.liquidate(base);
    expect(r.submitted).toBe(true);
    expect(r.replaced).toBe(false);
    expect(submitted.length).toBe(1);
    expect(c.pendingCount()).toBe(1);
  });

  it("refuses a new liquidation when the tank has no headroom", async () => {
    const { c, submitted } = makeCarrier(() => 0n);
    const r = await c.liquidate(base);
    expect(r.submitted).toBe(false);
    expect(submitted.length).toBe(0);
    expect(c.pendingCount()).toBe(0);
  });

  it("replaces on a new round with a >=10% fee bump, reusing the slot (no extra headroom needed)", async () => {
    const { c, submitted } = makeCarrier(() => 1n); // only one slot of headroom
    await c.liquidate(base);
    // headroom now effectively consumed by the pending one; a replacement must still go through.
    const r = await c.liquidate({ ...base, roundId: 6n });
    expect(r.submitted).toBe(true);
    expect(r.replaced).toBe(true);
    expect(submitted.length).toBe(2);
    expect(c.pendingCount()).toBe(1); // still one position pending
  });

  it("does not resubmit at the same round", async () => {
    const { c } = makeCarrier(() => 5n);
    await c.liquidate(base);
    const r = await c.liquidate(base);
    expect(r.submitted).toBe(false);
  });

  it("invalidate drops the pending liquidation (rescue)", async () => {
    const { c } = makeCarrier(() => 5n);
    await c.liquidate(base);
    c.invalidate(1n);
    expect(c.pendingCount()).toBe(0);
  });
});

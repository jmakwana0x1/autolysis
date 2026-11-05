import { describe, it, expect } from "vitest";
import { Carrier } from "../src/carrier.js";
import type { FrameTx } from "../src/frameTx.js";
import type { Address } from "viem";

const ACCOUNT = "0x000000000000000000000000000000000000A11c" as Address;
const MARKET = "0x0000000000000000000000000000000000000aaa" as Address;

function makeCarrier(headroom: () => bigint) {
  const submitted: FrameTx[] = [];
  const c = new Carrier({
    chainId: 1337,
    account: ACCOUNT,
    market: MARKET,
    submit: async (tx) => {
      submitted.push(tx);
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
  it("submits when the tank has headroom", async () => {
    const { c, submitted } = makeCarrier(() => 3n);
    const r = await c.liquidate(base);
    expect(r.submitted).toBe(true);
    expect(submitted.length).toBe(1);
  });
  it("refuses a new liquidation when the tank has no headroom", async () => {
    const { c, submitted } = makeCarrier(() => 0n);
    const r = await c.liquidate(base);
    expect(r.submitted).toBe(false);
    expect(submitted.length).toBe(0);
  });
  it("replaces on a new round with a >=10% fee bump, reusing the slot", async () => {
    const { c, submitted } = makeCarrier(() => 1n);
    await c.liquidate(base);
    const r = await c.liquidate({ ...base, roundId: 6n });
    expect(r.submitted && r.replaced).toBe(true);
    expect(submitted.length).toBe(2);
    expect(c.pendingCount()).toBe(1);
  });
  it("does not resubmit at the same round", async () => {
    const { c } = makeCarrier(() => 5n);
    await c.liquidate(base);
    expect((await c.liquidate(base)).submitted).toBe(false);
  });
  it("invalidate drops the pending liquidation (rescue)", async () => {
    const { c } = makeCarrier(() => 5n);
    await c.liquidate(base);
    c.invalidate(1n);
    expect(c.pendingCount()).toBe(0);
  });
});

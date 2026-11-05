import { describe, it, expect } from "vitest";
import { canonicalLiquidationTx, encodeFrameTx, profile, nonceKeyFor } from "../src/frameTx.js";
import { appendKey, dirtyTopByte, dropVerifyScope, reorderFrames } from "../src/attacks.js";
import { decodeTx } from "@forshtat/hegota-support/tx";
import type { Address } from "viem";

const p = {
  chainId: 1337,
  account: "0x000000000000000000000000000000000000A11c" as Address,
  market: "0x0000000000000000000000000000000000000aaa" as Address,
  positionId: 1n,
  roundId: 5n,
  sequence: 0n,
  maxFeePerGas: 1_000_000_000n,
  verifyGas: 200_000n,
  verifyStateLimit: 150_000n,
  executeGas: 300_000n,
};

describe("canonical frame tx (real hegota-support encoder)", () => {
  it("round-trips through encodeTx/decodeTx", () => {
    const tx = canonicalLiquidationTx(p);
    const back = decodeTx(profile, encodeFrameTx(tx));
    expect(back.sender.toLowerCase()).toBe(p.account.toLowerCase());
    expect(back.nonceKeys[0]).toBe(nonceKeyFor(p.market, p.positionId));
    expect(back.frames.length).toBe(2);
  });
  it("the VERIFY frame carries the EXECUTION_AND_PAYMENT scope in its flags", () => {
    const tx = canonicalLiquidationTx(p);
    expect(tx.frames[0].flags & 3).toBe(3); // scope bits = 3
    expect(tx.nonceKeys[0] >> 248n).toBe(0n); // top byte cleared
  });
  it("attack builders mutate exactly one thing and still encode", () => {
    expect(appendKey(p, 7n).nonceKeys.length).toBe(2);
    expect(dirtyTopByte(p).nonceKeys[0] >> 248n).not.toBe(0n);
    expect(dropVerifyScope(p).frames[0].flags & 3).toBe(0);
    expect(reorderFrames(p).frames[0].mode).toBe(canonicalLiquidationTx(p).frames[1].mode);
    for (const t of [appendKey(p, 7n), dirtyTopByte(p), dropVerifyScope(p), reorderFrames(p)]) {
      expect(encodeFrameTx(t).startsWith("0x")).toBe(true);
    }
  });
});

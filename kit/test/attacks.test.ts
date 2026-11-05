import { describe, it, expect } from "vitest";
import { canonicalLiquidationTx, serializeFrameTx } from "../src/frameTx.js";
import { appendKey, dirtyTopByte, overCapFee, wrongRound, reorderFrames } from "../src/attacks.js";
import type { Address } from "viem";

const p = {
  chainId: 1337,
  account: "0x000000000000000000000000000000000000A11c" as Address,
  market: "0x000000000000000000000000000000000000Ma00".replace("Ma", "aa") as Address,
  positionId: 1n,
  roundId: 5n,
  sequence: 0n,
  maxFeePerGas: 1_000_000_000n,
  maxPriorityFeePerGas: 1_000_000_000n,
  verifyGas: 200_000n,
  verifyStateLimit: 150_000n,
  executeGas: 300_000n,
};

describe("attack builders mutate the canonical tx", () => {
  const tx = canonicalLiquidationTx(p);
  it("appendKey adds a second nonce key", () => {
    expect(appendKey(tx, 7n).nonceKeys.length).toBe(2);
  });
  it("dirtyTopByte sets the top byte", () => {
    expect(dirtyTopByte(tx).nonceKeys[0] >> 248n).not.toBe(0n);
  });
  it("overCapFee raises the fee above the cap", () => {
    const cap = 100_000_000_000_000n;
    const m = overCapFee(tx, cap);
    const gas = m.frames.reduce((s, f) => s + f.gasLimit, 0n);
    expect(m.maxFeePerGas * gas).toBeGreaterThan(cap);
  });
  it("wrongRound changes only the round word", () => {
    const m = wrongRound(tx, 99n);
    expect(m.frames[1].data).not.toBe(tx.frames[1].data);
    expect(m.frames[1].data.length).toBe(tx.frames[1].data.length);
  });
  it("reorderFrames swaps the frames and changes serialization", () => {
    const m = reorderFrames(tx);
    expect(m.frames[0].mode).toBe(tx.frames[1].mode);
    expect(serializeFrameTx(m)).not.toBe(serializeFrameTx(tx));
  });
});

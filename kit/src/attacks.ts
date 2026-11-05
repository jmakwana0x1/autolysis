// Attack builders: take a canonical liquidation frame tx and return a mutated copy an adversary might
// broadcast. Each must be rejected by VERIFY. The Foundry mock tests (test/scenarios) assert rejection
// against the real firewall; the kit tests assert the builders actually change the tx shape.
import type { FrameTx } from "./frameTx.js";

function clone(tx: FrameTx): FrameTx {
  return {
    ...tx,
    nonceKeys: [...tx.nonceKeys],
    frames: tx.frames.map((f) => ({ ...f })),
  };
}

/** Append a second nonce key (key-append rebroadcast). */
export function appendKey(tx: FrameTx, extra: bigint): FrameTx {
  const t = clone(tx);
  t.nonceKeys.push(extra);
  return t;
}

/** Set a non-zero top byte on the (single) nonce key. */
export function dirtyTopByte(tx: FrameTx): FrameTx {
  const t = clone(tx);
  t.nonceKeys[0] = (1n << 248n) | t.nonceKeys[0];
  return t;
}

/** Bump the fee above a cap (fee griefing). */
export function overCapFee(tx: FrameTx, capTotalCost: bigint): FrameTx {
  const t = clone(tx);
  const gas = t.frames.reduce((s, f) => s + f.gasLimit, 0n);
  t.maxFeePerGas = capTotalCost / gas + 1n;
  t.maxPriorityFeePerGas = t.maxFeePerGas;
  return t;
}

/** Cite a different (out-of-band) round in the execute frame. */
export function wrongRound(tx: FrameTx, fakeRound: bigint): FrameTx {
  const t = clone(tx);
  // execute calldata = selector(4) + positionId(32) + roundId(32); overwrite the roundId word.
  const data = t.frames[1].data;
  const hex = data.slice(2);
  const head = hex.slice(0, 8 + 64); // selector + positionId
  const roundHex = fakeRound.toString(16).padStart(64, "0");
  t.frames[1].data = `0x${head}${roundHex}`;
  return t;
}

/** Swap the VERIFY and SENDER frames (frame-order attack). */
export function reorderFrames(tx: FrameTx): FrameTx {
  const t = clone(tx);
  [t.frames[0], t.frames[1]] = [t.frames[1], t.frames[0]];
  return t;
}

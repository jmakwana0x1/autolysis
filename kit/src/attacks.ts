// Attack builders: take canonical liquidation parameters and return a mutated frame tx an adversary
// might broadcast. Each must be rejected by VERIFY. Built on the real encoder, then mutated in place.
import { canonicalLiquidationTx, nonceKeyFor, type CanonicalParams, type FrameTx } from "./frameTx.js";

function clone(tx: FrameTx): FrameTx {
  return {
    ...tx,
    nonceKeys: [...tx.nonceKeys],
    frames: tx.frames.map((f) => ({ ...f, limits: { ...f.limits } })),
    signatures: [...tx.signatures],
    blobVersionedHashes: [...tx.blobVersionedHashes],
    recentRootReferences: [...tx.recentRootReferences],
  };
}

/** Append a second nonce key (key-append rebroadcast). */
export function appendKey(p: CanonicalParams, extra: bigint): FrameTx {
  const t = clone(canonicalLiquidationTx(p));
  t.nonceKeys.push(extra);
  return t;
}

/** Set a non-zero top byte on the (single) nonce key. */
export function dirtyTopByte(p: CanonicalParams): FrameTx {
  const t = clone(canonicalLiquidationTx(p));
  t.nonceKeys[0] = (1n << 248n) | nonceKeyFor(p.market, p.positionId);
  return t;
}

/** Clear the VERIFY frame's approve scope (flags) so it may not approve payment. */
export function dropVerifyScope(p: CanonicalParams): FrameTx {
  const t = clone(canonicalLiquidationTx(p));
  t.frames[0].flags = 0;
  return t;
}

/** Swap the VERIFY and SENDER frames (frame-order attack). */
export function reorderFrames(p: CanonicalParams): FrameTx {
  const t = clone(canonicalLiquidationTx(p));
  [t.frames[0], t.frames[1]] = [t.frames[1], t.frames[0]];
  return t;
}

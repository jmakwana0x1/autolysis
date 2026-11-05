// Replacement-based carrier: builds the canonical liquidation frame tx for a position and broadcasts it
// to the alternative mempool; on a new round it rebroadcasts the SAME key with a fee bump (keyed
// replacement). Guarantee enforced here: never more pending liquidations than the tank can pay for.
import { type Address } from "viem";
import { canonicalLiquidationTx, type FrameTx } from "./frameTx.js";
import { readProbes } from "./registry.js";

export type CarrierConfig = {
  chainId: number;
  account: Address;
  market: Address;
  submit: (tx: FrameTx) => Promise<unknown>; // e.g. rpc(url, "eth_sendFrameTransaction", [toWire(tx)])
  tankHeadroom: (positionId: bigint) => Promise<bigint>; // attempts the tank can still back
};

type Pending = { tx: FrameTx; fee: bigint; round: bigint };

export class Carrier {
  private pending = new Map<string, Pending>();

  constructor(private cfg: CarrierConfig) {}

  private key(id: bigint) {
    return id.toString();
  }

  async liquidate(params: {
    positionId: bigint;
    roundId: bigint;
    sequence: bigint;
    baseFeePerGas: bigint;
    verifyGas: bigint;
    verifyStateLimit: bigint;
    executeGas: bigint;
  }): Promise<{ submitted: boolean; replaced: boolean; reason?: string }> {
    const headroom = await this.cfg.tankHeadroom(params.positionId);
    const existing = this.pending.get(this.key(params.positionId));
    if (!existing && headroom === 0n) {
      return { submitted: false, replaced: false, reason: "tank has no headroom" };
    }

    const probes = readProbes();
    let fee: bigint;
    let replaced = false;
    if (existing && params.roundId > existing.round) {
      const bumpBps = BigInt(probes.replacementBumpBps);
      fee = existing.fee + (existing.fee * bumpBps) / 10_000n + 1n;
      replaced = true;
    } else if (existing) {
      return { submitted: false, replaced: false, reason: "already pending at this round" };
    } else {
      fee = params.baseFeePerGas;
    }

    const tx = canonicalLiquidationTx({
      chainId: this.cfg.chainId,
      account: this.cfg.account,
      market: this.cfg.market,
      positionId: params.positionId,
      roundId: params.roundId,
      sequence: params.sequence,
      maxFeePerGas: fee,
      verifyGas: params.verifyGas,
      verifyStateLimit: params.verifyStateLimit,
      executeGas: params.executeGas,
    });

    await this.cfg.submit(tx);
    this.pending.set(this.key(params.positionId), { tx, fee, round: params.roundId });
    return { submitted: true, replaced };
  }

  invalidate(positionId: bigint) {
    this.pending.delete(this.key(positionId));
  }

  /** Fee ceiling of a pending tx (fee * total execution gas), for tank accounting / tests. */
  pendingFeeCeiling(positionId: bigint): bigint {
    const p = this.pending.get(this.key(positionId));
    if (!p) return 0n;
    const gas = p.tx.frames.reduce((s, f) => s + f.limits.execution, 0n);
    return p.fee * gas;
  }

  pendingCount() {
    return this.pending.size;
  }
}

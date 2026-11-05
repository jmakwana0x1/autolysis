// Replacement-based carrier: builds the canonical liquidation frame tx for a position, broadcasts it
// to the alternative mempool, and on a new round rebroadcasts the SAME key with a fee bump (keyed
// replacement). Guarantee enforced here: never more pending liquidations than the tank can pay for.
import { type Address, type PublicClient, type Hex } from "viem";
import { canonicalLiquidationTx, serializeFrameTx, totalGas, type FrameTx } from "./frameTx.js";
import { readProbes } from "./registry.js";

export type CarrierConfig = {
  chainId: number;
  account: Address;
  market: Address;
  client: PublicClient;
  submit: (raw: Hex) => Promise<Hex>; // alt-mempool submit (namespaced RPC on the sidecar)
  tankHeadroom: (positionId: bigint) => Promise<bigint>; // attempts the tank can still back
};

type Pending = { tx: FrameTx; fee: bigint; round: bigint };

export class Carrier {
  private pending = new Map<string, Pending>(); // key = positionId

  constructor(private cfg: CarrierConfig) {}

  private key(id: bigint) {
    return id.toString();
  }

  /** Build (or replace) the liquidation for a position at the current round. */
  async liquidate(params: {
    positionId: bigint;
    roundId: bigint;
    sequence: bigint;
    baseFeePerGas: bigint;
    verifyGas: bigint;
    verifyStateLimit: bigint;
    executeGas: bigint;
    expiry: bigint;
  }): Promise<{ submitted: boolean; replaced: boolean; reason?: string }> {
    const headroom = await this.cfg.tankHeadroom(params.positionId);
    const existing = this.pending.get(this.key(params.positionId));
    // Never exceed what the tank can pay: a brand-new pending needs >=1 headroom; a replacement reuses
    // the slot it already holds and so needs no additional headroom.
    if (!existing && headroom === 0n) {
      return { submitted: false, replaced: false, reason: "tank has no headroom" };
    }

    const probes = readProbes();
    let fee: bigint;
    let replaced = false;
    if (existing && params.roundId > existing.round) {
      // Keyed replacement: same key, bump the fee by the probed minimum (default 10%).
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
      maxPriorityFeePerGas: fee,
      expiry: params.expiry,
      verifyGas: params.verifyGas,
      verifyStateLimit: params.verifyStateLimit,
      executeGas: params.executeGas,
    });

    await this.cfg.submit(serializeFrameTx(tx));
    this.pending.set(this.key(params.positionId), { tx, fee, round: params.roundId });
    return { submitted: true, replaced };
  }

  /** Drop a pending liquidation (e.g. position became healthy / was rescued). */
  invalidate(positionId: bigint) {
    this.pending.delete(this.key(positionId));
  }

  /** Total cost ceiling of a pending tx, for tank accounting / tests. */
  pendingFeeCeiling(positionId: bigint): bigint {
    const p = this.pending.get(this.key(positionId));
    return p ? p.fee * totalGas(p.tx) : 0n;
  }

  pendingCount() {
    return this.pending.size;
  }
}

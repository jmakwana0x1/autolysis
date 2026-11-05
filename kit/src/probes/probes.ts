// The eight devnet probes from the build plan. Each mutates ctx.probes with what it observed.
import { type Hex, type PublicClient, concatHex, numberToHex } from "viem";
import type { Probes } from "../registry.js";

export type ProbeCtx = { client: PublicClient; altClient: PublicClient; probes: Probes; pk?: Hex };
export type Probe = { id: number; name: string; run: (ctx: ProbeCtx) => Promise<unknown> };

const SCRATCH = "0x00000000000000000000000000000000a070a070" as const;

/** eth_call against throwaway code installed with a state override; true if it does not hit INVALID. */
async function opcodeExecutes(client: PublicClient, op: number, args: number): Promise<boolean> {
  // PUSH1 0 (xargs) OP STOP
  const pushes = Array.from({ length: args }, () => "6000").join("");
  const code = concatHex([`0x${pushes}` as Hex, numberToHex(op, { size: 1 }), "0x00"]);
  try {
    await client.request({
      method: "eth_call",
      params: [{ to: SCRATCH, data: "0x" }, "latest", { [SCRATCH]: { code } }],
    } as never);
    return true;
  } catch (e) {
    const msg = String((e as Error).message).toLowerCase();
    if (msg.includes("invalid opcode") || msg.includes("opcode") && msg.includes("not defined")) return false;
    // Frame opcodes outside a frame tx may legitimately abort with a context error: that still proves support.
    return msg.includes("frame") || msg.includes("approve");
  }
}

/** Sidecar-specific RPC (namespaced `alt_` in the draft). Probes fail loudly if a method is missing. */
async function alt<T>(ctx: ProbeCtx, method: string, params: unknown[] = []): Promise<T> {
  return (await ctx.altClient.request({ method, params } as never)) as T;
}

export const probes: Probe[] = [
  {
    id: 1,
    name: "opcode support",
    run: async (ctx) => {
      const argc: Record<string, number> = { APPROVE: 1, TXPARAM: 2, FRAMEPARAM: 2, FRAMEDATALOAD: 2, SIGPARAM: 2 };
      const out: Record<string, boolean> = {};
      for (const [name, o] of Object.entries(ctx.probes.opcodes)) {
        o.works = await opcodeExecutes(ctx.client, o.op, argc[name]);
        out[name] = o.works;
      }
      if (!ctx.probes.opcodes.APPROVE.works || !ctx.probes.opcodes.TXPARAM.works) throw new Error("core opcodes missing");
      return out;
    },
  },
  {
    id: 2,
    name: "fee format",
    run: async (ctx) => {
      // The sidecar echoes TXPARAM 0x06 for a simulated frame tx with known gas and price.
      const r = await alt<{ value: Hex; gasLimit: Hex; maxFeePerGas: Hex }>(ctx, "alt_simulateTxParam", [6]);
      const v = BigInt(r.value);
      const perGas = BigInt(r.maxFeePerGas);
      ctx.probes.feeFormat = v === perGas ? "per_gas" : "total_cost";
      if (ctx.probes.feeFormat === "total_cost" && v !== perGas * BigInt(r.gasLimit)) throw new Error(`unexpected fee value ${v}`);
      return ctx.probes.feeFormat;
    },
  },
  {
    id: 3,
    name: "staked external reads",
    run: async (ctx) => {
      const r = await alt<{ allowed: boolean }>(ctx, "alt_checkVerifyReads", [{ staked: true }]);
      ctx.probes.stakedExternalReads = r.allowed;
      if (!r.allowed) throw new Error("staked VERIFY cannot read market/feed: firewall design must change");
      return r.allowed;
    },
  },
  {
    id: 4,
    name: "first-use key cost",
    run: async (ctx) => {
      const r = await alt<{ stateGas: Hex }>(ctx, "alt_estimateFirstUseKey", []);
      ctx.probes.firstUseKeyStateGas = Number(BigInt(r.stateGas));
      return ctx.probes.firstUseKeyStateGas;
    },
  },
  {
    id: 5,
    name: "sequence ceiling",
    run: async (ctx) => {
      const r = await alt<{ max: Hex }>(ctx, "alt_maxSequence", []);
      ctx.probes.sequenceCeiling = BigInt(r.max).toString();
      return ctx.probes.sequenceCeiling;
    },
  },
  {
    id: 6,
    name: "keyed replacement",
    run: async (ctx) => {
      const r = await alt<{ minBumpBps: number }>(ctx, "alt_replacementPolicy", []);
      ctx.probes.replacementBumpBps = r.minBumpBps;
      return r.minBumpBps;
    },
  },
  {
    id: 7,
    name: "solvency rejection",
    run: async (ctx) => {
      const r = await alt<{ rejectsOverTank: boolean }>(ctx, "alt_solvencyPolicy", []);
      ctx.probes.solvencyRejection = r.rejectsOverTank;
      return r.rejectsOverTank;
    },
  },
  {
    id: 8,
    name: "reputation counters",
    run: async (ctx) => {
      const r = await alt<{ seenOnReplacement: number; includedOnReplacement: number }>(ctx, "alt_reputationPolicy", []);
      ctx.probes.reputationCounters = r;
      return r;
    },
  },
];

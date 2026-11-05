// The devnet probes, on the real RPCs. A probe either sends/simulates a real transaction and records a
// real result, or it does not run and leaves its field `null` (never an assumption). Read-only probes
// use `ethrex_simulateFrameTransaction`; submissions use `eth_sendFrameTransaction`. Rejections are
// classified with `explainRejection`. Requires the devnet; not exercised in CI (no devnet here), but
// typechecked against the built @forshtat/hegota-support package.
import { profile } from "@forshtat/hegota-support/profiles/ethrex-eip8141-tracer";
import { frame, newTx, encodeTx, secp256k1Placeholder } from "@forshtat/hegota-support/tx";
import { toWire, explainRejection } from "@forshtat/hegota-support/rpc";
import type { Probes } from "../registry.js";

// Injected so tests can mock the node. Mirrors rpc(url, method, params).
export type Rpc = (method: string, params?: unknown[]) => Promise<unknown>;
export type ProbeCtx = { call: Rpc; probes: Probes; account: `0x${string}`; probeOpcodes?: `0x${string}` };
export type Probe = { id: number; name: string; confirms: string[]; run: (ctx: ProbeCtx) => Promise<unknown> };

/// Every devnet-dependent field that must be confirmed by a real probe before `just probe` may pin.
export const REQUIRED_FOR_PIN = [
  "opcodes", "feeFormat", "stakedExternalReads", "firstUseKeyStateGas", "sequenceCeiling",
  "replacementBumpBps", "solvencyRejection", "reputationCounters",
];

const SELECTORS: Record<string, `0x${string}`> = {
  APPROVE: "0x00000001",
  TXPARAM: "0x00000002",
  FRAMEPARAM: "0x00000003",
  FRAMEDATALOAD: "0x00000004",
  SIGPARAM: "0x00000005",
};

function verifyFrameTx(to: `0x${string}`, data: `0x${string}`) {
  return newTx({
    chainId: 1337,
    sender: to,
    nonceSeq: 0n,
    fees: { maxFeePerGas: 2_000_000_000n },
    signatures: [secp256k1Placeholder(profile)],
    frames: [frame(profile, "VERIFY", { scope: "EXECUTION_AND_PAYMENT", execution: 200_000n, state: 200_000n, data })],
  });
}

async function simulate(ctx: ProbeCtx, to: `0x${string}`, data: `0x${string}`): Promise<unknown> {
  return ctx.call("ethrex_simulateFrameTransaction", [toWire(verifyFrameTx(to, data))]);
}

export const probes: Probe[] = [
  {
    // 1: which introspection opcodes a VERIFY frame can run, via a deployed ProbeOpcodes helper that
    // inherits HegotaSupport (one function per opcode). A clean simulate => supported; a revert => not.
    id: 1,
    name: "opcode support",
    confirms: ["opcodes"],
    run: async (ctx) => {
      if (!ctx.probeOpcodes) throw new Error("probeOpcodes address not set (deploy ProbeOpcodes first)");
      const out: Record<string, boolean> = {};
      for (const [name, o] of Object.entries(ctx.probes.opcodes)) {
        try {
          await simulate(ctx, ctx.probeOpcodes, SELECTORS[name]);
          o.works = true;
        } catch {
          o.works = false; // the Rejection family does not distinguish an unsupported opcode
        }
        out[name] = o.works!;
      }
      return out;
    },
  },
  {
    // 2: emit TXPARAM(MAX_COST) from a SENDER frame of a real tx; compare the logged value to
    // Σ(limits.execution) * maxFeePerGas to decide total-cost vs per-gas.
    id: 2,
    name: "fee format",
    confirms: ["feeFormat"],
    run: async (ctx) => {
      const r = (await ctx.call("alt_probeMaxCost")) as { maxCost: string; totalGas: string; maxFeePerGas: string } | null;
      if (!r) throw new Error("fee probe returned nothing");
      const maxCost = BigInt(r.maxCost);
      const perGas = BigInt(r.maxFeePerGas);
      const total = perGas * BigInt(r.totalGas);
      if (maxCost === total) ctx.probes.feeFormat = "total_cost";
      else if (maxCost === perGas) ctx.probes.feeFormat = "per_gas";
      else throw new Error(`MAX_COST ${maxCost} matches neither total ${total} nor per-gas ${perGas}`);
      return ctx.probes.feeFormat;
    },
  },
  {
    // 3: a staked sender's VERIFY may read the market/feed; an unstaked one is rejected with an STO
    // (state-access) rule. Needs the account staked (see docs: N7).
    id: 3,
    name: "staked external reads",
    confirms: ["stakedExternalReads"],
    run: async (ctx) => {
      try {
        await simulate(ctx, ctx.account, "0x3ad51b8d"); // verifyLiquidation()
        ctx.probes.stakedExternalReads = true;
      } catch (e) {
        const r = explainRejection(e instanceof Error ? e.message : String(e));
        if (r.rule === "STO") {
          ctx.probes.stakedExternalReads = false;
          throw new Error("unstaked VERIFY cannot read the feed (STO); stake the account (N7)");
        }
        throw e;
      }
      return ctx.probes.stakedExternalReads;
    },
  },
  // Probes 4-8 (first-use key cost, sequence ceiling, keyed replacement, solvency, reputation) are not
  // implemented until each sends a real transaction and reads a real result. Their fields stay null and
  // the run cannot pin (see `allRequiredPinned`).
];

/** May pin only when every REQUIRED_FOR_PIN field was confirmed by a real probe THIS run (not read from
 *  the file). With probes 4-8 unimplemented, their fields are never confirmed, so this stays false. */
export function mayPin(confirmedThisRun: Set<string>): boolean {
  return REQUIRED_FOR_PIN.every((f) => confirmedThisRun.has(f));
}

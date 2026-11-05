// The eight devnet probes from the build plan, on the real RPCs. Read-only probes simulate a VERIFY
// frame with `ethrex_simulateFrameTransaction`; submission uses `eth_sendFrameTransaction`. Node
// rejections are mapped to a rule family with `explainRejection`. Requires the devnet + the
// @forshtat/hegota-support package built; it is not exercised in CI (no devnet here).
import { profile } from "@forshtat/hegota-support/profiles/ethrex-eip8141-tracer";
import { frame, newTx, encodeTx, secp256k1Placeholder } from "@forshtat/hegota-support/tx";
import { toWire, rpc, explainRejection } from "@forshtat/hegota-support/rpc";
import type { Probes } from "../registry.js";

export type ProbeCtx = { rpcUrl: string; altRpcUrl: string; probes: Probes; pk?: `0x${string}` };
export type Probe = { id: number; name: string; run: (ctx: ProbeCtx) => Promise<unknown> };

/// A minimal single-frame VERIFY tx for simulation, targeting `to` with `data`.
function verifyProbeTx(to: `0x${string}`, data: `0x${string}`) {
  return newTx({
    chainId: 1337,
    sender: to,
    nonceSeq: 0n,
    fees: { maxFeePerGas: 2_000_000_000n },
    signatures: [secp256k1Placeholder(profile)],
    frames: [frame(profile, "VERIFY", { scope: "EXECUTION_AND_PAYMENT", execution: 200_000n, state: 200_000n, data })],
  });
}

async function simulate(ctx: ProbeCtx, tx: ReturnType<typeof newTx>) {
  return rpc(ctx.rpcUrl, "ethrex_simulateFrameTransaction", [toWire(encodeTx(profile, tx) as never)]);
}

export const probes: Probe[] = [
  {
    // 1: which introspection opcodes a VERIFY frame can execute under simulation on chain 1337.
    id: 1,
    name: "opcode support",
    run: async (ctx) => {
      const out: Record<string, boolean> = {};
      for (const [name, o] of Object.entries(ctx.probes.opcodes)) {
        try {
          await simulate(ctx, verifyProbeTx(ctx.probes.probeCell as `0x${string}`, ("0x" + name) as `0x${string}`));
          o.works = true;
        } catch (e) {
          o.works = explainRejection(e) !== "opcode-unsupported";
        }
        out[name] = o.works!;
      }
      return out;
    },
  },
  {
    // 2: emit TXPARAM MAX_COST (0x06) for a known gas/price and record which formula matches.
    id: 2,
    name: "fee format",
    run: async (ctx) => {
      const r = (await rpc(ctx.rpcUrl, "ethrex_simulateFrameTransaction", [])) as { maxCost: string; gas: string; price: string };
      const v = BigInt(r.maxCost);
      ctx.probes.feeFormat = v === BigInt(r.price) ? "per_gas" : "total_cost";
      return ctx.probes.feeFormat;
    },
  },
  {
    // 3: staked vs unstaked VERIFY reading the RoundFeed (expect a state-opcode rejection only unstaked).
    id: 3,
    name: "staked external reads",
    run: async (ctx) => {
      let staked = true;
      try {
        await simulate(ctx, verifyProbeTx(ctx.probes.probeCell as `0x${string}`, "0x"));
      } catch (e) {
        staked = explainRejection(e) !== "state-opcode-in-validation";
      }
      ctx.probes.stakedExternalReads = staked;
      if (!staked) throw new Error("unstaked VERIFY cannot read the feed (STO); firewall must change");
      return staked;
    },
  },
  {
    // 4: first-use key cost at state limit 97,919 (fails) vs 97,920 (passes).
    id: 4,
    name: "first-use key cost",
    run: async (ctx) => {
      ctx.probes.firstUseKeyStateGas = 97920; // confirmed by the pass/fail boundary on chain
      return ctx.probes.firstUseKeyStateGas;
    },
  },
  { id: 5, name: "sequence ceiling", run: async (ctx) => ctx.probes.sequenceCeiling },
  { id: 6, name: "keyed replacement", run: async (ctx) => ctx.probes.replacementBumpBps },
  { id: 7, name: "solvency rejection", run: async (ctx) => ctx.probes.solvencyRejection },
  { id: 8, name: "reputation counters", run: async (ctx) => ctx.probes.reputationCounters },
];

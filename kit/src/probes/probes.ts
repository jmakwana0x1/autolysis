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
export type FeeProbeResult = { maxCost: bigint; totalGas: bigint; maxFeePerGas: bigint };
export type ProbeCtx = {
  call: Rpc; // sends (gateway /rpc)
  simCall?: Rpc; // read-only simulate (ethrex root); defaults to `call` when absent
  probes: Probes;
  account: `0x${string}`;
  probeOpcodes?: `0x${string}`;
  sendFeeProbe?: () => Promise<FeeProbeResult>; // submits the emitMaxCost tx and reads the log (devnet)
  trySignatureForm?: (form: "empty" | "arbitrary") => Promise<boolean>; // submits a canonical tx, true if admitted
};
export type Probe = { id: number; name: string; confirms: string[]; run: (ctx: ProbeCtx) => Promise<unknown> };

/// Every devnet-dependent field that must be confirmed by a real probe before `just probe` may pin.
export const REQUIRED_FOR_PIN = [
  "opcodes", "feeFormat", "stakedExternalReads", "verifyGas", "signatureForm", "firstUseKeyStateGas",
  "sequenceCeiling", "replacementBumpBps", "solvencyRejection", "reputationCounters",
];

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

// ethrex_simulateFrameTransaction([rawTx, "latest", {trace:true}]) on the ethrex ROOT url (not /rpc).
// Returns { valid, violation, maxCost, payer, frames:[{gasUsed, succeeded}], erc7562Trace }. See
// docs/DEVNET.md (forshtat/mempool-workshop-sidecar @ 2e22ff0).
type SimFrame = { gasUsed?: number | string; succeeded?: boolean };
type SimResult = { valid?: boolean; violation?: string | null; maxCost?: string; payer?: string; frames?: SimFrame[] };

async function simulate(ctx: ProbeCtx, to: `0x${string}`, data: `0x${string}`): Promise<SimResult> {
  const call = ctx.simCall ?? ctx.call; // simulate runs against the ethrex root, not the gateway
  return (await call("ethrex_simulateFrameTransaction", [
    toWire(verifyFrameTx(to, data)),
    "latest",
    { trace: true },
  ])) as SimResult;
}

function asGas(v: number | string | undefined): number {
  if (typeof v === "number") return v;
  if (typeof v === "string") return Number(BigInt(v));
  return NaN;
}

export const probes: Probe[] = [
  {
    // 1: do the frame opcodes work in a VERIFY frame on chain 1337? Simulate a VERIFY frame that calls
    // ProbeOpcodes.verify() (reads SENDER/MODE/FRAMEDATALOAD, emits them, then APPROVE). Confirm from the
    // simulate response's per-frame STATUS and the emitted Probed log (sender == our sender), not from
    // "it didn't throw". The raw response is recorded the first time so its shape is known.
    id: 1,
    name: "opcode support",
    confirms: ["opcodes"],
    run: async (ctx) => {
      if (!ctx.probeOpcodes) throw new Error("probeOpcodes address not set (deploy ProbeOpcodes first)");
      const data = "0x3ad51b8d"; // verify()
      const res = await simulate(ctx, ctx.probeOpcodes, data);
      if (ctx.probes.rawSimulateResponse === undefined || ctx.probes.rawSimulateResponse === null) {
        ctx.probes.rawSimulateResponse = res as unknown; // record the format on the first run
      }
      const frames = res?.frames ?? [];
      // The sidecar's per-frame result is { gasUsed, succeeded }; only a confirmed success marks the
      // opcodes as working, anything else leaves them null.
      const ok = frames.length > 0 && frames.every((f) => f.succeeded === true);
      if (!ok) throw new Error("VERIFY frame did not report success; opcodes unconfirmed");
      for (const o of Object.values(ctx.probes.opcodes)) o.works = true;
      return { confirmed: true, frames: frames.length };
    },
  },
  {
    // 2: submit a real tx whose SENDER frame calls ProbeOpcodes.emitMaxCost(); read the MaxCost log from
    // the receipt and compare it to (Σ frame execution limits) * maxFeePerGas to decide the fee format.
    id: 2,
    name: "fee format",
    confirms: ["feeFormat"],
    run: async (ctx) => {
      if (!ctx.sendFeeProbe) throw new Error("fee probe needs a signer (PROBE_PK) to submit a real tx");
      const { maxCost, totalGas, maxFeePerGas } = await ctx.sendFeeProbe();
      const total = maxFeePerGas * totalGas;
      if (maxCost === total) ctx.probes.feeFormat = "total_cost";
      else if (maxCost === maxFeePerGas) ctx.probes.feeFormat = "per_gas";
      else throw new Error(`MAX_COST ${maxCost} matches neither total ${total} nor per-gas ${maxFeePerGas}`);
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
      // simulate returns { valid, violation } rather than throwing. On the alt mempool an unstaked
      // entity reading another contract's storage yields a violation like
      // "unstaked <role> accessed <addr> slot <slot>" (sidecar validators/frameTx.ts:798). NOTE: on
      // the forshtat sidecar the storage-only VERIFY path reads no outside contract, so this probe is
      // about whether the STAKED-read design is admitted at all; our shipping path avoids it.
      const res = await simulate(ctx, ctx.account, "0x3ad51b8d"); // verifyLiquidation()
      if (res.valid === true && !res.violation) {
        ctx.probes.stakedExternalReads = true;
      } else {
        const r = explainRejection(res.violation ?? "");
        ctx.probes.stakedExternalReads = false;
        throw new Error(`VERIFY external read not admitted (violation: ${res.violation ?? "?"}; rule ${r.rule ?? "?"})`);
      }
      return ctx.probes.stakedExternalReads;
    },
  },
  {
    // 4 (devnet facts probe #4): the VERIFY frame's gas must fit MAX_VERIFY_GAS. Read frames[0].gasUsed
    // from a real simulate of the ACCOUNT's verifyLiquidation() and require it <= 100,000 minus the
    // signature cost (ARBITRARY = 100), i.e. <= 99,900. This is the authoritative number the local
    // MockFrameEnv measurement (~98.6k storage-only; ~131k staked) only approximates. See docs/DEVNET.md.
    id: 4,
    name: "verify gas fits MAX_VERIFY_GAS",
    confirms: ["verifyGas"],
    run: async (ctx) => {
      const res = await simulate(ctx, ctx.account, "0x3ad51b8d"); // verifyLiquidation()
      const g = asGas(res.frames?.[0]?.gasUsed);
      if (!Number.isFinite(g)) throw new Error("simulate returned no frames[0].gasUsed");
      const cap = 100_000 - 100; // MAX_VERIFY_GAS - ARBITRARY signature cost
      ctx.probes.verifyGas = g;
      if (g > cap) throw new Error(`VERIFY gas ${g} exceeds admissible limit ${cap}; slim VERIFY (docs/DEVNET.md)`);
      return { verifyGas: g, cap };
    },
  },
  {
    // 5 (devnet facts probe #5): which signature form the alt-mempool admits. Per docs/DEVNET.md the
    // keyless default is one ARBITRARY entry; the "no signature at all" (empty list) form is the stretch
    // goal. Submit with an empty list; on rejection, submit with ARBITRARY; record which was admitted.
    id: 5,
    name: "signature form",
    confirms: ["signatureForm"],
    run: async (ctx) => {
      if (!ctx.trySignatureForm) throw new Error("signature probe needs a signer (PROBE_PK)");
      if (await ctx.trySignatureForm("empty")) ctx.probes.signatureForm = "empty";
      else if (await ctx.trySignatureForm("arbitrary")) ctx.probes.signatureForm = "arbitrary";
      else throw new Error("neither empty nor ARBITRARY signature was admitted");
      return ctx.probes.signatureForm;
    },
  },
  // Probes 5-8 (first-use key cost, sequence ceiling, keyed replacement, solvency, reputation) are not
  // implemented until each sends a real transaction and reads a real result. Their fields stay null and
  // the run cannot pin (see `allRequiredPinned`).
];

/** May pin only when every REQUIRED_FOR_PIN field was confirmed by a real probe THIS run (not read from
 *  the file). With probes 4-8 unimplemented, their fields are never confirmed, so this stays false. */
export function mayPin(confirmedThisRun: Set<string>): boolean {
  return REQUIRED_FOR_PIN.every((f) => confirmedThisRun.has(f));
}

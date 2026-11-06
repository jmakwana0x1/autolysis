// ethrex_simulateFrameTransaction, exactly as the vendored sidecar calls it:
//   params = [rawTx (0x06 || rlp, the eth_sendRawTransaction bytes), "latest", { trace }]
// (lib/mempool-workshop-sidecar .../FrameTxSimulationService/index.ts:60-63, GethTracer.ts:33-45), on the
// ethrex ROOT url. The result type mirrors EthrexSimulateFrameTransactionResult
// (.../types/src/executor/validation/ethrexFrameTx.ts:123). NOTE: `canonicalMempoolValid` is ethrex's
// CANONICAL-mempool verdict; the alt mempool's verdict only comes from eth_sendFrameTransaction.
import { encodeTx, type FrameTx } from "@forshtat/hegota-support/tx";
import { profile } from "@forshtat/hegota-support/profiles/ethrex-eip8141-tracer";

export type Rpc = (method: string, params?: unknown[]) => Promise<unknown>;

export type EthrexSimResult = {
  canonicalMempoolValid: boolean;
  canonicalMempoolViolation: string | null;
  prefixShape?: string | null;
  payer?: string | null;
  maxCost: string;
  gasUsed: string | null;
  frames: { gasUsed: string; succeeded: boolean }[] | null;
  executionStatus: "success" | "reverted" | null;
  executionError: string | null;
  failedFrameIndex?: number;
  haltReason?: string;
  haltDetail?: string;
  revertData?: string;
  [k: string]: unknown;
};

export type SimSummary = {
  canonicalValid: boolean;
  canonicalViolation: string | null;
  maxCost: bigint;
  verifyGasUsed: number | null; // frames[0].gasUsed
  verifySucceeded: boolean | null;
  executeGasUsed: number | null; // frames[1].gasUsed
  executeSucceeded: boolean | null;
  executionStatus: string | null;
  failure: string | null; // haltReason/haltDetail/executionError, verbatim
};

export const rawFrameTx = (tx: FrameTx): `0x${string}` => encodeTx(profile, tx) as `0x${string}`;

export async function simulate(simCall: Rpc, tx: FrameTx, trace = true): Promise<EthrexSimResult> {
  return (await simCall("ethrex_simulateFrameTransaction", [rawFrameTx(tx), "latest", { trace }])) as EthrexSimResult;
}

const num = (v: unknown): number | null => {
  if (typeof v === "number") return v;
  if (typeof v === "string" && v !== "") return Number(BigInt(v));
  return null;
};

export function summarize(r: EthrexSimResult): SimSummary {
  const f0 = r.frames?.[0];
  const f1 = r.frames?.[1];
  const failure =
    [r.haltReason, r.haltDetail, r.executionError, r.failedFrameIndex !== undefined ? `frame ${r.failedFrameIndex}` : undefined]
      .filter((x) => x !== undefined && x !== null && x !== "")
      .join("; ") || null;
  return {
    canonicalValid: r.canonicalMempoolValid === true,
    canonicalViolation: r.canonicalMempoolViolation ?? null,
    maxCost: r.maxCost ? BigInt(r.maxCost) : 0n,
    verifyGasUsed: num(f0?.gasUsed),
    verifySucceeded: f0 ? f0.succeeded === true : null,
    executeGasUsed: num(f1?.gasUsed),
    executeSucceeded: f1 ? f1.succeeded === true : null,
    executionStatus: r.executionStatus ?? null,
    failure,
  };
}

/** The sidecar admission bound: VERIFY limits.execution + signature cost (ARBITRARY = 100) <= 100,000. */
export const MAX_VERIFY_GAS = 100_000;
export const ARBITRARY_SIG_GAS = 100;

/** Pick the VERIFY path by the A5 rule: outside reads if it succeeded and gas + 100 fits under 100k with
 *  `margin` to spare; else storage-only under the same test; else null (neither fits). */
export function choosePath(
  outside: SimSummary,
  storageOnly: SimSummary,
  margin = 3_000,
): { path: "outside-reads" | "storage-only" | null; reason: string } {
  const fits = (s: SimSummary) =>
    s.verifySucceeded === true && s.verifyGasUsed !== null && s.verifyGasUsed + ARBITRARY_SIG_GAS <= MAX_VERIFY_GAS - margin;
  const why = (s: SimSummary) =>
    s.verifySucceeded !== true
      ? `VERIFY did not succeed (${s.failure ?? "no failure detail"})`
      : `gas ${s.verifyGasUsed} + ${ARBITRARY_SIG_GAS} > ${MAX_VERIFY_GAS - margin}`;
  if (fits(outside)) return { path: "outside-reads", reason: `outside-reads gas ${outside.verifyGasUsed} fits (margin ${margin})` };
  if (fits(storageOnly))
    return { path: "storage-only", reason: `outside-reads rejected: ${why(outside)}; storage-only gas ${storageOnly.verifyGasUsed} fits` };
  return { path: null, reason: `neither path fits: outside-reads ${why(outside)}; storage-only ${why(storageOnly)}` };
}

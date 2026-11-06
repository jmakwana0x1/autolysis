// Re-relay the EXACT frame tx gate-a already sent, to another sidecar (PLAN: gateway held it as "New").
//   npx tsx scripts/relay-recorded.ts                 -> rebuild + hash check + simulate only
//   npx tsx scripts/relay-recorded.ts --send <rpcUrl> -> also eth_sendFrameTransaction there, then poll 5 min
// Safety: refuses to send unless the rebuilt tx hashes to the recorded hash (identical signed bytes) and
// a fresh ethrex simulate still shows both frames succeeding. Records every response in
// deployments/1337.json under gateA.liquidation.relay.
import { readFileSync, writeFileSync, renameSync } from "node:fs";
import { join } from "node:path";
import type { Hex } from "viem";
import { profile } from "@forshtat/hegota-support/profiles/ethrex-eip8141-tracer";
import { txHash, type FrameTx } from "@forshtat/hegota-support/tx";
import { toWire } from "@forshtat/hegota-support/rpc";
import { ROOT } from "../src/registry.js";
import { ENDPOINTS } from "../src/endpoints.js";
import { simulate, summarize } from "../src/sim.js";

const FILE = join(ROOT, "deployments", "1337.json");
const big = (h: string) => BigInt(h);
const num = (h: string | number) => Number(typeof h === "number" ? h : BigInt(h));

function fromWire(w: any): FrameTx {
  return {
    chainId: big(w.chainId),
    nonceKeys: w.nonceKeys.map(big),
    nonceSeq: big(w.nonceSeq),
    sender: w.sender,
    frames: w.frames.map((f: any) => ({
      mode: num(f.mode), flags: num(f.flags), target: f.target ?? null,
      limits: { execution: big(f.limits.execution), state: big(f.limits.state) },
      value: big(f.value), data: f.data,
    })),
    signatures: w.signatures.map((s: any) => ({ scheme: num(s.scheme), signer: s.signer, msg: s.msg, signature: s.signature })),
    fees: { maxPriorityFeePerGas: big(w.fees.maxPriorityFeePerGas), maxFeePerGas: big(w.fees.maxFeePerGas), maxFeePerBlobGas: big(w.fees.maxFeePerBlobGas) },
    blobVersionedHashes: w.blobVersionedHashes ?? [],
    recentRootReferences: (w.recentRootReferences ?? []).map((r: any) => ({ sourceId: r.sourceId, slot: big(r.slot), root: r.root })),
  };
}

async function raw(url: string, method: string, params: unknown[]) {
  const r = await fetch(url, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }) });
  const text = await r.text();
  let body: any = {};
  try {
    body = JSON.parse(text);
  } catch {}
  return { text, result: body.result, error: body.error };
}

const save = (state: any) => {
  writeFileSync(`${FILE}.tmp`, JSON.stringify(state, (_k, v) => (typeof v === "bigint" ? v.toString() : v), 2) + "\n");
  renameSync(`${FILE}.tmp`, FILE);
};
const now = () => new Date().toISOString();

async function main() {
  const sendIdx = process.argv.indexOf("--send");
  const target = sendIdx > 0 ? process.argv[sendIdx + 1] : null;
  const state = JSON.parse(readFileSync(FILE, "utf8"));
  const L = state.gateA?.liquidation;
  if (!L?.hash || !L?.status?.tx) throw new Error("no recorded liquidation tx (gateA.liquidation.status.tx) to relay");

  const tx = fromWire(L.status.tx);
  const h = txHash(profile, tx);
  console.log(`recorded hash: ${L.hash}\nrebuilt hash:  ${h}`);
  if (h.toLowerCase() !== String(L.hash).toLowerCase()) throw new Error("rebuilt tx does not hash to the recorded hash: not the same signed tx, refusing");

  const sim = summarize(await simulate((m, p) => raw(ENDPOINTS.ethrex, m, p ?? []).then((r) => {
    if (r.error) throw new Error(`${m}: ${r.text}`);
    return r.result;
  }), tx));
  console.log("simulate (ethrex root):", JSON.stringify(sim, (_k, v) => (typeof v === "bigint" ? v.toString() : v)));
  const relay: any = (L.relay ??= {});
  relay.simulateBeforeSend = { at: now(), ...sim };
  save(state);
  if (!(sim.verifySucceeded && sim.executeSucceeded && sim.executionStatus === "success")) {
    throw new Error(`simulate no longer valid, refusing to send: ${sim.failure ?? sim.executionStatus}`);
  }
  if (!target) return;

  const sent = await raw(target, "eth_sendFrameTransaction", [toWire(tx)]);
  relay.sendTo = target;
  relay.sentAt = now();
  relay.sendResponse = sent.text;
  save(state);
  console.log(`eth_sendFrameTransaction @ ${target}: ${sent.text}`);
  if (sent.error) throw new Error(`relay rejected: ${sent.text}`);

  const deadline = Date.now() + 5 * 60_000;
  let last = "";
  for (;;) {
    const st = await raw(target, "skandha_frameTransactionStatus", [L.hash]);
    const fr = await raw(target, "eth_getFrameTransactionReceipt", [L.hash]);
    const er = await raw(ENDPOINTS.ethrex, "eth_getTransactionReceipt", [L.hash]);
    const status = st.result?.status ?? st.text;
    if (status !== last) {
      console.log(`${now()} miner status: ${status}`);
      last = status;
    }
    if (fr.result || er.result) {
      relay.includedAt = now();
      relay.statusFinal = st.result ?? st.text;
      relay.frameReceipt = fr.result ?? null;
      relay.ethrexReceipt = er.result ?? null;
      save(state);
      console.log(`INCLUDED: block ${(er.result ?? fr.result)?.blockNumber}`);
      return;
    }
    if (Date.now() > deadline) {
      relay.statusFinal = st.result ?? st.text;
      relay.timedOutAt = now();
      save(state);
      throw new Error(`not included within 5 minutes; miner status: ${st.text}`);
    }
    await new Promise((r) => setTimeout(r, 5_000));
  }
}

main().catch((e) => {
  console.error(`STOPPED: ${(e as Error).message}`);
  process.exit(1);
});

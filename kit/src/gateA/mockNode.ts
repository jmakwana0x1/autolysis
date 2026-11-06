// MOCK frame node for `just gate-a-local`: a JSON-RPC proxy in front of anvil. Standard eth_* calls go to
// anvil unchanged (so deploy, legacy txs, reads are real). The frame-tx RPCs anvil lacks are answered here,
// and every such answer carries "mock": true:
//   ethrex_simulateFrameTransaction -> canned VERIFY gas per path (the A1 mock numbers), executionStatus success
//   eth_sendRawTransaction (0x06)   -> a canned canonical rejection (MOCK_CANONICAL=accept to accept)
//   eth_sendFrameTransaction        -> emulates the SENDER frame: etches FrameEnvStub over the frame env,
//                                       impersonates the account and calls frame 1 (selfLiquidate) on anvil
//   eth_getTransactionReceipt       -> the anvil receipt of that emulation, plus frameReceipts
//   skandha_frameTransactionStatus / skandha_explorer_listReputation -> canned
// VERIFY itself is NOT executed (anvil has no frame opcodes); that is what the devnet run measures.
import { createServer } from "node:http";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { decodeTx } from "@forshtat/hegota-support/tx";
import { profile } from "@forshtat/hegota-support/profiles/ethrex-eip8141-tracer";
import { encodeFunctionData, decodeFunctionResult, keccak256, toHex, type Hex } from "viem";
import { ROOT } from "../registry.js";
import { accountAbi } from "./abis.js";

const UPSTREAM = process.env.ANVIL_URL ?? "http://127.0.0.1:8546";
const PORT = Number(process.env.MOCK_PORT ?? "8547");
const GAS = { outside: Number(process.env.MOCK_OUTSIDE_GAS ?? 71_822), storage: Number(process.env.MOCK_STORAGE_GAS ?? 50_414) };
const STUB = JSON.parse(readFileSync(join(ROOT, "out/FrameEnvStub.sol/FrameEnvStub.json"), "utf8")).deployedBytecode.object as Hex;

let id = 0;
async function up(method: string, params: unknown[]): Promise<any> {
  const r = await fetch(UPSTREAM, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ jsonrpc: "2.0", id: ++id, method, params }) });
  const j = (await r.json()) as { result?: unknown; error?: { message: string } };
  if (j.error) throw new Error(`anvil ${method}: ${j.error.message}`);
  return j.result;
}
const call = async (to: Hex, fn: "storageOnlyVerify" | "env") => {
  const data = encodeFunctionData({ abi: accountAbi, functionName: fn });
  return decodeFunctionResult({ abi: accountAbi, functionName: fn, data: await up("eth_call", [{ to, data }, "latest"]) });
};

const emulated = new Map<string, string>(); // frame hash -> anvil hash
const frameReceipt = (r: any) => ({ ...r, mock: true, frameReceipts: [{ status: "0x1", mock: true }, { status: r.status }] });

const handlers: Record<string, (p: any[]) => Promise<unknown>> = {
  async ethrex_simulateFrameTransaction([raw]) {
    const tx = decodeTx(profile, raw);
    const storageOnly = (await call(tx.sender, "storageOnlyVerify")) as boolean;
    const gas = storageOnly ? GAS.storage : GAS.outside;
    const limits = tx.frames.reduce((s, f) => s + f.limits.execution + f.limits.state, 0n);
    return {
      mock: true,
      canonicalMempoolValid: storageOnly,
      canonicalMempoolViolation: storageOnly ? null : "MOCK: StorageReadNonSender",
      prefixShape: "self_verify", payer: tx.sender, maxCost: toHex(limits * tx.fees.maxFeePerGas),
      gasUsed: toHex(gas + 600_000), frames: [{ gasUsed: toHex(gas), succeeded: true }, { gasUsed: toHex(600_000), succeeded: true }],
      executionStatus: "success", executionError: null, erc7562Trace: null, erc7562TraceError: null,
    };
  },
  async eth_sendRawTransaction([raw]) {
    if (!String(raw).startsWith("0x06")) return up("eth_sendRawTransaction", [raw]);
    if (process.env.MOCK_CANONICAL === "accept") throw Object.assign(new Error("MOCK canonical accept is not emulated"), { code: -32601 });
    throw Object.assign(new Error("MOCK canonical mempool: validation prefix rejected: StorageReadNonSender"), { code: -32000 });
  },
  async eth_sendFrameTransaction([wire]) {
    const sender = wire.sender as Hex;
    const f1 = wire.frames[1];
    const env = (await call(sender, "env")) as Hex;
    await up("anvil_setCode", [env, STUB]);
    await up("anvil_impersonateAccount", [sender]);
    const h = await up("eth_sendTransaction", [{ from: sender, to: f1.target ?? sender, data: f1.data, gas: "0x2dc6c0" }]);
    await up("anvil_stopImpersonatingAccount", [sender]);
    const fh = keccak256(toHex(JSON.stringify(wire)));
    emulated.set(fh, h);
    return fh;
  },
  async eth_getTransactionReceipt([hash]) {
    const h = emulated.get(hash);
    if (!h) return up("eth_getTransactionReceipt", [hash]);
    const r = await up("eth_getTransactionReceipt", [h]);
    return r ? frameReceipt(r) : null;
  },
  async skandha_frameTransactionStatus([hash]) {
    return { mock: true, hash, status: emulated.has(hash) ? "included" : "unknown" };
  },
  async skandha_explorer_listReputation() {
    return { mock: true, entries: [] };
  },
};

createServer(async (req, res) => {
  let body = "";
  for await (const c of req) body += c;
  const msg = JSON.parse(body);
  const reply = async (m: any) => {
    try {
      const h = handlers[m.method];
      return { jsonrpc: "2.0", id: m.id, result: h ? await h(m.params ?? []) : await up(m.method, m.params ?? []) };
    } catch (e: any) {
      return { jsonrpc: "2.0", id: m.id, error: { code: e.code ?? -32000, message: e.message, ...(handlers[m.method] ? { data: { mock: true } } : {}) } };
    }
  };
  const out = Array.isArray(msg) ? await Promise.all(msg.map(reply)) : await reply(msg);
  res.writeHead(200, { "content-type": "application/json" });
  res.end(JSON.stringify(out));
}).listen(PORT, () => console.log(`[mock-node] :${PORT} -> ${UPSTREAM} (frame RPCs mocked)`));

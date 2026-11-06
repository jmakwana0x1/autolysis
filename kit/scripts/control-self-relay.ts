// Control experiment: the mempool-workshop's plain self-relay frame tx (buildSelfRelayTx + signFrameTx in
// lib/mempool-workshop/src/lib/frameTx/build.ts, reproduced 1:1 on the same hegota-support profile), sent to
// a given sidecar. Proves whether the chain lands a vanilla frame tx at all.
//   CONTROL_PK=0x.. npx tsx scripts/control-self-relay.ts <sendUrl>
import type { Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { profile } from "@forshtat/hegota-support/profiles/ethrex-eip8141-tracer";
import { frame, newTx, secp256k1Placeholder, signTx, txHash } from "@forshtat/hegota-support/tx";
import { toWire } from "@forshtat/hegota-support/rpc";
import { ENDPOINTS } from "../src/endpoints.js";

const RECIPIENT = "0x8943545177806ED17B9F23F0a21ee5948eCaa776"; // workshop.config.json5 recipient
const VALUE = 1_000_000_000n; // transferGwei: 1
const MAX_FEE = 2_000_000_000n; // maxFeePerGasGwei: 2

async function rpc(url: string, method: string, params: unknown[]) {
  const r = await fetch(url, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }) });
  const text = await r.text();
  const j = JSON.parse(text);
  return { text, result: j.result, error: j.error };
}

async function main() {
  const sendUrl = process.argv[2] ?? ENDPOINTS.miner;
  const pk = process.env.CONTROL_PK as Hex;
  if (!pk) throw new Error("CONTROL_PK not set");
  const from = privateKeyToAccount(pk).address;
  const nonce = BigInt((await rpc(ENDPOINTS.ethrex, "eth_getTransactionCount", [from, "latest"])).result);
  const unsigned = newTx({
    chainId: 1337,
    sender: from,
    nonceSeq: nonce,
    frames: [
      frame(profile, "VERIFY", { scope: "EXECUTION_AND_PAYMENT", target: null, execution: 30_000n }),
      frame(profile, "SENDER", { target: RECIPIENT, execution: 50_000n, value: VALUE, state: 200_000n }),
    ],
    signatures: [secp256k1Placeholder(profile, "0x")],
    fees: { maxFeePerGas: MAX_FEE },
  });
  const tx = await signTx(profile, unsigned, pk);
  const hash = txHash(profile, tx);
  console.log(`control from ${from} nonce ${nonce} hash ${hash}`);
  const sent = await rpc(sendUrl, "eth_sendFrameTransaction", [toWire(tx)]);
  console.log(`eth_sendFrameTransaction @ ${sendUrl}: ${sent.text}`);
  if (sent.error) throw new Error(`control rejected: ${sent.text}`);

  const deadline = Date.now() + 5 * 60_000;
  let last = "";
  for (;;) {
    const st = await rpc(sendUrl, "skandha_frameTransactionStatus", [hash]);
    const status = st.result?.status ?? st.text;
    if (status !== last) console.log(`${new Date().toISOString()} status: ${status}${st.result?.reason ? ` (${st.result.reason})` : ""}`), (last = status);
    const rc = await rpc(ENDPOINTS.ethrex, "eth_getTransactionReceipt", [hash]);
    if (rc.result) {
      const r = rc.result;
      console.log(`INCLUDED block ${Number(r.blockNumber)} status ${r.status} frames ${JSON.stringify((r.frameReceipts ?? []).map((f: any) => f.status))}`);
      if (r.status !== "0x1") process.exit(1);
      return;
    }
    if (status === "Cancelled" || Date.now() > deadline) throw new Error(`not included; final status: ${st.text}`);
    await new Promise((res) => setTimeout(res, 3_000));
  }
}

main().catch((e) => {
  console.error(`STOPPED: ${(e as Error).message}`);
  process.exit(1);
});

// `just probe`: settles the devnet assumptions and writes deployments/probes.json. Requires RPC_URL
// (chain 1337) and a devnet. It pins ONLY when every required field was confirmed by a real probe this
// run; a probe that did not run leaves its field as-is and the file stays pinned:false.
import { rpc } from "@forshtat/hegota-support/rpc";
import { readProbes, writeProbes, type Probes } from "../registry.js";
import { probes, mayPin, type ProbeCtx } from "./probes.js";
import { sendUrl, ethrexUrl } from "../endpoints.js";

async function main() {
  const account = process.env.ACCOUNT as `0x${string}` | undefined;
  if (!account) {
    console.error("ACCOUNT must be set: probes need the devnet account (chain 1337). Nothing written.");
    process.exit(1);
  }
  // Sends go to the gateway (RPC_URL override); simulate/receipts to the ethrex root (ETHREX_URL). The
  // devnet resets often, so this always re-probes and only pins when every required field is confirmed.
  const txUrl = sendUrl();
  const simUrl = ethrexUrl();
  const next: Probes = structuredClone(readProbes());
  const ctx: ProbeCtx = {
    call: (method, params) => rpc(txUrl, method, params),
    simCall: (method, params) => rpc(simUrl, method, params),
    probes: next,
    account,
    probeOpcodes: (next.probeCell as `0x${string}`) ?? undefined,
  };

  const confirmed = new Set<string>();
  let failed = 0;
  for (const p of probes) {
    try {
      console.log(`#${p.id} ${p.name.padEnd(24)} ${JSON.stringify(await p.run(ctx))}`);
      for (const f of p.confirms) confirmed.add(f);
    } catch (e) {
      failed++;
      console.log(`#${p.id} ${p.name.padEnd(24)} FAILED: ${(e as Error).message}`);
    }
  }
  next.pinned = mayPin(confirmed);
  next.probedAt = new Date().toISOString();
  next.rpc = txUrl;
  writeProbes(next);
  if (!next.pinned) console.log("not pinned: some required fields were not confirmed by a real probe this run");
  if (failed) process.exit(1);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});

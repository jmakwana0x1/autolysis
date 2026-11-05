// `just probe`: settles the devnet assumptions and writes deployments/probes.json. Requires RPC_URL
// (chain 1337) and the @forshtat/hegota-support package. Not exercised without a devnet.
import { readProbes, writeProbes, type Probes } from "../registry.js";
import { probes, type ProbeCtx } from "./probes.js";

async function main() {
  const rpcUrl = process.env.RPC_URL;
  if (!rpcUrl) {
    console.error("RPC_URL is not set: probes need the devnet (chain 1337). Nothing written.");
    process.exit(1);
  }
  const before = readProbes();
  const next: Probes = structuredClone(before);
  const ctx: ProbeCtx = { rpcUrl, altRpcUrl: process.env.ALT_RPC_URL ?? rpcUrl, probes: next, pk: process.env.PROBE_PK as `0x${string}` | undefined };

  let failed = 0;
  for (const p of probes) {
    try {
      console.log(`#${p.id} ${p.name.padEnd(24)} ${JSON.stringify(await p.run(ctx))}`);
    } catch (e) {
      failed++;
      console.log(`#${p.id} ${p.name.padEnd(24)} FAILED: ${(e as Error).message}`);
    }
  }
  next.pinned = failed === 0;
  next.probedAt = new Date().toISOString();
  next.rpc = rpcUrl;
  writeProbes(next);
  if (failed) process.exit(1);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});

// `just probe`: settles the devnet assumptions on chain and writes deployments/probes.json.
// Rerun before every demo. Any probe that cannot run leaves its field untouched and fails the run.
import { createPublicClient, http, type Hex } from "viem";
import { readProbes, writeProbes, type Probes } from "../registry.js";
import { probes, type ProbeCtx } from "./probes.js";

async function main() {
  const rpc = process.env.RPC_URL;
  const alt = process.env.ALT_RPC_URL ?? rpc;
  if (!rpc) {
    console.error("RPC_URL is not set: probes need the devnet (chain 1337). Nothing written.");
    process.exit(1);
  }
  const client = createPublicClient({ transport: http(rpc) });
  const altClient = createPublicClient({ transport: http(alt) });
  const chainId = await client.getChainId();
  if (chainId !== 1337) throw new Error(`expected chain 1337, got ${chainId}`);

  const before = readProbes();
  const next: Probes = structuredClone(before);
  const ctx: ProbeCtx = { client, altClient, probes: next, pk: process.env.PROBE_PK as Hex | undefined };

  let failed = 0;
  for (const p of probes) {
    try {
      const r = await p.run(ctx);
      console.log(`#${p.id} ${p.name.padEnd(24)} ${JSON.stringify(r)}`);
    } catch (e) {
      failed++;
      console.log(`#${p.id} ${p.name.padEnd(24)} FAILED: ${(e as Error).message}`);
    }
  }

  next.pinned = failed === 0;
  next.probedAt = new Date().toISOString();
  next.rpc = rpc;
  writeProbes(next);

  const changed = diff(before, next);
  if (changed.length) console.log(`changed: ${changed.join(", ")} -> run \`just gen\` and rebuild`);
  if (failed) process.exit(1);
}

function diff(a: Probes, b: Probes): string[] {
  const skip = new Set(["probedAt", "rpc", "pinned"]);
  return Object.keys(b).filter((k) => !skip.has(k) && JSON.stringify(a[k]) !== JSON.stringify(b[k]));
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});

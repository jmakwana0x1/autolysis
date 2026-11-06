// Print the hash of the canonical liquidation tx gate-a/scenes would build for (position, round, sequence),
// with the default gate-a limits/fees, so a sidecar can be asked about it. Read-only.
//   npx tsx scripts/hash-canonical.ts <positionId> <roundId> [sequence]
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { profile } from "@forshtat/hegota-support/profiles/ethrex-eip8141-tracer";
import { txHash } from "@forshtat/hegota-support/tx";
import { ROOT } from "../src/registry.js";
import { canonicalLiquidationTx } from "../src/frameTx.js";
import { defaultConfig } from "../src/gateA/gateA.js";

const [pos, round, seq] = process.argv.slice(2);
const c = JSON.parse(readFileSync(join(ROOT, "deployments", "1337.json"), "utf8")).contracts;
const cfg = defaultConfig(1337, "");
const tx = canonicalLiquidationTx({
  chainId: 1337, account: c.AutolysisAccount, market: c.AutolysisMarket, positionId: BigInt(pos), roundId: BigInt(round),
  sequence: BigInt(seq ?? "0"), maxFeePerGas: cfg.maxFeePerGas, verifyGas: cfg.verifyGasLimit, verifyStateLimit: cfg.verifyStateLimit,
  executeGas: cfg.executeGasLimit, executeStateLimit: cfg.executeStateLimit, signatureForm: "arbitrary",
});
console.log(txHash(profile, tx));

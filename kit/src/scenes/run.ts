// `just scene <crash|replace|attacks|uniswap-balances>` and `just reputation <label>`. Same env as
// `just gate-a` (PRIVATE_KEY, RPC_URL, ETHREX_URL, CHAIN_ID). Records into deployments/<chainId>.json and
// exits 1 when the scene's assertion fails (the record still holds every exact response).
import { mkdirSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import type { Hex } from "viem";
import { ROOT } from "../registry.js";
import { ENDPOINTS, frameSendUrl } from "../endpoints.js";
import { defaultConfig } from "../gateA/gateA.js";
import { realChainIO, realFrameIO, type IoConfig } from "../gateA/io.js";
import { fileStore } from "../gateA/store.js";
import { attacks, crash, replace, reputation, uniswapBalances, type SceneDeps } from "./phaseB.js";

const scenes: Record<string, (d: SceneDeps, arg?: string) => Promise<Record<string, any>>> = {
  crash: (d) => crash(d),
  replace: (d) => replace(d),
  attacks: (d) => attacks(d),
  "uniswap-balances": (d) => uniswapBalances(d),
  reputation: (d, label) => reputation(d, label ?? "manual"),
};

async function main() {
  const [name, arg] = process.argv.slice(2);
  const scene = scenes[name];
  if (!scene) throw new Error(`unknown scene "${name}"; one of: ${Object.keys(scenes).join(", ")}`);
  const pk = process.env.PRIVATE_KEY as Hex | undefined;
  if (!pk) throw new Error("PRIVATE_KEY is not set (put the devnet-only key in .env)");
  const io: IoConfig = {
    rpcUrl: process.env.RPC_URL ?? ENDPOINTS.gateway,
    ethrexUrl: process.env.ETHREX_URL ?? ENDPOINTS.ethrex,
    frameUrl: frameSendUrl(),
    privateKey: pk,
    legacyGasPriceWei: BigInt(process.env.LEGACY_GAS_PRICE_WEI ?? "2000000"),
  };
  const chainId = Number(process.env.CHAIN_ID ?? "1337");
  const cfg = defaultConfig(chainId, process.env.EXPLORER_URL ?? ENDPOINTS.explorer);
  cfg.explorerNode = frameSendUrl();
  if (process.env.GATE_A_POLL_MS) cfg.pollMs = Number(process.env.GATE_A_POLL_MS);
  const out = await scene(
    {
      chain: realChainIO(io, chainId),
      frame: realFrameIO(io),
      store: fileStore(chainId),
      cfg,
      log: console.log,
      writeFile: (rel, content) => {
        mkdirSync(dirname(join(ROOT, rel)), { recursive: true });
        writeFileSync(join(ROOT, rel), content);
      },
    },
    arg,
  );
  const { raw: _r, current: _c, ...shown } = out as Record<string, unknown>;
  console.log(JSON.stringify(shown, (_k, v) => (typeof v === "bigint" ? v.toString() : v), 2));
  console.log(`\nscene ${name}: ${out.ok ? "OK" : "FAILED"} (recorded in deployments/${chainId}.json)`);
  if (!out.ok) process.exit(1);
}

main().catch((e) => {
  console.error(`scene stopped: ${(e as Error).message}`);
  process.exit(1);
});

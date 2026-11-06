// `just gate-a` entry point. Env: PRIVATE_KEY (devnet-only key, from .env), RPC_URL (gateway /rpc),
// ETHREX_URL (ethrex root, for simulate), optional EXPLORER_URL, STAKING_REGISTRY, LEGACY_GAS_PRICE_WEI.
// Writes everything to deployments/<chainId>.json and stops on the first error with its exact text.
import { readFileSync, writeFileSync, existsSync, renameSync } from "node:fs";
import { join } from "node:path";
import type { Address, Hex } from "viem";
import { ROOT } from "../registry.js";
import { ENDPOINTS } from "../endpoints.js";
import { defaultConfig, runGateA, GateAError, type Store } from "./gateA.js";
import { forgeDeploy, realChainIO, realFrameIO, type IoConfig } from "./io.js";

export function fileStore(chainId: number): Store {
  const file = join(ROOT, "deployments", `${chainId}.json`);
  return {
    load: () => (existsSync(file) ? JSON.parse(readFileSync(file, "utf8")) : { chainId, contracts: {} }),
    save: (s) => {
      writeFileSync(`${file}.tmp`, JSON.stringify(s, null, 2) + "\n");
      renameSync(`${file}.tmp`, file);
    },
  };
}

async function main() {
  const pk = process.env.PRIVATE_KEY as Hex | undefined;
  if (!pk) throw new Error("PRIVATE_KEY is not set (put the devnet-only key in .env)");
  const io: IoConfig = {
    rpcUrl: process.env.RPC_URL ?? ENDPOINTS.gateway,
    ethrexUrl: process.env.ETHREX_URL ?? ENDPOINTS.ethrex,
    privateKey: pk,
    legacyGasPriceWei: BigInt(process.env.LEGACY_GAS_PRICE_WEI ?? "2000000"), // 0.002 gwei
  };
  const chainId = Number(process.env.CHAIN_ID ?? "1337");
  const cfg = defaultConfig(chainId, process.env.EXPLORER_URL ?? ENDPOINTS.explorer);
  if (process.env.STAKING_REGISTRY) cfg.registry = process.env.STAKING_REGISTRY as Address;
  if (process.env.FRAME_MAX_FEE_WEI) cfg.maxFeePerGas = BigInt(process.env.FRAME_MAX_FEE_WEI);
  if (process.env.GATE_A_POLL_MS) cfg.pollMs = Number(process.env.GATE_A_POLL_MS);

  const state = await runGateA({
    chain: realChainIO(io, chainId),
    frame: realFrameIO(io),
    deploy: forgeDeploy(io, chainId),
    store: fileStore(chainId),
    cfg,
    log: (m) => console.log(m),
  });
  const g = state.gateA;
  console.log(`\nGATE A PASSED on chain ${chainId}`);
  console.log(`  VERIFY path: ${g.verify?.chosen} (${g.verify?.reason})`);
  console.log(`  canonical mempool: ${g.canonical?.responseText}`);
  console.log(`  liquidation: ${g.liquidation?.hash} -> ${g.liquidation?.outcome}`);
  console.log(`  explorer: ${g.liquidation?.explorer?.url} (search ${g.liquidation?.hash})`);
  console.log(`  record: deployments/${chainId}.json`);
}

main().catch((e) => {
  if (e instanceof GateAError) console.error(`\nGATE A STOPPED at step "${e.step}":\n${e.message}`);
  else console.error(e);
  process.exit(1);
});

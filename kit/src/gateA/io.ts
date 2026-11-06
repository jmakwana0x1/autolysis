// Real IO for `just gate-a`: legacy txs and reads through viem (gateway /rpc, legacy gas price), frame-tx
// RPCs exactly as the vendored workshop/sidecar call them, and the forge deploy. Every failure carries the
// node's exact text.
import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import {
  createPublicClient, createWalletClient, defineChain, http, type Abi, type Address, type Hex,
  type PublicClient, type WalletClient, type Chain, BaseError, ContractFunctionRevertedError,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { rpc } from "@forshtat/hegota-support/rpc";
import { toWire } from "@forshtat/hegota-support/rpc";
import type { FrameTx } from "@forshtat/hegota-support/tx";
import { ROOT } from "../registry.js";
import { simulate as simulateRaw, type EthrexSimResult } from "../sim.js";

export type TxResult = { hash: Hex; status: "success" | "reverted"; gasUsed: bigint };
export type RawResponse = { ok: boolean; text: string; result?: unknown; error?: { code: number; message: string; data?: unknown } };
export type FrameReceipt = {
  status: Hex;
  blockNumber?: Hex;
  transactionHash?: Hex;
  frameReceipts?: { status: Hex; [k: string]: unknown }[];
  logs?: { address: Address; topics: Hex[]; data: Hex }[];
  [k: string]: unknown;
};

export interface ChainIO {
  deployer: Address;
  chainId(): Promise<number>;
  balance(a: Address): Promise<bigint>;
  code(a: Address): Promise<Hex>;
  storageAt(a: Address, slot: Hex): Promise<Hex>;
  read<T = unknown>(address: Address, abi: Abi, fn: string, args?: readonly unknown[]): Promise<T>;
  /** Legacy tx; waits for the receipt; throws with the revert reason on failure. */
  write(address: Address, abi: Abi, fn: string, args?: readonly unknown[], value?: bigint): Promise<TxResult>;
  send(to: Address, value: bigint): Promise<TxResult>;
}

export interface FrameIO {
  simulate(tx: FrameTx): Promise<EthrexSimResult>;
  /** eth_sendRawTransaction of the 0x06 bytes; never throws on a JSON-RPC error, returns the exact body. */
  sendRaw(raw: Hex): Promise<RawResponse>;
  /** eth_sendFrameTransaction(toWire(tx)); throws with the exact error text. */
  sendFrame(tx: FrameTx): Promise<Hex>;
  status(hash: Hex): Promise<unknown>;
  receipt(hash: Hex): Promise<FrameReceipt | null>;
  reputation(): Promise<unknown>;
}

export type DeployFn = (opts: { usePredeployedV4: boolean }) => Promise<Record<string, Address>>;

export type IoConfig = {
  rpcUrl: string; // gateway /rpc (sends, reads)
  ethrexUrl: string; // ethrex root (simulate)
  privateKey: Hex;
  legacyGasPriceWei: bigint;
  legacyGasLimit?: bigint;
};

async function jsonRpcRaw(url: string, method: string, params: unknown[]): Promise<RawResponse> {
  const res = await fetch(url, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }),
  });
  const text = await res.text();
  let body: { result?: unknown; error?: { code: number; message: string; data?: unknown } } = {};
  try {
    body = JSON.parse(text);
  } catch {
    return { ok: false, text, error: { code: res.status, message: text } };
  }
  return body.error ? { ok: false, text, error: body.error } : { ok: true, text, result: body.result };
}

function revertText(e: unknown): string {
  if (e instanceof BaseError) {
    const r = e.walk((x) => x instanceof ContractFunctionRevertedError) as ContractFunctionRevertedError | null;
    if (r) return r.data?.errorName ? `${r.data.errorName}(${(r.data.args ?? []).join(",")})` : r.reason ?? r.shortMessage;
    return e.shortMessage + (e.details ? ` (${e.details})` : "");
  }
  return (e as Error).message;
}

export function realChainIO(cfg: IoConfig, chainId: number): ChainIO {
  const account = privateKeyToAccount(cfg.privateKey);
  const chain: Chain = defineChain({
    id: chainId, name: `chain-${chainId}`, nativeCurrency: { name: "ETH", symbol: "ETH", decimals: 18 },
    rpcUrls: { default: { http: [cfg.rpcUrl] } },
  });
  const pub: PublicClient = createPublicClient({ chain, transport: http(cfg.rpcUrl) });
  const wallet: WalletClient = createWalletClient({ account, chain, transport: http(cfg.rpcUrl) });
  const legacy = { type: "legacy" as const, gasPrice: cfg.legacyGasPriceWei };

  const wait = async (hash: Hex, what: string, sim: () => Promise<unknown>): Promise<TxResult> => {
    const r = await pub.waitForTransactionReceipt({ hash, timeout: 180_000 });
    if (r.status !== "success") {
      let reason = "no reason";
      try {
        await sim();
      } catch (e) {
        reason = revertText(e);
      }
      throw new Error(`${what} reverted in tx ${hash}: ${reason}`);
    }
    return { hash, status: r.status, gasUsed: r.gasUsed };
  };

  return {
    deployer: account.address,
    chainId: () => pub.getChainId(),
    balance: (a) => pub.getBalance({ address: a }),
    code: async (a) => (await pub.getCode({ address: a })) ?? "0x",
    storageAt: async (a, slot) => (await pub.getStorageAt({ address: a, slot })) ?? "0x0",
    read: async <T>(address: Address, abi: Abi, fn: string, args: readonly unknown[] = []) =>
      (await pub.readContract({ address, abi, functionName: fn, args })) as T,
    write: async (address, abi, fn, args = [], value = 0n) => {
      const req = { address, abi, functionName: fn, args, value, account } as const;
      let hash: Hex;
      try {
        hash = await wallet.writeContract({ ...req, chain, ...legacy, gas: cfg.legacyGasLimit });
      } catch (e) {
        throw new Error(`${fn} on ${address} not sent: ${revertText(e)}`);
      }
      return wait(hash, `${fn} on ${address}`, () => pub.simulateContract(req));
    },
    send: async (to, value) => {
      const hash = await wallet.sendTransaction({ account, chain, to, value, ...legacy, gas: 50_000n });
      return wait(hash, `send ${value} wei to ${to}`, async () => undefined);
    },
  };
}

export function realFrameIO(cfg: IoConfig): FrameIO {
  return {
    simulate: (tx) => simulateRaw((m, p) => rpc(cfg.ethrexUrl, m, p ?? []), tx),
    sendRaw: (raw) => jsonRpcRaw(cfg.rpcUrl, "eth_sendRawTransaction", [raw]),
    sendFrame: async (tx) => {
      const r = await jsonRpcRaw(cfg.rpcUrl, "eth_sendFrameTransaction", [toWire(tx)]);
      if (!r.ok) throw new Error(`eth_sendFrameTransaction rejected: ${r.text}`);
      return r.result as Hex;
    },
    status: async (hash) => (await jsonRpcRaw(cfg.rpcUrl, "skandha_frameTransactionStatus", [hash])).result ?? null,
    // The workshop reads frame receipts with eth_getTransactionReceipt through the gateway
    // (lib/mempool-workshop/src/lib/chain.ts waitMined + frameTx/send.ts waitForReceipt).
    receipt: async (hash) => ((await jsonRpcRaw(cfg.rpcUrl, "eth_getTransactionReceipt", [hash])).result as FrameReceipt) ?? null,
    reputation: async () => {
      const r = await jsonRpcRaw(cfg.rpcUrl, "skandha_explorer_listReputation", [{ limit: 200 }]);
      return r.ok ? r.result : { error: r.text };
    },
  };
}

/** forge script Deploy.s.sol with legacy txs at the configured gas price. Addresses come back from the
 *  script's own JSON (deployments/<chainId>.addresses.json). */
export function forgeDeploy(cfg: IoConfig, chainId: number): DeployFn {
  return async ({ usePredeployedV4 }) => {
    const args = [
      "script", "script/Deploy.s.sol:Deploy", "--rpc-url", cfg.rpcUrl, "--broadcast", "--slow",
      "--legacy", "--with-gas-price", cfg.legacyGasPriceWei.toString(), "--private-key", cfg.privateKey,
    ];
    if (process.env.FORGE_SKIP_SIMULATION === "true") args.push("--skip-simulation");
    if (process.env.FORGE_GAS_ESTIMATE_MULTIPLIER) args.push("--gas-estimate-multiplier", process.env.FORGE_GAS_ESTIMATE_MULTIPLIER);
    const r = spawnSync("forge", args, {
      cwd: ROOT,
      env: { ...process.env, USE_PREDEPLOYED_V4: String(usePredeployedV4), STAKING_REGISTRY: "0x0000000000000000000000000000000000000000", STORAGE_ONLY_VERIFY: "false" },
      encoding: "utf8",
      maxBuffer: 64 * 1024 * 1024,
    });
    if (r.status !== 0) {
      const tail = `${r.stdout ?? ""}\n${r.stderr ?? ""}`.split("\n").filter((l) => l.trim()).slice(-25).join("\n");
      throw new Error(`forge script Deploy.s.sol failed (exit ${r.status}):\n${tail.replaceAll(cfg.privateKey, "<redacted>")}`);
    }
    return JSON.parse(readFileSync(join(ROOT, "deployments", `${chainId}.addresses.json`), "utf8"));
  };
}

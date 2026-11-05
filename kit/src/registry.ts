// One source of addresses and probe constants: deployments/*.json. Nothing in the kit hard-codes them.
import { readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import type { Address } from "viem";

export const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const file = (name: string) => join(ROOT, "deployments", name);

export type Probes = {
  chainId: number;
  pinned: boolean;
  probedAt: string | null;
  rpc: string | null;
  opcodes: Record<"APPROVE" | "TXPARAM" | "FRAMEPARAM" | "FRAMEDATALOAD" | "SIGPARAM", { op: number; works: boolean | null }>;
  txParams: Record<string, number>;
  frameParams: Record<string, number>;
  feeFormat: "total_cost" | "per_gas";
  stakedExternalReads: boolean | null;
  firstUseKeyStateGas: number;
  sequenceCeiling: string;
  replacementBumpBps: number;
  solvencyRejection: boolean | null;
  reputationCounters: { seenOnReplacement: number; includedOnReplacement: number } | null;
  [k: string]: unknown;
};

export type Deployment = { chainId: number; contracts: Record<string, Address> };

export const readProbes = (): Probes => JSON.parse(readFileSync(file("probes.json"), "utf8"));
export const writeProbes = (p: Probes) => writeFileSync(file("probes.json"), JSON.stringify(p, null, 2) + "\n");

export function readDeployment(chainId = 1337): Deployment {
  return JSON.parse(readFileSync(file(`${chainId}.json`), "utf8"));
}

export function addressOf(name: string, chainId = 1337): Address {
  const a = readDeployment(chainId).contracts[name];
  if (!a) throw new Error(`deployments/${chainId}.json has no "${name}"; run \`just reset\``);
  return a;
}

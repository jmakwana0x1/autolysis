import { readFileSync, writeFileSync, existsSync, renameSync } from "node:fs";
import { join } from "node:path";
import { ROOT } from "../registry.js";
import type { Store } from "./gateA.js";

/** deployments/<chainId>.json, written atomically. */
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

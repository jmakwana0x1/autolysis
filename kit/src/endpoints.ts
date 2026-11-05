// Hegota alt-mempool devnet endpoints (chain 1337). Source: forshtat/mempool-workshop-sidecar
// deploy/devnet/devnet-readme.md, vendored at lib/mempool-workshop-sidecar. See docs/DEVNET.md.
//
// Send everything to the GATEWAY (/rpc): eth_sendFrameTransaction (alt mempool) and
// eth_sendRawTransaction (canonical, forwarded to ethrex). Run ethrex_simulateFrameTransaction,
// receipts and debug_* against the ETHREX ROOT. The devnet resets at any time and the ethrex image
// tracks a moving branch, so rerun the probes before every demo — nothing here is pinned.

export const ENDPOINTS = {
  /** Gateway sidecar — send all transactions here (eth_sendFrameTransaction / eth_sendRawTransaction). */
  gateway: "https://altmempoolgateway.forshtat.com/rpc",
  /** Miner sidecar. */
  miner: "https://altmempool.forshtat.com/rpc",
  /** ethrex root — ethrex_simulateFrameTransaction, eth_getTransactionReceipt, debug_*. */
  ethrex: "https://altmempool.forshtat.com",
  /** Block explorer. */
  explorer: "https://explorer.altmempool.wtf/",
} as const;

export const CHAIN_ID = 1337;

/** Where transactions are sent (override with RPC_URL). */
export const sendUrl = (): string => process.env.RPC_URL ?? ENDPOINTS.gateway;
/** Where read-only simulate / receipts / debug run (override with ETHREX_URL, else RPC_URL, else root). */
export const ethrexUrl = (): string => process.env.ETHREX_URL ?? process.env.RPC_URL ?? ENDPOINTS.ethrex;

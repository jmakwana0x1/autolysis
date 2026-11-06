// `just gate-a` state machine against a fake chain + fake frame node (the mocked RPC). The real-chain
// parts (deploy, legacy txs) are additionally exercised against anvil by `just gate-a-local`.
import { describe, it, expect } from "vitest";
import { encodeEventTopics, pad, numberToHex, type Address, type Hex } from "viem";
import { runGateA, defaultConfig, GateAError, type Store } from "../src/gateA/gateA.js";
import type { ChainIO, FrameIO, FrameReceipt } from "../src/gateA/io.js";
import { accountAbi } from "../src/gateA/abis.js";
import type { EthrexSimResult } from "../src/sim.js";

const A = (n: number) => `0x${n.toString(16).padStart(40, "0")}` as Address;
const CONTRACTS = {
  WETH: A(1), USDC: A(2), RoundFeed: A(3), HegotaFrameEnv: A(4), AutolysisAccount: A(5), AutolysisMarket: A(6),
  PoolManager: A(7), BackstopHook: A(8), V4Venue: A(9),
};
const DEPLOYER = A(0xd0);
const WAD = 10n ** 18n;

type World = {
  deployed: boolean;
  stake: bigint;
  storageOnly: boolean;
  feeCap: bigint;
  accountEth: bigint;
  nextPos: bigint;
  owners: Map<bigint, Address>;
  rounds: { price: bigint; timestamp: bigint }[];
  writes: string[];
  liquidated: Set<bigint>;
};

function world(): World {
  return {
    deployed: false, stake: 0n, storageOnly: false, feeCap: 10n ** 15n, accountEth: 0n, nextPos: 1n,
    owners: new Map(), rounds: [{ price: 2n * WAD, timestamp: 1_000n }], writes: [], liquidated: new Set(),
  };
}

function fakeChain(w: World, nowSec: () => bigint): ChainIO {
  const hf = (id: bigint) => {
    if (w.liquidated.has(id)) return 105n * 10n ** 16n;
    const p = w.rounds[w.rounds.length - 1].price;
    return (p * 8n) / 15n; // 0.1 col @p, L 0.8, debt 0.15 -> HF = p * 0.8 / 1.5
  };
  let n = 0;
  const tx = (what: string) => {
    w.writes.push(what);
    return { hash: `0x${(++n).toString(16).padStart(64, "0")}` as Hex, status: "success" as const, gasUsed: 21_000n };
  };
  return {
    deployer: DEPLOYER,
    chainId: async () => 1337,
    balance: async (a) => (a === CONTRACTS.AutolysisAccount ? w.accountEth : 10n ** 18n),
    code: async () => (w.deployed ? "0x60" : "0x") as Hex,
    storageAt: async () => "0x0" as Hex,
    read: async <T,>(_a: Address, _abi: unknown, fn: string, args: readonly unknown[] = []) => {
      const id = args[0] as bigint;
      const r: Record<string, () => unknown> = {
        getDepositInfo: () => [w.stake, w.stake > 0n ? 86_400 : 0, 0n],
        stakingRegistry: () => (w.stake > 0n ? defaultConfig(1337, "").registry : A(0)),
        feeCapTotal: () => w.feeCap,
        nextPositionId: () => w.nextPos,
        positions: () => [w.owners.get(id) ?? A(0), 10n ** 17n, 15n * 10n ** 16n, w.liquidated.has(id) ? 1n : 0n],
        latestRound: () => BigInt(w.rounds.length),
        getRound: () => w.rounds[Number(id) - 1],
        healthFactor: () => hf(id),
        storageOnlyVerify: () => w.storageOnly,
        totalFeeBilled: () => 0n,
        depositsOf: () => 1_000n * WAD,
        balanceOf: () => 0n,
      };
      if (!r[fn]) throw new Error(`fake read ${fn}`);
      return r[fn]() as T;
    },
    write: async (_a, _abi, fn, args = [], value = 0n) => {
      if (fn === "stake") w.stake += value;
      if (fn === "setFeeCap") w.feeCap = args[0] as bigint;
      if (fn === "setStorageOnlyVerify") w.storageOnly = args[0] as boolean;
      if (fn === "open") w.owners.set(w.nextPos++, DEPLOYER);
      if (fn === "post") w.rounds.push({ price: args[0] as bigint, timestamp: nowSec() });
      return tx(fn);
    },
    send: async (_to, value) => {
      w.accountEth += value;
      return tx("send");
    },
  };
}

type FrameOpts = { outsideGas?: number; storageGas?: number; canonical?: "reject" | "accept"; outcome?: "ok" | "failed"; sendError?: string; receiptAfterPolls?: number };
function fakeFrame(w: World, o: FrameOpts = {}) {
  const calls: string[] = [];
  let polls = 0;
  const sim = (gas: number, ok = true): EthrexSimResult => ({
    canonicalMempoolValid: false, canonicalMempoolViolation: "StorageReadNonSender", maxCost: "0x11c37937e08000",
    gasUsed: null, frames: [{ gasUsed: `0x${gas.toString(16)}`, succeeded: ok }, { gasUsed: "0x927c0", succeeded: true }],
    executionStatus: "success", executionError: null,
  });
  const receipt = (positionId: bigint): FrameReceipt => {
    const ev = o.outcome === "failed" ? "LiquidationFailed" : "LiquidationOk";
    return {
      status: "0x1", frameReceipts: [{ status: "0x1" }, { status: "0x1" }],
      logs: [{ address: CONTRACTS.AutolysisAccount, topics: [encodeEventTopics({ abi: accountAbi, eventName: ev })[0], pad(numberToHex(positionId), { size: 32 })], data: "0x" }],
    };
  };
  let sentFor: bigint | null = null;
  const io: FrameIO = {
    simulate: async () => {
      calls.push(`simulate:${w.storageOnly ? "storage" : "outside"}`);
      return w.storageOnly ? sim(o.storageGas ?? 50_414) : sim(o.outsideGas ?? 71_822);
    },
    sendRaw: async () => {
      calls.push("sendRaw");
      if (o.canonical === "accept") {
        w.liquidated.add(1n);
        return { ok: true, text: '{"jsonrpc":"2.0","id":1,"result":"0xcafe"}', result: "0xcafe" };
      }
      return { ok: false, text: '{"jsonrpc":"2.0","id":1,"error":{"code":-32000,"message":"StorageReadNonSender"}}', error: { code: -32000, message: "StorageReadNonSender" } };
    },
    sendFrame: async (tx) => {
      calls.push("sendFrame");
      if (o.sendError) throw new Error(o.sendError);
      sentFor = BigInt(`0x${tx.frames[1].data.slice(10, 74)}`);
      return "0xf00d";
    },
    status: async () => ({ status: "pending" }),
    receipt: async (hash) => {
      if (hash === "0xcafe") return receipt(1n);
      if (o.receiptAfterPolls && polls++ < o.receiptAfterPolls) return null;
      if (sentFor === null && !o.receiptAfterPolls) return null;
      const id = sentFor ?? 1n;
      if (o.outcome !== "failed") w.liquidated.add(id);
      return receipt(id);
    },
    reputation: async () => ({ entries: [{ address: CONTRACTS.AutolysisAccount, isStaked: true, status: "ok" }] }),
  };
  return { io, calls };
}

function memStore(): Store & { state: Record<string, any> } {
  const s = { state: {} as Record<string, any> } as Store & { state: Record<string, any> };
  s.load = () => structuredClone(s.state);
  s.save = (x) => {
    s.state = structuredClone(x);
  };
  return s;
}

function harness(o: FrameOpts = {}, w = world(), store = memStore()) {
  const clock = { t: 1_000_000 };
  const f = fakeFrame(w, o);
  let deploys = 0;
  const cfg = { ...defaultConfig(1337, "https://explorer.altmempool.wtf/"), pollMs: 0, receiptTimeoutMs: 50 };
  const run = () =>
    runGateA({
      chain: fakeChain(w, () => BigInt(clock.t)),
      frame: f.io,
      deploy: async ({ usePredeployedV4 }) => {
        deploys++;
        expect(usePredeployedV4).toBe(true);
        w.deployed = true;
        return CONTRACTS;
      },
      store,
      cfg,
      sleep: async () => {},
      now: () => new Date(clock.t * 1000),
    });
  return { run, w, store, calls: f.calls, deploys: () => deploys };
}

describe("just gate-a", () => {
  it("runs Phase A end to end and records everything", async () => {
    const h = harness();
    const s = await h.run();
    const g = s.gateA;
    expect(h.deploys()).toBe(1);
    expect(h.w.stake).toBe(12n * 10n ** 15n);
    expect(h.calls).toEqual(["simulate:outside", "simulate:storage", "sendRaw", "sendFrame"]);
    expect(g.verify.chosen).toBe("outside-reads");
    expect(g.verify.outsideReads.verifyGasUsed).toBe(71_822);
    expect(g.verify.storageOnly.verifyGasUsed).toBe(50_414);
    expect(h.w.storageOnly).toBe(false); // left on the chosen path
    expect(g.canonical.responseText).toContain("StorageReadNonSender");
    expect(g.liquidation.hash).toBe("0xf00d");
    expect(g.liquidation.outcome).toBe("LiquidationOk");
    expect(g.liquidation.before.position.debt).toBeDefined();
    expect(g.result).toBe("passed");
    expect(h.store.state.contracts.AutolysisAccount).toBe(CONTRACTS.AutolysisAccount);
  });

  it("is idempotent: a second run deploys, stakes, seeds and sends nothing", async () => {
    const h = harness();
    await h.run();
    const writes = h.w.writes.length;
    const calls = h.calls.length;
    await h.run();
    expect(h.deploys()).toBe(1);
    expect(h.w.writes.length).toBe(writes);
    expect(h.calls.length).toBe(calls);
  });

  it("chooses storage-only when outside reads would not fit 100k with margin", async () => {
    const h = harness({ outsideGas: 97_500 });
    const s = await h.run();
    expect(s.gateA.verify.chosen).toBe("storage-only");
    expect(h.w.storageOnly).toBe(true);
  });

  it("stops at the first error with its exact text and sends nothing after it", async () => {
    const h = harness({ outsideGas: 120_000, storageGas: 101_000 });
    await expect(h.run()).rejects.toBeInstanceOf(GateAError);
    expect(h.store.state.gateA.failed.step).toBe("simulate");
    expect(h.store.state.gateA.failed.error).toContain("neither path fits");
    expect(h.calls).not.toContain("sendRaw");
    expect(h.calls).not.toContain("sendFrame");
  });

  it("propagates the alt mempool's rejection text verbatim", async () => {
    const msg = 'eth_sendFrameTransaction rejected: {"error":{"code":-32602,"message":"unstaked sender accessed 0xabc slot 0x1"}}';
    const h = harness({ sendError: msg });
    await expect(h.run()).rejects.toThrow(msg);
    expect(h.store.state.gateA.failed).toMatchObject({ step: "liquidate", error: msg });
  });

  it("if the canonical mempool accepts, records its inclusion and liquidates the second position via alt", async () => {
    const h = harness({ canonical: "accept" });
    const s = await h.run();
    expect(s.gateA.canonical.accepted).toBe(true);
    expect(s.gateA.canonical.included).toBe(true);
    expect(s.gateA.liquidation.positionId).toBe("2");
    expect(s.gateA.liquidation.outcome).toBe("LiquidationOk");
  });

  it("an executed-but-failed liquidation (LiquidationFailed) stops the run", async () => {
    const h = harness({ outcome: "failed" });
    await expect(h.run()).rejects.toThrow(/LiquidationFailed/);
  });

  it("resumes a sent liquidation by polling its hash instead of resending", async () => {
    const w = world();
    const store = memStore();
    const first = harness({ receiptAfterPolls: 1_000_000 }, w, store);
    await expect(first.run()).rejects.toThrow(/no receipt/);
    expect(first.calls.filter((c) => c === "sendFrame").length).toBe(1);
    const second = harness({}, w, store);
    await second.run().catch(() => {});
    expect(second.calls).not.toContain("sendFrame");
    expect(store.state.gateA.liquidation.hash).toBe("0xf00d");
  });
});

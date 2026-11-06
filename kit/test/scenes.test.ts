// Phase B scenes against a fake chain + a fake frame node (mocked RPC) that applies VERIFY's shape rules
// and the alt mempool's keyed replacement. Frames cannot run locally; this pins each scene's logic,
// what it sends, what it records, and that it fails loudly when an outcome is wrong.
import { describe, it, expect } from "vitest";
import { encodeErrorResult, encodeEventTopics, keccak256, numberToHex, pad, toHex, type Address, type Hex } from "viem";
import { profile } from "@forshtat/hegota-support/profiles/ethrex-eip8141-tracer";
import { frameMode, type FrameTx } from "@forshtat/hegota-support/tx";
import { runGateA, defaultConfig, type Store } from "../src/gateA/gateA.js";
import type { ChainIO, FrameIO, FrameReceipt } from "../src/gateA/io.js";
import { accountAbi } from "../src/gateA/abis.js";
import { attacks, crash, replace, reputation, uniswapBalances, OFFICIAL_POOL_MANAGER, type SceneDeps } from "../src/scenes/phaseB.js";
import type { EthrexSimResult } from "../src/sim.js";

const A = (n: number) => `0x${n.toString(16).padStart(40, "0")}` as Address;
const C = {
  WETH: A(1), USDC: A(2), RoundFeed: A(3), HegotaFrameEnv: A(4), AutolysisAccount: A(5), AutolysisMarket: A(6),
  PoolManager: OFFICIAL_POOL_MANAGER, BackstopHook: A(8), V4Venue: A(9),
};
const WAD = 10n ** 18n;
const VERIFY = frameMode(profile, "VERIFY");

class World {
  deployed = false;
  stake = 0n;
  storageOnly = false;
  feeCap = 10n ** 15n;
  accountEth = 0n;
  nextPos = 1n;
  openPrice = new Map<bigint, bigint>();
  liquidated = new Set<bigint>();
  rounds: { price: bigint; timestamp: bigint }[] = [{ price: 2n * WAD, timestamp: 1_000n }];
  writes: string[] = [];
  seen = 0;
  included = 0;
  price = () => this.rounds[this.rounds.length - 1].price;
  hf = (id: bigint) => (this.liquidated.has(id) ? 105n * 10n ** 16n : (this.price() * 8n * WAD) / (10n * ((this.openPrice.get(id) ?? 2n * WAD) * 3n / 4n)));
}

function chainOf(w: World): ChainIO {
  let n = 0;
  const tx = (what: string) => {
    w.writes.push(what);
    return { hash: toHex(++n, { size: 32 }), status: "success" as const, gasUsed: 21_000n };
  };
  return {
    deployer: A(0xd0),
    chainId: async () => 1337,
    balance: async (a) => (a === C.AutolysisAccount ? w.accountEth : 10n ** 19n),
    code: async () => (w.deployed ? "0x60" : "0x") as Hex,
    storageAt: async () => "0x0" as Hex,
    read: async <T,>(_a: Address, _abi: unknown, fn: string, args: readonly unknown[] = []) => {
      const id = args[0] as bigint;
      const r: Record<string, () => unknown> = {
        getDepositInfo: () => [w.stake, w.stake > 0n ? 86_400 : 0, 0n],
        stakingRegistry: () => (w.stake > 0n ? defaultConfig(1337, "").registry : A(0)),
        feeCapTotal: () => w.feeCap,
        nextPositionId: () => w.nextPos,
        positions: () => [A(0xd0), 10n ** 17n, 15n * 10n ** 16n, w.liquidated.has(id) ? 1n : 0n],
        latestRound: () => BigInt(w.rounds.length),
        getRound: () => w.rounds[Number(id) - 1],
        healthFactor: () => w.hf(id),
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
      if (fn === "open") w.openPrice.set(w.nextPos++, w.price());
      if (fn === "post") w.rounds.push({ price: args[0] as bigint, timestamp: 1_000n });
      return tx(fn);
    },
    send: async (_to, value) => {
      w.accountEth += value;
      return tx("send");
    },
  };
}

const posOf = (tx: FrameTx) => BigInt(`0x${tx.frames[1].data.slice(10, 74)}`);
const roundOf = (tx: FrameTx) => BigInt(`0x${tx.frames[1].data.slice(74, 138)}`);
const limits = (tx: FrameTx) => tx.frames.reduce((s, f) => s + f.limits.execution + f.limits.state, 0n);

/** VERIFY's verdict for `tx` (the subset of FirewallRules + the round gate the attacks exercise). */
function verdict(w: World, tx: FrameTx): string | null {
  if (tx.frames[0].mode !== VERIFY) return "Rejected(2)";
  if (!tx.frames[1].data.startsWith("0xf3ab9cad")) return "Rejected(5)";
  if (tx.nonceKeys.length !== 1) return "Rejected(12)";
  if (limits(tx) * tx.fees.maxFeePerGas > w.feeCap) return "Rejected(13)";
  if (roundOf(tx) + 4n <= BigInt(w.rounds.length)) return "StaleRound";
  if (w.hf(posOf(tx)) >= WAD) return "NotUnhealthy";
  return null;
}
const revertData = (v: string): Hex =>
  v.startsWith("Rejected")
    ? encodeErrorResult({ abi: accountAbi, errorName: "Rejected", args: [Number(v.slice(9, -1))] })
    : v === "NotUnhealthy"
      ? encodeErrorResult({ abi: accountAbi, errorName: "NotUnhealthy" })
      : "0x";

type Pending = { tx: FrameTx; status: "Pending" | "OnChain" | "Cancelled" };
function frameOf(w: World, o: { approveAttack?: string } = {}) {
  const pend = new Map<Hex, Pending>();
  const sent: FrameTx[] = [];
  const keyOf = (t: FrameTx) => `${t.nonceKeys.join(",")}:${t.nonceSeq}`;
  const io: FrameIO = {
    simulate: async (tx): Promise<EthrexSimResult> => {
      let v = verdict(w, tx);
      if (o.approveAttack && tx.frames[1].data.startsWith(o.approveAttack)) v = null;
      const gas = w.storageOnly ? 50_414 : 71_822;
      return {
        canonicalMempoolValid: false, canonicalMempoolViolation: "StorageReadNonSender",
        maxCost: toHex(limits(tx) * tx.fees.maxFeePerGas), gasUsed: null,
        frames: [{ gasUsed: toHex(gas), succeeded: v === null }, { gasUsed: "0x927c0", succeeded: true }],
        executionStatus: v ? "reverted" : "success", executionError: null,
        ...(v ? { failedFrameIndex: 0, haltReason: "revert", revertData: revertData(v) } : {}),
      };
    },
    sendRaw: async () => ({ ok: false, text: '{"jsonrpc":"2.0","id":1,"error":{"code":-32000,"message":"StorageReadNonSender"}}', error: { code: -32000, message: "StorageReadNonSender" } }),
    sendFrame: async (tx) => {
      sent.push(tx);
      const v = verdict(w, tx);
      if (v) throw new Error(`eth_sendFrameTransaction rejected: {"error":{"code":-32500,"message":"validation prefix frame reverted: ${v}"}}`);
      const prior = [...pend.entries()].find(([, p]) => p.status === "Pending" && keyOf(p.tx) === keyOf(tx));
      if (prior) {
        const bumped = tx.fees.maxFeePerGas * 10n >= prior[1].tx.fees.maxFeePerGas * 11n && tx.fees.maxPriorityFeePerGas * 10n >= prior[1].tx.fees.maxPriorityFeePerGas * 11n;
        if (!bumped) throw new Error('eth_sendFrameTransaction rejected: {"error":{"message":"replacement underpriced"}}');
        prior[1].status = "Cancelled";
      }
      w.seen++;
      const h = keccak256(toHex(`${keyOf(tx)}:${tx.fees.maxFeePerGas}:${roundOf(tx)}`));
      pend.set(h, { tx, status: "Pending" });
      return h;
    },
    status: async (h) => ({ status: pend.get(h)?.status ?? null }),
    receipt: async (h): Promise<FrameReceipt | null> => {
      const p = pend.get(h);
      if (!p || p.status === "Cancelled") return null;
      if (p.status === "Pending") {
        p.status = "OnChain";
        w.liquidated.add(posOf(p.tx));
        w.included++;
      }
      return {
        status: "0x1", frameReceipts: [{ status: "0x1" }, { status: "0x1" }],
        logs: [{ address: C.AutolysisAccount, topics: [encodeEventTopics({ abi: accountAbi, eventName: "LiquidationOk" })[0], pad(numberToHex(posOf(p.tx)), { size: 32 })], data: "0x" }],
      };
    },
    reputation: async () => ({ items: [{ address: C.AutolysisAccount, opsSeen: w.seen, opsIncluded: w.included, status: "ok", isStaked: true }] }),
  };
  return { io, sent };
}

function memStore(): Store & { state: Record<string, any> } {
  const s = { state: {} as Record<string, any> } as Store & { state: Record<string, any> };
  s.load = () => structuredClone(s.state);
  s.save = (x) => void (s.state = structuredClone(x));
  return s;
}

async function setup(o: { approveAttack?: string } = {}) {
  const w = new World();
  const store = memStore();
  const f = frameOf(w, o);
  const cfg = { ...defaultConfig(1337, "https://explorer.altmempool.wtf/"), pollMs: 0, receiptTimeoutMs: 20 };
  const files: Record<string, string> = {};
  const chain = chainOf(w);
  await runGateA({
    chain, frame: f.io, store, cfg, sleep: async () => {},
    deploy: async () => ((w.deployed = true), C), now: () => new Date(1_000_000_000),
  });
  f.sent.length = 0;
  const deps: SceneDeps = { chain, frame: f.io, store, cfg, sleep: async () => {}, writeFile: (p, c) => void (files[p] = c) };
  return { w, store, deps, sent: f.sent, files };
}

describe("Phase B scenes", () => {
  it("refuse to run before Gate A passed", async () => {
    const w = new World();
    const deps: SceneDeps = { chain: chainOf(w), frame: frameOf(w).io, store: memStore(), cfg: defaultConfig(1337, "") };
    await expect(crash(deps)).rejects.toThrow(/just gate-a/);
  });

  it("crash: 12 positions on 12 keys, canonical then alt for each, all 12 included", async () => {
    const h = await setup();
    const r = await crash(h.deps);
    expect(r.items).toHaveLength(12);
    expect(new Set(h.sent.map((t) => t.nonceKeys[0])).size).toBe(12);
    expect(r.items.every((i: any) => i.canonical.responseText.includes("StorageReadNonSender"))).toBe(true);
    expect(r.summary).toMatchObject({ positions: 12, canonicalAccepted: 0, altAdmitted: 12, included: 12, liquidationOk: 12 });
    expect(r.reputationAfter.opsIncluded - r.reputationBefore.opsIncluded).toBe(12);
    expect(r.ok).toBe(true);
    expect(r.precheck.items).toHaveLength(12);
    expect(r.precheck.items.every((p: any) => p.ok && p.verifyGasUsed + 100 <= p.verifyLimit)).toBe(true);
    expect(r.precheck.balanceCovers).toBe(true);
    expect(h.store.state.reputation.snapshots.map((s: any) => s.label)).toEqual(["crash-before", "crash-after"]);
  });

  it("crash: a failing pre-check sends nothing", async () => {
    const h = await setup();
    const sim = h.deps.frame.simulate;
    h.deps.frame.simulate = async (tx) => ({ ...(await sim(tx)), frames: [{ gasUsed: "0x1869c", succeeded: true }, { gasUsed: "0x927c0", succeeded: true }] }); // 99,996 + 100 > 99,900
    await expect(crash(h.deps)).rejects.toThrow(/pre-check failed, nothing sent/);
    expect(h.sent).toHaveLength(0);
  });

  it("replace: same key + sequence, both fees +10%, newer round -> the new tx is included, the old is cancelled", async () => {
    const h = await setup();
    const r = await replace(h.deps);
    const [t1, t2] = h.sent;
    expect(t2.nonceKeys).toEqual(t1.nonceKeys);
    expect(t2.nonceSeq).toBe(t1.nonceSeq);
    expect(t2.fees.maxFeePerGas * 10n).toBeGreaterThanOrEqual(t1.fees.maxFeePerGas * 11n);
    expect(t2.fees.maxPriorityFeePerGas * 10n).toBeGreaterThanOrEqual(t1.fees.maxPriorityFeePerGas * 11n);
    expect(roundOf(t2)).toBeGreaterThan(roundOf(t1));
    expect(r.statusFinal.old).toEqual({ status: "Cancelled" });
    expect(r.newIncluded).toBe(true);
    expect(r.ok).toBe(true);
  });

  it("attacks: each of the 5 is rejected, with the decoded VERIFY reason and the exact send text", async () => {
    const h = await setup();
    const r = await attacks(h.deps);
    expect(Object.keys(r.items).sort()).toEqual(["appendedKey", "feeOverCap", "frame0WrongMode", "staleRound", "wrongSelector"]);
    expect(r.items.appendedKey.simulate.decoded).toBe("Rejected(SECOND_KEY)");
    expect(r.items.wrongSelector.simulate.decoded).toBe("Rejected(EXEC_SELECTOR)");
    expect(r.items.feeOverCap.simulate.decoded).toBe("Rejected(FEE_CAP)");
    expect(r.items.frame0WrongMode.simulate.decoded).toBe("Rejected(VERIFY_FRAME)");
    expect(r.items.staleRound.send.error).toContain("StaleRound");
    expect(Object.values(r.items).every((i: any) => i.rejected && i.send.error.startsWith("eth_sendFrameTransaction rejected:"))).toBe(true);
    expect(r.ok).toBe(true);
  });

  it("attacks: an attack VERIFY would approve is never broadcast and fails the scene", async () => {
    const h = await setup({ approveAttack: "0xdeadbeef" });
    const r = await attacks(h.deps);
    expect(r.items.wrongSelector.rejected).toBe(false);
    expect(r.items.wrongSelector.send).toBeUndefined();
    expect(h.sent.some((t) => t.frames[1].data.startsWith("0xdeadbeef"))).toBe(false);
    expect(r.ok).toBe(false);
  });

  it("uniswap-balances: table from gate-a's before/after, through the official PoolManager, hook holds nothing", async () => {
    const h = await setup();
    const r = await uniswapBalances(h.deps);
    expect(r.officialPoolManager).toBe(true);
    expect(r.hookHoldsNothing).toBe(true);
    expect(r.markdown).toContain(OFFICIAL_POOL_MANAGER);
    expect(r.markdown).toContain("| Hook ERC-6909 claims USDC |");
    expect(h.files["deployments/uniswap-balances-1337.md"]).toBe(r.markdown + "\n");
    expect(r.ok).toBe(true);
  });

  it("reputation: labelled snapshots accumulate and feed the measured EXO-010 series", async () => {
    const h = await setup();
    await reputation(h.deps, "before");
    await crash(h.deps);
    await reputation(h.deps, "after");
    const m = JSON.parse(h.files["kit/out/exo010-measured.json"]);
    expect(m.source).toContain("skandha_explorer_listReputation");
    expect(m.snapshots.map((s: any) => s.label)).toEqual(["before", "crash-before", "crash-after", "after"]);
    expect(m.snapshots.at(-1).opsIncluded - m.snapshots[0].opsIncluded).toBe(12);
  });
});

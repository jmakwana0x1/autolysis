// `just gate-a`: Phase A on the devnet in one unattended, idempotent run (PLAN-v4.4 A2-A7).
//   preflight -> deploy (USE_PREDEPLOYED_V4 on 1337) -> stake 0.012 ETH -> fund + fee cap -> seed 2 positions
//   -> crash rounds -> VERIFY snapshots -> simulate BOTH VERIFY paths, choose by the A5 rule
//   -> canonical-mempool attempt (exact response saved) -> alt-mempool liquidation -> receipt + balances.
// Every step first checks chain state and skips work already done, records hashes/gas/balances into
// deployments/<chainId>.json under `gateA`, and the run stops on the first error with its exact text.
import { concat, encodeEventTopics, keccak256, numberToHex, pad, type Address, type Hex } from "viem";
import { profile } from "@forshtat/hegota-support/profiles/ethrex-eip8141-tracer";
import { txHash, type FrameTx } from "@forshtat/hegota-support/tx";
import { canonicalLiquidationTx, nonceKeyFor } from "../frameTx.js";
import { choosePath, rawFrameTx, summarize, type SimSummary } from "../sim.js";
import type { ChainIO, DeployFn, FrameIO, FrameReceipt } from "./io.js";
import { accountAbi, erc20Abi, feedAbi, hookAbi, marketAbi, poolManagerAbi, registryAbi, wethAbi } from "./abis.js";

export const DEVNET_REGISTRY: Address = "0xD51c04d7A0B01124E84DE152F4e56d9eeCB22D2F";
export const NONCE_MANAGER = profile.predeploys!.NONCE_MANAGER as Address;
const FIRST_USE_KEY_STATE_GAS = 97_920n; // deployments/probes.json firstUseKeyStateGas
const WAD = 10n ** 18n;

export type GateAConfig = {
  chainId: number;
  explorerUrl: string;
  registry: Address;
  stakeWei: bigint;
  unstakeDelaySec: number;
  minStakeWei: bigint;
  minDeployerWei: bigint;
  accountFundWei: bigint;
  feeCapWei: bigint;
  collateralPerPositionWei: bigint;
  marketUsdc: bigint;
  houseUsdc: bigint;
  maxFeePerGas: bigint;
  verifyGasLimit: bigint;
  verifyStateLimit: bigint;
  executeGasLimit: bigint;
  executeStateLimit: bigint;
  verifyMargin: number;
  receiptTimeoutMs: number;
  pollMs: number;
  maxRoundAgeSec: bigint;
};

export const defaultConfig = (chainId: number, explorerUrl: string): GateAConfig => ({
  chainId,
  explorerUrl,
  registry: DEVNET_REGISTRY,
  stakeWei: 12n * 10n ** 15n, // 0.012 ETH
  unstakeDelaySec: 86_400,
  minStakeWei: 10n ** 16n, // the sidecar's minStake, 0.01 ETH
  minDeployerWei: 10n ** 17n, // 0.1 ETH: stake + account float + 2 x 0.1 WETH collateral + gas
  accountFundWei: 5n * 10n ** 16n, // 0.05 ETH: the account self-pays (pending gas must fit its balance)
  feeCapWei: 10n ** 16n, // 0.01 ETH MAX_COST ceiling VERIFY accepts
  collateralPerPositionWei: 10n ** 17n, // 0.1 ETH-backed WETH per position (the fee path unwraps WETH)
  marketUsdc: 1_000n * WAD,
  houseUsdc: 1_000n * WAD,
  maxFeePerGas: 2_000_000_000n, // 2 gwei, the workshop's frame-tx maxFeePerGas
  verifyGasLimit: 99_900n, // MAX_VERIFY_GAS 100,000 - ARBITRARY signature 100
  verifyStateLimit: FIRST_USE_KEY_STATE_GAS + 50_000n,
  executeGasLimit: 1_500_000n,
  executeStateLimit: 500_000n,
  verifyMargin: 3_000,
  receiptTimeoutMs: 180_000,
  pollMs: 3_000,
  maxRoundAgeSec: 1_800n, // RoundFeed.MAX_AGE is 1 h; refresh a round older than 30 min
});

export type Store = { load(): Record<string, any>; save(state: Record<string, any>): void };
export type Log = (msg: string) => void;
export type Deps = {
  chain: ChainIO;
  frame: FrameIO;
  deploy: DeployFn;
  store: Store;
  cfg: GateAConfig;
  log?: Log;
  sleep?: (ms: number) => Promise<void>;
  now?: () => Date;
};

export class GateAError extends Error {
  constructor(readonly step: string, message: string) {
    super(message);
  }
}

const REQUIRED_CONTRACTS = [
  "WETH", "USDC", "RoundFeed", "HegotaFrameEnv", "AutolysisAccount", "AutolysisMarket", "PoolManager",
  "BackstopHook", "V4Venue",
] as const;

/** Per-run fields, cleared when a devnet reset forces a redeploy. */
const RUN_FIELDS = ["positions", "liquidationTarget", "round", "verify", "canonical", "liquidation", "result", "reputationAfter"];

const big = (v: unknown) => (typeof v === "bigint" ? v.toString() : v);
const jsonSafe = (o: unknown): unknown => JSON.parse(JSON.stringify(o, (_k, v) => big(v)));

export const keyedNonceSlot = (sender: Address, key: bigint): Hex =>
  keccak256(concat([pad(sender, { size: 32 }), numberToHex(key, { size: 32 })]));

export async function runGateA(d: Deps): Promise<Record<string, any>> {
  const log = d.log ?? (() => {});
  const sleep = d.sleep ?? ((ms) => new Promise((r) => setTimeout(r, ms)));
  const now = d.now ?? (() => new Date());
  const { chain, frame, cfg } = d;
  const state = d.store.load();
  state.chainId = cfg.chainId;
  state.contracts ??= {};
  state.gateA ??= {};
  const g = state.gateA as Record<string, any>;
  g.steps ??= {};
  delete g.failed;
  const save = () => {
    g.updatedAt = now().toISOString();
    d.store.save(jsonSafe(state) as Record<string, any>);
  };
  const C = () => state.contracts as Record<string, Address>;

  const step = async (name: string, fn: () => Promise<Record<string, unknown> | void>) => {
    log(`[gate-a] ${name} ...`);
    try {
      const out = (await fn()) ?? {};
      g.steps[name] = { ...(g.steps[name] ?? {}), ...out, ok: true, at: now().toISOString() };
      save();
      log(`[gate-a] ${name} ok${out.skipped ? " (already done)" : ""}`);
    } catch (e) {
      const message = e instanceof Error ? e.message : String(e);
      g.failed = { step: name, error: message, at: now().toISOString() };
      save();
      throw new GateAError(name, message);
    }
  };

  // ---------------------------------------------------------------------------------------- preflight
  await step("preflight", async () => {
    const id = await chain.chainId();
    if (id !== cfg.chainId) throw new Error(`RPC chain id is ${id}, expected ${cfg.chainId}`);
    const bal = await chain.balance(chain.deployer);
    g.deployer = chain.deployer;
    if (bal < cfg.minDeployerWei && !g.steps.liquidate?.ok) {
      throw new Error(`deployer ${chain.deployer} holds ${bal} wei; needs >= ${cfg.minDeployerWei} (fund it from the faucet)`);
    }
    return { deployerBalanceWei: bal };
  });

  // ------------------------------------------------------------------------------------------- deploy
  await step("deploy", async () => {
    const have = C();
    if (REQUIRED_CONTRACTS.every((k) => have[k])) {
      const codes = await Promise.all(REQUIRED_CONTRACTS.map((k) => chain.code(have[k])));
      if (codes.every((c) => c && c !== "0x")) return { skipped: true };
      log("[gate-a] recorded contracts have no code (devnet reset?) - redeploying");
      for (const k of Object.keys(g.steps)) if (k !== "preflight") delete g.steps[k];
      for (const k of RUN_FIELDS) delete g[k];
    }
    const addrs = await d.deploy({ usePredeployedV4: cfg.chainId === 1337 });
    for (const k of REQUIRED_CONTRACTS) {
      if (!addrs[k]) throw new Error(`deploy wrote no address for ${k}`);
      const code = await chain.code(addrs[k]);
      if (!code || code === "0x") throw new Error(`deployed ${k} at ${addrs[k]} has no code`);
    }
    state.contracts = { ...addrs };
    return { contracts: addrs };
  });
  const account = C().AutolysisAccount;
  const market = C().AutolysisMarket;

  // -------------------------------------------------------------------------------------------- stake
  await step("stake", async () => {
    const regCode = await chain.code(cfg.registry);
    if (!regCode || regCode === "0x") throw new Error(`no staking registry code at ${cfg.registry}`);
    const info = async () => {
      const [stake, delay, withdrawTime] = await chain.read<[bigint, number, bigint]>(cfg.registry, registryAbi, "getDepositInfo", [account]);
      return { stake, unstakeDelaySec: Number(delay), withdrawTime };
    };
    const staked = (i: Awaited<ReturnType<typeof info>>) =>
      i.stake >= cfg.minStakeWei && i.unstakeDelaySec >= cfg.unstakeDelaySec && i.withdrawTime === 0n;
    let i = await info();
    const out: Record<string, unknown> = {};
    if (!staked(i)) {
      const cur = await chain.read<Address>(account, accountAbi, "stakingRegistry");
      if (cur.toLowerCase() !== cfg.registry.toLowerCase()) {
        out.setRegistryTx = (await chain.write(account, accountAbi, "setStakingRegistry", [cfg.registry])).hash;
      }
      const t = await chain.write(account, accountAbi, "stake", [cfg.unstakeDelaySec], cfg.stakeWei);
      out.stakeTx = t.hash;
      i = await info();
      if (!staked(i)) throw new Error(`stake tx ${t.hash} mined but getDepositInfo(${account}) = ${JSON.stringify(jsonSafe(i))}`);
    } else {
      out.skipped = true;
    }
    out.depositInfo = i;
    out.reputation = findEntry(await frame.reputation(), account);
    return out;
  });

  // -------------------------------------------------------------------------------- fund + fee cap
  await step("fund", async () => {
    const out: Record<string, unknown> = {};
    const bal = await chain.balance(account);
    if (bal < cfg.accountFundWei) out.fundTx = (await chain.send(account, cfg.accountFundWei - bal)).hash;
    const cap = await chain.read<bigint>(account, accountAbi, "feeCapTotal");
    if (cap < cfg.feeCapWei) out.feeCapTx = (await chain.write(account, accountAbi, "setFeeCap", [cfg.feeCapWei])).hash;
    out.accountBalanceWei = await chain.balance(account);
    out.feeCapWei = await chain.read<bigint>(account, accountAbi, "feeCapTotal");
    if (!out.fundTx && !out.feeCapTx) out.skipped = true;
    return out;
  });

  // --------------------------------------------------------------------------------------------- seed
  await step("seed", async () => {
    const recorded: string[] = g.positions ?? [];
    if (recorded.length === 2) {
      const owners = await Promise.all(
        recorded.map(async (id) => (await chain.read<[Address]>(market, marketAbi, "positions", [BigInt(id)]))[0]),
      );
      if (owners.every((o) => o.toLowerCase() === chain.deployer.toLowerCase())) return { skipped: true };
    }
    const { USDC, WETH, BackstopHook } = C();
    const txs: Record<string, Hex> = {};
    txs.marketLiquidity = (await chain.write(USDC, erc20Abi, "mint", [market, cfg.marketUsdc])).hash;
    txs.houseMint = (await chain.write(USDC, erc20Abi, "mint", [chain.deployer, cfg.houseUsdc])).hash;
    txs.houseApprove = (await chain.write(USDC, erc20Abi, "approve", [BackstopHook, cfg.houseUsdc])).hash;
    txs.houseDeposit = (await chain.write(BackstopHook, hookAbi, "deposit", [USDC, cfg.houseUsdc])).hash;
    // ETH-backed collateral: the gas fee path unwraps WETH, so minted (unbacked) WETH would revert it.
    txs.wrap = (await chain.write(WETH, wethAbi, "deposit", [], 2n * cfg.collateralPerPositionWei)).hash;
    txs.approveMarket = (await chain.write(WETH, wethAbi, "approve", [market, 2n ** 256n - 1n])).hash;
    const ids: string[] = [];
    for (let k = 0; k < 2; k++) {
      const id = await chain.read<bigint>(market, marketAbi, "nextPositionId");
      txs[`open${k}`] = (await chain.write(market, marketAbi, "open")).hash;
      txs[`deposit${k}`] = (await chain.write(market, marketAbi, "deposit", [id, cfg.collateralPerPositionWei])).hash;
      // 1.5 debt per collateral at price 2, L = 0.8 -> HF 1.0667 (the local tests' position).
      txs[`borrow${k}`] = (await chain.write(market, marketAbi, "borrow", [id, (cfg.collateralPerPositionWei * 3n) / 2n])).hash;
      ids.push(id.toString());
    }
    g.positions = ids;
    g.liquidationTarget = ids[0];
    delete g.steps.canonical;
    delete g.steps.liquidate;
    return { positions: ids, txs };
  });
  const positions: bigint[] = (g.positions as string[]).map(BigInt);
  // Once Gate A passed, the target position is healthy again: never post new down-rounds against it.
  const passed = g.result === "passed" && g.liquidation?.outcome === "LiquidationOk";
  if (passed) {
    log(`[gate-a] already passed: liquidation ${g.liquidation.hash} (rerun after a devnet reset redeploys)`);
    return state;
  }

  // -------------------------------------------------------------------------------------------- crash
  await step("crash", async () => {
    const { RoundFeed } = C();
    const target = BigInt(g.liquidationTarget);
    const posted: { round: string; price: string; tx: Hex }[] = [];
    const latest = async () => {
      const id = await chain.read<bigint>(RoundFeed, feedAbi, "latestRound");
      const r = await chain.read<{ price: bigint; timestamp: bigint }>(RoundFeed, feedAbi, "getRound", [id]);
      return { id, price: r.price, timestamp: r.timestamp };
    };
    let l = await latest();
    const nowSec = BigInt(Math.floor(now().getTime() / 1000));
    if (nowSec > l.timestamp + cfg.maxRoundAgeSec) {
      const t = await chain.write(RoundFeed, feedAbi, "post", [l.price]); // fresh round, same price
      posted.push({ round: (l.id + 1n).toString(), price: l.price.toString(), tx: t.hash });
      l = await latest();
    }
    for (let k = 0; k < 6 && (await chain.read<bigint>(market, marketAbi, "healthFactor", [target])) >= WAD; k++) {
      const next = (l.price * 9n) / 10n; // -10%: exactly RoundFeed.MAX_MOVE_BPS, stays in band
      const t = await chain.write(RoundFeed, feedAbi, "post", [next]);
      l = await latest();
      posted.push({ round: l.id.toString(), price: next.toString(), tx: t.hash });
    }
    const hf = await chain.read<bigint>(market, marketAbi, "healthFactor", [target]);
    if (hf >= WAD) throw new Error(`position ${target} still healthy (HF ${hf}) after ${posted.length} down-rounds`);
    g.round = l.id.toString();
    return { round: g.round, price: l.price, targetHf: hf, posted, skipped: posted.length === 0 };
  });
  const round = BigInt(g.round);

  // ---------------------------------------------------------------------------------------- snapshots
  await step("snapshot", async () => {
    if (g.steps.snapshot?.ok && g.steps.snapshot.round === round.toString()) return { skipped: true };
    const txs: Record<string, Hex> = {};
    for (const id of positions) {
      txs[id.toString()] = (await chain.write(account, accountAbi, "pushVerifySnapshot", [id, round])).hash;
    }
    return { round: round.toString(), txs };
  });

  // --------------------------------------------------------------------------------------- build tx
  const buildTx = async (positionId: bigint): Promise<FrameTx> => {
    const key = nonceKeyFor(market, positionId);
    const sequence = BigInt(await chain.storageAt(NONCE_MANAGER, keyedNonceSlot(account, key)));
    return canonicalLiquidationTx({
      chainId: cfg.chainId, account, market, positionId, roundId: round, sequence,
      maxFeePerGas: cfg.maxFeePerGas, verifyGas: cfg.verifyGasLimit, verifyStateLimit: cfg.verifyStateLimit,
      executeGas: cfg.executeGasLimit, executeStateLimit: cfg.executeStateLimit, signatureForm: "arbitrary",
    });
  };
  const setPath = async (storageOnly: boolean) => {
    const cur = await chain.read<boolean>(account, accountAbi, "storageOnlyVerify");
    return cur === storageOnly ? null : (await chain.write(account, accountAbi, "setStorageOnlyVerify", [storageOnly])).hash;
  };

  // ------------------------------------------------------------------------------- simulate + choose
  await step("simulate", async () => {
    const tx = await buildTx(BigInt(g.liquidationTarget));
    const runPath = async (storageOnly: boolean) => {
      const setTx = await setPath(storageOnly);
      const raw = await frame.simulate(tx);
      return { setTx, summary: summarize(raw), raw };
    };
    const outside = await runPath(false);
    const storage = await runPath(true);
    const choice = choosePath(outside.summary, storage.summary, cfg.verifyMargin);
    const rec = {
      positionId: g.liquidationTarget,
      outsideReads: { ...outside.summary, setPathTx: outside.setTx, raw: outside.raw },
      storageOnly: { ...storage.summary, setPathTx: storage.setTx, raw: storage.raw },
      rule: `VERIFY gasUsed + 100 <= ${100_000 - cfg.verifyMargin}, outside reads preferred`,
      chosen: choice.path,
      reason: choice.reason,
    };
    g.verify = rec;
    if (!choice.path) throw new Error(choice.reason);
    const chosen: SimSummary = choice.path === "outside-reads" ? outside.summary : storage.summary;
    const setTx = await setPath(choice.path === "storage-only");
    const cap = await chain.read<bigint>(account, accountAbi, "feeCapTotal");
    if (chosen.maxCost > cap) throw new Error(`simulated maxCost ${chosen.maxCost} exceeds the account fee cap ${cap}`);
    const bal = await chain.balance(account);
    if (chosen.maxCost > bal) throw new Error(`simulated maxCost ${chosen.maxCost} exceeds the account balance ${bal}`);
    return { chosen: choice.path, reason: choice.reason, finalPathTx: setTx, maxCostWei: chosen.maxCost };
  });

  // ------------------------------------------------------------------------- canonical-mempool attempt
  await step("canonical", async () => {
    if (g.canonical) return { skipped: true };
    const target = BigInt(g.liquidationTarget);
    const tx = await buildTx(target);
    const res = await frame.sendRaw(rawFrameTx(tx));
    g.canonical = {
      method: "eth_sendRawTransaction (0x06 raw, via the gateway, forwarded to ethrex)",
      positionId: target.toString(),
      path: g.verify?.chosen,
      accepted: res.ok,
      responseText: res.text,
      error: res.error ?? null,
      result: res.result ?? null,
    };
    if (res.ok) {
      // The canonical mempool admitted it: wait for that inclusion, then the alt-mempool liquidation
      // runs on the second position so both outcomes are recorded.
      const r = await waitReceipt(frame, res.result as Hex, cfg, sleep);
      g.canonical.receipt = r;
      g.canonical.included = receiptOk(r);
      const other = positions.find((p) => p !== target)!;
      g.liquidationTarget = other.toString();
    }
    return { accepted: res.ok };
  });

  // --------------------------------------------------------------------------- alt-mempool liquidation
  await step("liquidate", async () => {
    const L = (g.liquidation ??= {});
    if (L.receipt && receiptOk(L.receipt) && L.outcome === "LiquidationOk") return { skipped: true };
    const target = BigInt(g.liquidationTarget);
    if (!L.hash || L.positionId !== target.toString()) {
      const tx = await buildTx(target);
      L.positionId = target.toString();
      L.round = round.toString();
      L.localTxHash = txHash(profile, tx);
      L.before = await balances(chain, C(), target);
      L.hash = await frame.sendFrame(tx);
      L.sentAt = now().toISOString();
      save(); // record the hash before waiting, so a rerun polls it instead of resending
    }
    L.status = await frame.status(L.hash);
    const r = await waitReceipt(frame, L.hash, cfg, sleep);
    L.receipt = r;
    L.statusAfter = await frame.status(L.hash);
    if (!receiptOk(r)) throw new Error(`liquidation ${L.hash} mined but not every frame succeeded: ${JSON.stringify(r)}`);
    L.outcome = liquidationOutcome(r, account, target);
    L.after = await balances(chain, C(), target);
    L.explorer = { url: cfg.explorerUrl, search: L.hash };
    if (L.outcome !== "LiquidationOk") throw new Error(`liquidation ${L.hash} executed but the account emitted ${L.outcome}`);
    return { hash: L.hash, outcome: L.outcome };
  });

  g.reputationAfter = findEntry(await frame.reputation(), account);
  g.result = "passed";
  save();
  return state;
}

// ------------------------------------------------------------------------------------------- helpers

export function receiptOk(r: FrameReceipt | null | undefined): boolean {
  if (!r) return false;
  return r.status === "0x1" && (r.frameReceipts ?? []).every((f) => f.status === "0x1");
}

export async function waitReceipt(frame: FrameIO, hash: Hex, cfg: GateAConfig, sleep: (ms: number) => Promise<void>) {
  const deadline = Date.now() + cfg.receiptTimeoutMs;
  for (;;) {
    const r = await frame.receipt(hash);
    if (r) return r;
    if (Date.now() > deadline) {
      throw new Error(`no receipt for ${hash} after ${cfg.receiptTimeoutMs / 1000}s; status: ${JSON.stringify(await frame.status(hash))}`);
    }
    await sleep(cfg.pollMs);
  }
}

const OK_TOPIC = encodeEventTopics({ abi: accountAbi, eventName: "LiquidationOk" })[0];
const FAILED_TOPIC = encodeEventTopics({ abi: accountAbi, eventName: "LiquidationFailed" })[0];

export function liquidationOutcome(r: FrameReceipt, account: Address, positionId: bigint): string {
  const idTopic = pad(numberToHex(positionId), { size: 32 }).toLowerCase();
  for (const l of r.logs ?? []) {
    if (l.address.toLowerCase() !== account.toLowerCase()) continue;
    if (l.topics[1]?.toLowerCase() !== idTopic) continue;
    if (l.topics[0] === OK_TOPIC) return "LiquidationOk";
    if (l.topics[0] === FAILED_TOPIC) return "LiquidationFailed";
  }
  return "no LiquidationOk/LiquidationFailed log";
}

export function findEntry(listing: unknown, addr: Address): unknown {
  const rows: unknown[] = Array.isArray(listing)
    ? listing
    : ((listing as any)?.entries ?? (listing as any)?.items ?? (listing as any)?.reputation ?? []);
  const hit = rows.find((r: any) => JSON.stringify(r).toLowerCase().includes(addr.toLowerCase()));
  return hit ?? { listed: false, raw: listing };
}

export async function balances(chain: ChainIO, c: Record<string, Address>, positionId: bigint) {
  const [owner, collateral, debt, liquidations] = await chain.read<[Address, bigint, bigint, bigint]>(
    c.AutolysisMarket, marketAbi, "positions", [positionId],
  );
  const bal = (t: Address, who: Address) => chain.read<bigint>(t, erc20Abi, "balanceOf", [who]);
  return {
    position: { id: positionId.toString(), owner, collateral, debt, liquidations },
    healthFactor: await chain.read<bigint>(c.AutolysisMarket, marketAbi, "healthFactor", [positionId]),
    accountEth: await chain.balance(c.AutolysisAccount),
    marketUsdc: await bal(c.USDC, c.AutolysisMarket),
    marketWeth: await bal(c.WETH, c.AutolysisMarket),
    marketFeeBilledWei: await chain.read<bigint>(c.AutolysisMarket, marketAbi, "totalFeeBilled"),
    hookHouseUsdc: await chain.read<bigint>(c.BackstopHook, hookAbi, "depositsOf", [c.USDC]),
    hookUsdc: await bal(c.USDC, c.BackstopHook),
    hookWeth: await bal(c.WETH, c.BackstopHook),
    poolManagerUsdc: await bal(c.USDC, c.PoolManager),
    poolManagerWeth: await bal(c.WETH, c.PoolManager),
    hookClaimsUsdc: await chain.read<bigint>(c.PoolManager, poolManagerAbi, "balanceOf", [c.BackstopHook, BigInt(c.USDC)]),
    hookClaimsWeth: await chain.read<bigint>(c.PoolManager, poolManagerAbi, "balanceOf", [c.BackstopHook, BigInt(c.WETH)]),
    hookOwnerWeth: await bal(c.WETH, chain.deployer), // tier-2 collateral goes to the hook owner (the deployer)
    hookOwnerUsdc: await bal(c.USDC, chain.deployer),
  };
}

// Phase B scenes (PLAN-v4.4 B1-B5), one command each. They build on a passed `just gate-a` (contracts,
// stake, chosen VERIFY path in deployments/<chainId>.json) and record every exact response there under
// `scenes.<name>`. Each scene asserts its outcome and returns { ok, ... }; the runner exits 1 when !ok.
import { decodeErrorResult, type Address, type Hex } from "viem";
import { profile } from "@forshtat/hegota-support/profiles/ethrex-eip8141-tracer";
import { frameMode, type FrameTx } from "@forshtat/hegota-support/tx";
import { canonicalLiquidationTx, nonceKeyFor, SELFLIQ_SELECTOR, type CanonicalParams } from "../frameTx.js";
import { appendKey } from "../attacks.js";
import { rawFrameTx, summarize, type SimSummary } from "../sim.js";
import type { ChainIO, FrameIO, FrameReceipt } from "../gateA/io.js";
import {
  NONCE_MANAGER, balances, findEntry, keyedNonceSlot, liquidationOutcome, receiptOk, waitReceipt,
  type GateAConfig, type Store,
} from "../gateA/gateA.js";
import { REJECT_NAMES, accountAbi, erc20Abi, feedAbi, marketAbi, wethAbi } from "../gateA/abis.js";

export const OFFICIAL_POOL_MANAGER: Address = "0x6bF9Aa9c04fd001385742d61f6818C3236429848";
const WAD = 10n ** 18n;
const VERIFY_WINDOW = 4n; // RoundFeed.VERIFY_WINDOW

export type SceneDeps = {
  chain: ChainIO;
  frame: FrameIO;
  store: Store;
  cfg: GateAConfig;
  log?: (m: string) => void;
  sleep?: (ms: number) => Promise<void>;
  now?: () => Date;
  writeFile?: (relPath: string, content: string) => void; // repo-relative
};

type Ctx = SceneDeps & {
  state: Record<string, any>;
  c: Record<string, Address>;
  account: Address;
  market: Address;
  storageOnly: boolean;
  log: (m: string) => void;
  sleep: (ms: number) => Promise<void>;
  now: () => Date;
  save: () => void;
};

const jsonSafe = (o: unknown): any => JSON.parse(JSON.stringify(o, (_k, v) => (typeof v === "bigint" ? v.toString() : v)));

function context(d: SceneDeps): Ctx {
  const state = d.store.load();
  if (state.gateA?.result !== "passed") throw new Error("run `just gate-a` first: deployments has no passed Gate A");
  const c = state.contracts as Record<string, Address>;
  state.scenes ??= {};
  return {
    ...d,
    state,
    c,
    account: c.AutolysisAccount,
    market: c.AutolysisMarket,
    storageOnly: state.gateA.verify?.chosen === "storage-only",
    log: d.log ?? (() => {}),
    sleep: d.sleep ?? ((ms) => new Promise((r) => setTimeout(r, ms))),
    now: d.now ?? (() => new Date()),
    save: () => d.store.save(jsonSafe(state)),
  };
}

// --------------------------------------------------------------------------------------------- helpers

async function latestRound(x: Ctx) {
  const id = await x.chain.read<bigint>(x.c.RoundFeed, feedAbi, "latestRound");
  const r = await x.chain.read<{ price: bigint }>(x.c.RoundFeed, feedAbi, "getRound", [id]);
  return { id, price: r.price };
}

/** Open `n` ETH-backed positions at HF 1.0667 under the current price. */
async function seedPositions(x: Ctx, n: number, collateral: bigint): Promise<bigint[]> {
  const { price } = await latestRound(x);
  await x.chain.write(x.c.WETH, wethAbi, "deposit", [], collateral * BigInt(n));
  await x.chain.write(x.c.WETH, wethAbi, "approve", [x.market, 2n ** 256n - 1n]);
  const debt = (collateral * price * 3n) / (4n * WAD); // HF = 0.8 / 0.75 = 1.0667
  const ids: bigint[] = [];
  for (let i = 0; i < n; i++) {
    const id = await x.chain.read<bigint>(x.market, marketAbi, "nextPositionId");
    await x.chain.write(x.market, marketAbi, "open");
    await x.chain.write(x.market, marketAbi, "deposit", [id, collateral]);
    await x.chain.write(x.market, marketAbi, "borrow", [id, debt]);
    ids.push(id);
  }
  return ids;
}

/** One -10% round (exactly the band); every id must then be unhealthy. Returns the round. */
async function crashRound(x: Ctx, ids: bigint[]): Promise<{ round: bigint; tx: Hex }> {
  const { price } = await latestRound(x);
  const t = await x.chain.write(x.c.RoundFeed, feedAbi, "post", [(price * 9n) / 10n]);
  const { id } = await latestRound(x);
  for (const p of ids) {
    const hf = await x.chain.read<bigint>(x.market, marketAbi, "healthFactor", [p]);
    if (hf >= WAD) throw new Error(`position ${p} still healthy (HF ${hf}) after the crash round`);
  }
  return { round: id, tx: t.hash };
}

async function snapshots(x: Ctx, ids: bigint[], round: bigint) {
  if (!x.storageOnly) return {};
  const out: Record<string, Hex> = {};
  for (const p of ids) out[p.toString()] = (await x.chain.write(x.account, accountAbi, "pushVerifySnapshot", [p, round])).hash;
  return out;
}

async function params(x: Ctx, positionId: bigint, round: bigint, maxFeePerGas = x.cfg.maxFeePerGas): Promise<CanonicalParams> {
  const key = nonceKeyFor(x.market, positionId);
  const sequence = BigInt(await x.chain.storageAt(NONCE_MANAGER, keyedNonceSlot(x.account, key)));
  return {
    chainId: x.cfg.chainId, account: x.account, market: x.market, positionId, roundId: round, sequence, maxFeePerGas,
    verifyGas: x.cfg.verifyGasLimit, verifyStateLimit: x.cfg.verifyStateLimit, executeGas: x.cfg.executeGasLimit,
    executeStateLimit: x.cfg.executeStateLimit, signatureForm: "arbitrary",
  };
}

const totalLimits = (tx: FrameTx) => tx.frames.reduce((s, f) => s + f.limits.execution + f.limits.state, 0n);

/** Keep the self-paying account above `need` (pending gas must fit the payer's balance). */
async function topUp(x: Ctx, need: bigint) {
  const bal = await x.chain.balance(x.account);
  return bal >= need ? null : (await x.chain.send(x.account, need - bal)).hash;
}

async function sendFrameSafe(x: Ctx, tx: FrameTx): Promise<{ admitted: boolean; hash?: Hex; error?: string }> {
  try {
    return { admitted: true, hash: await x.frame.sendFrame(tx) };
  } catch (e) {
    return { admitted: false, error: (e as Error).message };
  }
}

async function receiptOrNull(x: Ctx, hash: Hex): Promise<FrameReceipt | null> {
  try {
    return await waitReceipt(x.frame, hash, x.cfg, x.sleep);
  } catch {
    return null;
  }
}

function revertName(revertData: unknown): string | null {
  if (typeof revertData !== "string" || revertData.length < 10) return null;
  try {
    const e = decodeErrorResult({ abi: accountAbi, data: revertData as Hex });
    return e.errorName === "Rejected" ? `Rejected(${REJECT_NAMES[Number(e.args[0])] ?? e.args[0]})` : e.errorName;
  } catch {
    return null;
  }
}

/** One page-walk of skandha_explorer_listReputation ({items, nextCursor}; sidecar modules/explorer.ts). */
export async function reputationSnapshot(frame: FrameIO, account: Address, label: string, at: string) {
  const listing = await frame.reputation();
  const entry = findEntry(listing, account) as Record<string, unknown>;
  return {
    label, at,
    listed: entry.listed !== false,
    opsSeen: (entry.opsSeen as number) ?? null,
    opsIncluded: (entry.opsIncluded as number) ?? null,
    status: (entry.status as string) ?? null,
    isStaked: (entry.isStaked as boolean) ?? null,
    raw: entry,
  };
}

// ---------------------------------------------------------------------------------------------- B1 crash

export async function crash(d: SceneDeps, n = 12) {
  const x = context(d);
  const rec: Record<string, any> = { startedAt: x.now().toISOString(), path: x.state.gateA.verify?.chosen };
  x.state.scenes.crash = rec;
  rec.reputationBefore = await reputationSnapshot(x.frame, x.account, "crash-before", x.now().toISOString());
  const ids = await seedPositions(x, n, 2n * 10n ** 16n); // 0.02 ETH each
  rec.positions = ids.map(String);
  const { round, tx } = await crashRound(x, ids);
  rec.round = round.toString();
  rec.roundTx = tx;
  rec.snapshots = await snapshots(x, ids, round);
  x.save();

  const txs = await Promise.all(ids.map(async (p) => canonicalLiquidationTx(await params(x, p, round))));
  const maxCost = totalLimits(txs[0]) * x.cfg.maxFeePerGas;
  rec.topUpTx = await topUp(x, (maxCost * BigInt(n) * 12n) / 10n);

  rec.items = [];
  for (let i = 0; i < n; i++) {
    const canon = await x.frame.sendRaw(rawFrameTx(txs[i]));
    const alt = await sendFrameSafe(x, txs[i]);
    rec.items.push({
      positionId: ids[i].toString(),
      canonical: { accepted: canon.ok, responseText: canon.text },
      alt,
    });
    x.save();
  }
  for (const it of rec.items) {
    const hash: Hex | undefined = it.alt.hash ?? (it.canonical.accepted ? JSON.parse(it.canonical.responseText).result : undefined);
    if (!hash) continue;
    const r = await receiptOrNull(x, hash);
    it.included = receiptOk(r);
    it.outcome = r ? liquidationOutcome(r, x.account, BigInt(it.positionId)) : "no receipt";
    it.block = r?.blockNumber ?? null;
    x.save();
  }
  rec.reputationAfter = await reputationSnapshot(x.frame, x.account, "crash-after", x.now().toISOString());
  x.state.reputation ??= { account: x.account, snapshots: [] };
  x.state.reputation.snapshots.push(rec.reputationBefore, rec.reputationAfter);
  rec.summary = {
    positions: n,
    canonicalAccepted: rec.items.filter((i: any) => i.canonical.accepted).length,
    altAdmitted: rec.items.filter((i: any) => i.alt.admitted).length,
    included: rec.items.filter((i: any) => i.included).length,
    liquidationOk: rec.items.filter((i: any) => i.outcome === "LiquidationOk").length,
  };
  rec.ok = rec.summary.liquidationOk === n;
  rec.finishedAt = x.now().toISOString();
  x.save();
  return rec;
}

// ------------------------------------------------------------------------------------------ B2 replace

export async function replace(d: SceneDeps) {
  const x = context(d);
  const rec: Record<string, any> = { startedAt: x.now().toISOString() };
  x.state.scenes.replace = rec;
  const [p] = await seedPositions(x, 1, 2n * 10n ** 16n);
  rec.positionId = p.toString();
  const r1 = await crashRound(x, [p]);
  // A second, newer round at the same price: both are inside the VERIFY window, the old tx cites r1.
  const { price } = await latestRound(x);
  const r2tx = (await x.chain.write(x.c.RoundFeed, feedAbi, "post", [price])).hash;
  const r2 = (await latestRound(x)).id;
  rec.rounds = { old: r1.round.toString(), new: r2.toString(), txs: [r1.tx, r2tx] };
  rec.snapshots = await snapshots(x, [p], r1.round);

  const fee1 = x.cfg.maxFeePerGas;
  const fee2 = (fee1 * 11n) / 10n + 1n; // both fee fields > +10% (the sidecar's replacement bump)
  const p1 = await params(x, p, r1.round, fee1);
  const p2 = await params(x, p, r2, fee2);
  const tx1 = canonicalLiquidationTx(p1);
  const tx2 = canonicalLiquidationTx(p2);
  rec.sameKeyAndSequence = tx1.nonceSeq === tx2.nonceSeq && tx1.nonceKeys[0] === tx2.nonceKeys[0];
  rec.fees = { old: { maxFeePerGas: fee1, maxPriorityFeePerGas: tx1.fees.maxPriorityFeePerGas }, new: { maxFeePerGas: fee2, maxPriorityFeePerGas: tx2.fees.maxPriorityFeePerGas } };
  await topUp(x, totalLimits(tx2) * fee2 * 3n);

  rec.old = await sendFrameSafe(x, tx1);
  if (x.storageOnly) rec.snapshotNew = (await x.chain.write(x.account, accountAbi, "pushVerifySnapshot", [p, r2])).hash;
  rec.new = await sendFrameSafe(x, tx2);
  rec.statusImmediately = {
    old: rec.old.hash ? await x.frame.status(rec.old.hash) : null,
    new: rec.new.hash ? await x.frame.status(rec.new.hash) : null,
  };
  x.save();
  const rNew = rec.new.hash ? await receiptOrNull(x, rec.new.hash) : null;
  rec.statusFinal = {
    old: rec.old.hash ? await x.frame.status(rec.old.hash) : null,
    new: rec.new.hash ? await x.frame.status(rec.new.hash) : null,
  };
  rec.oldReceipt = rec.old.hash ? await x.frame.receipt(rec.old.hash) : null;
  rec.newIncluded = receiptOk(rNew);
  rec.newOutcome = rNew ? liquidationOutcome(rNew, x.account, p) : "no receipt";
  rec.ok = rec.sameKeyAndSequence && rec.newIncluded && rec.newOutcome === "LiquidationOk" && !receiptOk(rec.oldReceipt);
  x.save();
  return rec;
}

// ------------------------------------------------------------------------------------------ B3 attacks

export type AttackName = "appendedKey" | "wrongSelector" | "feeOverCap" | "staleRound" | "frame0WrongMode";

export function buildAttacks(base: CanonicalParams, opts: { feeCap: bigint; staleRound: bigint }): Record<AttackName, FrameTx> {
  const canonical = canonicalLiquidationTx(base);
  const wrongSel = canonicalLiquidationTx(base);
  wrongSel.frames[1] = { ...wrongSel.frames[1], data: (`0xdeadbeef` + wrongSel.frames[1].data.slice(10)) as Hex };
  const overFee = (opts.feeCap / totalLimits(canonical) + 1n) * 2n; // maxCost ~2x the account's fee cap
  const wrongMode = canonicalLiquidationTx(base);
  wrongMode.frames[0] = { ...wrongMode.frames[0], mode: frameMode(profile, "DEFAULT") };
  return {
    appendedKey: appendKey(base, nonceKeyFor(base.market, base.positionId + 1n)),
    wrongSelector: wrongSel,
    feeOverCap: canonicalLiquidationTx({ ...base, maxFeePerGas: overFee }),
    staleRound: canonicalLiquidationTx({ ...base, roundId: opts.staleRound }),
    frame0WrongMode: wrongMode,
  };
}

export async function attacks(d: SceneDeps) {
  const x = context(d);
  const rec: Record<string, any> = { startedAt: x.now().toISOString() };
  x.state.scenes.attacks = rec;
  const [p] = await seedPositions(x, 1, 2n * 10n ** 16n);
  rec.positionId = p.toString();
  const { round } = await crashRound(x, [p]);
  // A stale round must be outside the K-round window: make sure K newer rounds exist (same price).
  let latest = (await latestRound(x)).id;
  while (latest < VERIFY_WINDOW + 1n) {
    await x.chain.write(x.c.RoundFeed, feedAbi, "post", [(await latestRound(x)).price]);
    latest = (await latestRound(x)).id;
  }
  const cited = (await latestRound(x)).id;
  rec.snapshots = await snapshots(x, [p], cited);
  const staleRound = cited - VERIFY_WINDOW;
  rec.rounds = { crash: round.toString(), cited: cited.toString(), stale: staleRound.toString() };
  const feeCap = await x.chain.read<bigint>(x.account, accountAbi, "feeCapTotal");
  const base = await params(x, p, cited);
  const built = buildAttacks(base, { feeCap, staleRound });
  rec.items = {};
  for (const [name, tx] of Object.entries(built) as [AttackName, FrameTx][]) {
    const raw = await x.frame.simulate(tx).catch((e: Error) => ({ error: e.message }) as any);
    const s: SimSummary | null = raw && !raw.error ? summarize(raw) : null;
    const item: Record<string, any> = {
      simulate: s ? { verifySucceeded: s.verifySucceeded, failure: s.failure, decoded: revertName(raw.revertData), canonicalViolation: s.canonicalViolation } : { error: raw?.error },
    };
    if (s?.verifySucceeded === true) {
      // VERIFY would approve this attack: never broadcast it. This is a firewall failure to fix.
      item.rejected = false;
      item.note = "VERIFY approved the mutated tx in simulate; NOT sent";
    } else {
      item.send = await sendFrameSafe(x, tx);
      item.rejected = !item.send.admitted;
      if (item.send.admitted) item.note = "the alt mempool ADMITTED the attack";
    }
    rec.items[name] = item;
    x.save();
  }
  rec.ok = Object.values(rec.items).every((i: any) => i.rejected === true);
  x.save();
  return rec;
}

// -------------------------------------------------------------------------------- B4 uniswap balances

export async function uniswapBalances(d: SceneDeps) {
  const x = context(d);
  const L = x.state.gateA.liquidation;
  if (!L?.before || !L?.after) throw new Error("gate-a recorded no before/after balances");
  const now = await balances(x.chain, x.c, BigInt(L.positionId));
  const official = x.c.PoolManager.toLowerCase() === OFFICIAL_POOL_MANAGER.toLowerCase();
  const rows: [string, string, string][] = [];
  const row = (label: string, key: string, sub?: string) => {
    const get = (b: any) => (sub ? b[key]?.[sub] : b[key]);
    rows.push([label, String(get(L.before) ?? "n/a"), String(get(L.after) ?? "n/a")]);
  };
  row("Borrower position collateral (WETH wei)", "position", "collateral");
  row("Borrower position debt (USDC wei)", "position", "debt");
  row("Health factor (WAD)", "healthFactor");
  row("PoolManager WETH", "poolManagerWeth");
  row("PoolManager USDC", "poolManagerUsdc");
  row("Hook WETH (tokens)", "hookWeth");
  row("Hook USDC (tokens)", "hookUsdc");
  row("Hook house deposits (USDC)", "hookHouseUsdc");
  row("Hook ERC-6909 claims WETH", "hookClaimsWeth");
  row("Hook ERC-6909 claims USDC", "hookClaimsUsdc");
  row("House (hook owner) WETH", "hookOwnerWeth");
  row("Account ETH (self-pay tank)", "accountEth");
  const md = [
    `Liquidation \`${L.hash}\` (position ${L.positionId}) through the ${official ? "official predeployed" : "NON-official"} PoolManager \`${x.c.PoolManager}\`.`,
    "",
    "| Balance | Before | After |",
    "| --- | ---: | ---: |",
    ...rows.map((r) => `| ${r[0]} | ${r[1]} | ${r[2]} |`),
  ].join("\n");
  const rec = {
    liquidation: L.hash, poolManager: x.c.PoolManager, officialPoolManager: official, rows,
    hookHoldsNothing: [now.hookWeth, now.hookClaimsWeth, now.hookClaimsUsdc].every((v) => v === 0n),
    current: now, markdown: md,
  };
  x.state.scenes.uniswapBalances = rec;
  x.save();
  d.writeFile?.(`deployments/uniswap-balances-${x.cfg.chainId}.md`, md + "\n");
  // The official-PoolManager proof is the devnet's (chain 1337); a local chain has a fresh manager.
  return { ...rec, ok: rec.hookHoldsNothing && (official || x.cfg.chainId !== 1337) };
}

// ------------------------------------------------------------------------------------- B5 reputation

/** Append a labelled skandha_explorer_listReputation snapshot of the account, and write the measured
 *  series the dashboard plots beside the EXO-010 simulation (kit/out/exo010-measured.json). */
export async function reputation(d: SceneDeps, label: string) {
  const x = context(d);
  x.state.reputation ??= { account: x.account, snapshots: [] };
  const snap = await reputationSnapshot(x.frame, x.account, label, x.now().toISOString());
  x.state.reputation.snapshots.push(snap);
  x.save();
  const measured = {
    source: "skandha_explorer_listReputation (live)",
    chainId: x.cfg.chainId,
    account: x.account,
    snapshots: x.state.reputation.snapshots.map(({ raw, ...s }: any) => s),
  };
  d.writeFile?.("kit/out/exo010-measured.json", JSON.stringify(measured, null, 2) + "\n");
  return { ok: snap.listed, snapshot: snap };
}

export { SELFLIQ_SELECTOR };

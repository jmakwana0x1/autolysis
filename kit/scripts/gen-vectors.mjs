#!/usr/bin/env node
// Generates 50,000 random liquidation cases with their TypeScript outputs into test/vectors/math.json.
// test/fuzz/Differential.t.sol reads them and asserts the Solidity library matches to the wei.
import { writeFileSync, mkdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { computeStep, healthFactor, closeFactor } from "../src/math.ts";

const root = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const N = Number(process.env.VECTORS ?? 50000);

// Deterministic PRNG (mulberry32) so vectors are reproducible.
let s = 0xa0704242 >>> 0;
function rnd() {
  s |= 0; s = (s + 0x6d2b79f5) | 0;
  let t = Math.imul(s ^ (s >>> 15), 1 | s);
  t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
  return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
}
function randRange(lo, hi) {
  // random bigint in [lo, hi]
  const span = hi - lo + 1n;
  // build ~128 bits of randomness
  let r = 0n;
  for (let i = 0; i < 4; i++) r = (r << 32n) | BigInt(Math.floor(rnd() * 4294967296));
  return lo + (r % span);
}

const cols = { c: [], p: [], lt: [], d: [], target: [], s: [], hf: [], cf: [], debt: [], sell: [], minOut: [] };
for (let i = 0; i < N; i++) {
  const c = randRange(1000000n, 10n ** 30n);
  const p = randRange(1000000n, 10n ** 30n);
  const lt = randRange(5n * 10n ** 17n, 90n * 10n ** 16n);
  const d = randRange(1000000n, 10n ** 30n);
  const target = randRange(101n * 10n ** 16n, 110n * 10n ** 16n);
  const sl = randRange(0n, 3n * 10n ** 16n); // 0..3% haircut
  const hf = healthFactor(c, p, lt, d);
  const step = computeStep(c, p, lt, d, target, sl);
  cols.c.push(c.toString()); cols.p.push(p.toString()); cols.lt.push(lt.toString());
  cols.d.push(d.toString()); cols.target.push(target.toString()); cols.s.push(sl.toString());
  cols.hf.push(hf.toString()); cols.cf.push(closeFactor(hf).toString());
  cols.debt.push(step.debtToRepay.toString()); cols.sell.push(step.collateralToSell.toString());
  cols.minOut.push(step.minOut.toString());
}
mkdirSync(join(root, "test/vectors"), { recursive: true });
writeFileSync(join(root, "test/vectors/math.json"), JSON.stringify({ count: N, ...cols }));
console.log(`wrote ${N} vectors to test/vectors/math.json`);

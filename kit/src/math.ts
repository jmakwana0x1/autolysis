// TypeScript port of src/libraries/LiquidationMath.sol. The differential test feeds the same random
// cases through this and the Solidity library and requires wei-identical output. Prices and ratios are
// WAD (1e18). `s` is the sale haircut the step prices against.
export const WAD = 10n ** 18n;
const HF_RAMP_TOP = WAD;
const HF_RAMP_BOTTOM = 95n * 10n ** 16n;
const CF_AT_TOP = 10n ** 17n;
const CF_AT_BOTTOM = WAD;

export function mulDiv(x: bigint, y: bigint, d: bigint): bigint {
  if (d === 0n) throw new Error("div by zero");
  return (x * y) / d;
}
export function mulDivUp(x: bigint, y: bigint, d: bigint): bigint {
  const r = mulDiv(x, y, d);
  return (x * y) % d !== 0n ? r + 1n : r;
}

export function healthFactor(c: bigint, p: bigint, lt: bigint, d: bigint): bigint {
  if (d === 0n) return (1n << 256n) - 1n;
  return mulDiv(mulDiv(mulDiv(c, p, WAD), lt, WAD), WAD, d);
}

export function closeFactor(hf: bigint): bigint {
  if (hf > HF_RAMP_TOP) return 0n;
  if (hf <= HF_RAMP_BOTTOM) return CF_AT_BOTTOM;
  const span = HF_RAMP_TOP - HF_RAMP_BOTTOM;
  const into = HF_RAMP_TOP - hf;
  return CF_AT_TOP + mulDiv(into, CF_AT_BOTTOM - CF_AT_TOP, span);
}

export function collateralForDebt(debtToRepay: bigint, price: bigint): bigint {
  if (price === 0n) throw new Error("TargetUnreachable");
  return mulDivUp(debtToRepay, WAD, price);
}

export function effectivePrice(price: bigint, s: bigint): bigint {
  return mulDiv(price, WAD - s, WAD);
}

function repayToReachTarget(c: bigint, p: bigint, lt: bigint, d: bigint, t: bigint, s: bigint): bigint {
  const weightedV = mulDiv(mulDiv(c, p, WAD), lt, WAD);
  const td = mulDiv(t, d, WAD);
  if (td <= weightedV) return 0n;
  const num = td - weightedV;
  const lOverOneMinusS = mulDiv(lt, WAD, WAD - s);
  const denom = t - lOverOneMinusS;
  return mulDivUp(num, WAD, denom);
}

export type Step = { debtToRepay: bigint; collateralToSell: bigint; minOut: bigint; insolvent: boolean };

export function computeStep(c: bigint, p: bigint, lt: bigint, d: bigint, t: bigint, s: bigint): Step {
  const empty: Step = { debtToRepay: 0n, collateralToSell: 0n, minOut: 0n, insolvent: false };
  if (p === 0n) throw new Error("TargetUnreachable");
  const hf = healthFactor(c, p, lt, d);
  if (hf >= HF_RAMP_TOP || d === 0n) return empty;

  const ps = effectivePrice(p, s);
  const insolvencyHf = mulDiv(lt, WAD, WAD - s);
  if (hf <= insolvencyHf) {
    const minOut = mulDiv(c, ps, WAD);
    const debtToRepay = minOut < d ? minOut : d;
    return { debtToRepay, collateralToSell: c, minOut, insolvent: debtToRepay < d };
  }

  const eligible = mulDiv(d, closeFactor(hf), WAD);
  let repay = repayToReachTarget(c, p, lt, d, t, s);
  if (repay > eligible) repay = eligible;
  if (repay > d) repay = d;

  let x = mulDivUp(repay, WAD, ps);
  if (x > c) {
    x = c;
    repay = mulDiv(x, ps, WAD);
  }
  return { debtToRepay: repay, collateralToSell: x, minOut: mulDiv(x, ps, WAD), insolvent: false };
}

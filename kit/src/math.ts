// TypeScript port of src/libraries/LiquidationMath.sol. The differential test (test/fuzz/Differential)
// feeds the same random cases through this and the Solidity library and requires wei-identical output.
export const WAD = 10n ** 18n;
const HF_RAMP_TOP = WAD;
const HF_RAMP_BOTTOM = 95n * 10n ** 16n; // 0.95e18
const CF_AT_TOP = 10n ** 17n; // 0.10e18
const CF_AT_BOTTOM = WAD;

// Full-width muldiv matches Solidity's; since JS BigInt is arbitrary precision we can divide directly.
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
  const collateralValue = mulDiv(c, p, WAD);
  const weighted = mulDiv(collateralValue, lt, WAD);
  return mulDiv(weighted, WAD, d);
}

export function closeFactor(hf: bigint): bigint {
  if (hf > HF_RAMP_TOP) return 0n;
  if (hf <= HF_RAMP_BOTTOM) return CF_AT_BOTTOM;
  const span = HF_RAMP_TOP - HF_RAMP_BOTTOM;
  const into = HF_RAMP_TOP - hf;
  const extra = mulDiv(into, CF_AT_BOTTOM - CF_AT_TOP, span);
  return CF_AT_TOP + extra;
}

export function collateralForDebt(debtToRepay: bigint, price: bigint): bigint {
  if (price === 0n) throw new Error("TargetUnreachable");
  return mulDivUp(debtToRepay, WAD, price);
}

function repayToReachTarget(c: bigint, p: bigint, lt: bigint, d: bigint, targetHf: bigint): bigint {
  const cv = mulDiv(mulDiv(c, p, WAD), lt, WAD);
  if (targetHf <= lt) return d;
  const rhs = mulDiv(targetHf, d, WAD);
  if (rhs <= cv) return 0n;
  const num = rhs - cv;
  const denom = targetHf - lt;
  return mulDivUp(num, WAD, denom);
}

export type Step = { debtToRepay: bigint; collateralToSell: bigint };

export function computeStep(c: bigint, p: bigint, lt: bigint, d: bigint, targetHf: bigint): Step {
  const hf = healthFactor(c, p, lt, d);
  if (hf >= HF_RAMP_TOP || d === 0n) return { debtToRepay: 0n, collateralToSell: 0n };

  const eligible = mulDiv(d, closeFactor(hf), WAD);
  const repayForTarget = repayToReachTarget(c, p, lt, d, targetHf);
  let repay = repayForTarget < eligible ? repayForTarget : eligible;
  if (repay > d) repay = d;

  let debtToRepay = repay;
  let collateralToSell = collateralForDebt(repay, p);
  if (collateralToSell > c) {
    collateralToSell = c;
    debtToRepay = mulDiv(c, p, WAD);
  }
  return { debtToRepay, collateralToSell };
}

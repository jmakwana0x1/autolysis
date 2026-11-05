# FEEDBACK.md — building on Uniswap v4

Notes from building the Autolysis `BackstopHook` on v4-core
(`bea7f6d1c11cd5dc4f0d5151ffa37a1c239feee6`).

## What worked well

- **Return-delta on `beforeSwap`** is exactly the right primitive for a backstop. Flagging a swap via
  `hookData` and returning a full `BeforeSwapDelta` lets the hook fill a registered liquidation from its
  own tier while any other swapper falls straight through to the concentrated-liquidity curve — the
  "outside swapper sees a normal pool" guarantee is one `ZERO_DELTA` return.
- **`CurrencySettler` with the claims flag** solved the one real footgun we hit (below) cleanly: taking
  the input leg as ERC-6909 claims instead of real tokens.

## Sharp edge: `manager.take` draws down pool reserves mid-swap

Mirroring the `CustomCurveHook` example (`manager.take(input)` then `output.settle`) underflowed for any
fill larger than the pool's current reserves of the input token. `take` transfers real tokens out of the
manager immediately, but in an exact-input swap the taker hasn't settled the input yet, so the manager
may not hold it. The fix was to resolve the input leg with `take(..., claims=true)` (i.e. `manager.mint`
of ERC-6909 claims) and only do a real transfer on the output leg from the hook's deposits.

Suggestion: the `CustomCurveHook` doc example could note that `manager.take` of the input leg only works
while the fill is within reserves, and point to the claims variant for hooks that source liquidity
themselves. It cost us a debugging cycle that the invariant "deltas net to zero" did not catch (the
unlock reverts for a different reason — reserve underflow — not an unbalanced delta).

## settle-before-swap is load-bearing and hard to assert directly

The unlock mechanism already enforces it: remove the `settle` and the unlock reverts with
`CurrencyNotSettled`, so a passing swap *is* the proof. We would have liked a cheaper way to assert
ordering in a unit test without a full mutation run; today it is an implicit property.

## Both currency orderings

Everything is symmetric once the hook reads input/output from `params.zeroForOne` against the sorted
`PoolKey`. We deploy and test pools with the collateral as `currency0` and as `currency1`; no code path
special-cases the ordering.

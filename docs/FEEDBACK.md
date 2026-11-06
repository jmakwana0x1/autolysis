# FEEDBACK.md: building on Uniswap v4

Notes from building the Autolysis `BackstopHook` (`src/backstop/BackstopHook.sol`) and `V4Venue` on
v4-core `bea7f6d1c11cd5dc4f0d5151ffa37a1c239feee6`, aimed at the official PoolManager predeployed on the
Hegota alt-mempool devnet (`0x6bF9Aa9c04fd001385742d61f6818C3236429848`). Everything below is friction we
actually hit, with what we did about it.

## What worked well

- **`beforeSwap` + `beforeSwapReturnDelta` is the right primitive for a backstop.** The hook fills a
  registered liquidation from its own tiers and returns the delta. Any other swapper gets `ZERO_DELTA`
  and sees the plain curve. "An outside swapper sees a normal pool" is one early return
  (`BackstopHook.sol:138`).
- **Authorizing on `sender` instead of `hookData`.** `sender` is the unlock caller (our venue), so the
  hook can check it against a registry. `hookData` is caller-chosen and carries only the "this is a
  liquidation" flag, so a liquidation cannot be faked by passing data.
- **Both currency orders just work** once input and output are read from `params.zeroForOne` against the
  sorted `PoolKey`. We test the collateral as `currency0` and as `currency1`.

## Friction we hit

1. **Sourcing the input leg mid-swap.** Following the `CustomCurveHook` example
   (`manager.take(input)` and then `output.settle`) underflowed whenever the fill was larger than the
   manager's current reserves of the input token. In an exact-input swap the swapper has not settled yet.
   Our first fix took the input as ERC-6909 claims. That left the hook holding claims and paying makers in
   claims. The final design is **settle-before-swap**: the venue settles the collateral into the manager
   *before* calling `swap` (`V4Venue.sol:94`), so the hook can pay makers and the house real tokens inside
   `beforeSwap` and ends every swap holding no tokens and no claims.
   *Suggestion:* note in the custom-curve docs that `take` on the input leg only works while the fill is
   within reserves, and show the settle-first pattern for hooks that pay third parties.

2. **"Deltas net to zero" didn't catch the bug in 1.** The unlock reverted with a reserve underflow, not
   `CurrencyNotSettled`, so the invariant we relied on said nothing. Settle-before-swap ordering is also
   only implicit: drop the `settle` and the unlock reverts, so a passing swap is the only proof. A cheap
   way to assert ordering in a unit test would help.

3. **Hook address mining needs two code paths.** The permission bits live in the address. Tests
   `vm.etch` the hook to `address(FLAGS)`. Deploys mine a CREATE2 salt (up to 300,000 tries,
   `Deploy.s.sol:172`) over an init-code hash that includes constructor args (manager, owner, feed, debt
   token). Any change to those args means re-mining, and the two paths can drift.
   *Suggestion:* a salt-mining helper shipped next to v4-core's test `Deployers` (we wrote our own,
   since v4-periphery is not vendored here) would remove a copy-paste step.

4. **Compiler-version split with 1inch SwapVM.** v4-core and our tree are pinned to solc 0.8.26. 1inch's
   SwapVM and Aqua need 0.8.30 with via-IR. The hook cannot import the router, so it calls it through an
   ABI-only interface (`src/interfaces/ISwapVMRouter.sol`, selectors checked against the compiled
   router). Tests deploy the 0.8.30 contracts from a separate artifacts directory with `vm.deployCode`.
   That is workable but not obvious, and it is one place where v4's pinned compiler shapes integration
   work.

5. **"Stack too deep" without via-IR.** Adding the SwapVM tier to `_beforeSwap` (quote, take, approve,
   swap, settle back) hit "stack too deep" under the legacy pipeline. We split the per-order work into
   `_fillOrder` / `_quoteFair` (`BackstopHook.sol:245`, `:264`). Hooks that do real work in a callback
   reach this quickly.

6. **The predeployed v4 on the devnet has no tokens we can use.** The official PoolManager,
   PositionManager, Quoter and Universal Router are there (good: our hook runs against real v4 bytecode).
   But the devnet USDC is deployer-mint only and WETH9 has no premint. We pair our own ETH-backed WETH
   and mock USDC on the official manager, and seed liquidity with v4-core's `PoolModifyLiquidityTest`.
   That is a test router, used because v4-periphery is not vendored here.

7. **Transient-storage patterns and Foundry's new `isolate` default.** Our flags (venue "liquidation
   active", Aqua gate) are TSTORE-based and checked across calls inside one transaction, as v4's own
   accounting is. Foundry 1.8 made `isolate = true` the default, which clears transient storage between
   a test's top-level calls. Ten tests failed until we pinned `isolate = false`. Not a v4 issue, but v4
   hook authors relying on transient flags will hit it.

8. **Checking that the hook holds nothing.** Confirming "no ERC-6909 claims left" means
   `manager.balanceOf(hook, uint256(uint160(currency)))`. The id convention is easy to get wrong, and a
   named helper would make the check clearer.

## Numbers from our tests

- A full self-paid liquidation through v4 and the hook: HF 0.960 → 1.055, house tier filled, hook ends
  with 0 WETH and 0 claims (**local test**; `just scene uniswap-balances` writes the before/after table).
- A tier-1 fill through the gated SwapVM router: maker USDC −116.49, maker WETH +71.91 at the cited 1.62,
  tiers 2 and 3 untouched (**local test**, and **on fork** against the official Aqua).

<!-- Devnet balance table (B4) goes here once `just scene uniswap-balances` has run on chain 1337. -->

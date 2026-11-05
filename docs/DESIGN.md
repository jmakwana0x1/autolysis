# DESIGN.md — Autolysis v4

Autolysis is a self-liquidating lending market. A borrower's position is wound down by a keyless
carrier transaction that only the alternative mempool admits; the borrower's own account validates and
pays for it, and the collateral is sold through a Uniswap v4 pool whose hook sources liquidity from
1inch Aqua makers first, then the house's deposits, then the plain curve. This document records the
decisions behind that, and the one place two stated guarantees genuinely conflict.

## One liquidation, three backstop tiers

```
carrier (no key) ──▶ alternative mempool ──▶ AutolysisAccount ──▶ AutolysisMarket
                                             VERIFY + pay            │ sells a slice
                                                                     ▼
                                              Uniswap v4 pool + BackstopHook
                                                     │ waterfall
                                     tier 1 Aqua makers → tier 2 deposits → tier 3 curve
```

The dashed data line in the plan is the oracle (`RoundFeed`): both the market's step math and the
account's VERIFY read it, and the hook prices maker/deposit fills from it.

## Why these shapes

- **The firewall is a pure function.** `FirewallRules.check` approves exactly one transaction shape per
  `(position, step)`. Keeping it pure (`TxView` in, `Reject` out) is what lets the whole firewall be
  fuzzed locally against a mocked frame environment even though Forge cannot execute the frame opcodes.
  `IFrameEnv` is the single seam: real opcodes on the devnet, an injected mock in Foundry.
- **The account never reverts during execution.** A failed liquidation must not be able to drain the
  borrower-funded gas tank, so `AutolysisAccount.execute` wraps the market call in a try/catch envelope
  that, on any failure, bills at most the failed-attempt cap and returns cleanly. The reservation is
  taken before the attempt so the tank accounting is exact whether the attempt succeeds or fails.
- **The market sells gradually.** `LiquidationMath` raises the close factor from 10% at HF 1.00 to 100%
  at HF 0.95, so a mildly unhealthy position is wound down in slices and a deeply unhealthy one can be
  taken whole. A transient "liquidation active" flag (EIP-1153) plus settle-before-swap keeps the sale
  atomic and reentrancy-safe, and `TankLedger` conserves deposits = balance + billed at all times.
- **The breaker needs two rounds.** `RoundFeed.priceForLiquidation` reverts rather than return a price
  outside the band, and a move over 10% needs a confirming round before it is usable, so a single oracle
  spike cannot drive a liquidation. The feed is the only price a liquidation may read.
- **The hook is invisible to everyone else.** `BackstopHook` returns `ZERO_DELTA` for any swap that is
  not a registered market's flagged liquidation, so an outside swapper sees a vanilla pool to the wei.
  A registered liquidation is filled with return-delta accounting through the three-tier waterfall.
- **The Aqua tier is gated.** `AutolysisAquaRouter` (our SwapVM redeploy) fills maker strategies only
  when the caller is the hook and the gate is open — no one outside a liquidation can touch a maker.
  Strategies run from an allowlisted EIP-1167 clone template under a per-maker gas stipend, so a
  gas-bomb or rugging maker is cut off and skipped to the next tier. Pricing (oracle − base spread + vol
  add-on) is shared by `quote()` and the fill, so a quote always equals the fill.

## The one real conflict: HF-preservation vs. protocol-favoring rounding

The plan lists two properties for `LiquidationMath`: *a step never lowers the health factor*, and
*rounding always favors the protocol*. For a single no-bonus self-liquidation trade these are opposed at
the wei: rounding the collateral sale **up** (protocol-favoring) sells the borrower a hair more
collateral per unit of debt cleared, which lowers HF; rounding it **down** protects HF but hands the
borrower a sliver. They cannot both hold exactly on the same quantity.

The resolution, chosen deliberately: **HF-preservation is the headline guarantee** for the step, since
self-liquidation exists to protect the borrower. In the regime the system operates in — a position still
over-collateralized by value (`V > D`), i.e. HF above the liquidation threshold but below 1 — a step
never lowers HF; the only erosion is sub-wei integer-collateral rounding, bounded by the value of one
indivisible collateral unit and absorbed by the `V > D` margin (the fuzz test asserts exactly this
bound). Protocol-favoring rounding is applied where it belongs instead: the swap's `minOut` (the market
requires at least the intended debt in return) and the debt/collateral accounting. Deeply underwater
positions (`V < D`) are bad debt where no fair-value sale can raise the ratio; there the close factor is
already 100% and the whole position is taken.

## What is modeled vs. vendored

v4-core and forge-std are vendored at pinned commits and the hook is built and tested against the real
`PoolManager`. The Hegota devnet frame opcodes and the 1inch SwapVM/Aqua engine are **modeled** in this
repo (`src/frame`, `src/aqua`) rather than vendored: the devnet and the sidecar are not available in
this build environment. Every modeled assumption is isolated behind an interface (`IFrameEnv`,
`IMakerStrategy`) and pinned in `deployments/probes.json`, so swapping in the real systems is a
configuration and adapter change, not a rewrite. `docs/STATUS.md` tracks exactly what is proven locally
versus what still needs the devnet.

## M4/M5: wiring the real devnet and SwapVM (follow-up, devnet/Hardhat-gated)

Two pieces are written to the real interfaces but cannot be *run* in this build (no devnet; SwapVM uses
a separate Hardhat/solc-0.8.30 toolchain):

- **Probes (M4).** `kit/src/probes/` targets the real sidecar: it builds frame transactions with
  `@forshtat/hegota-support` (`newTx`/`frame`/`encodeTx`), submits with `eth_sendFrameTransaction`
  (`toWire`), runs read-only probes with `ethrex_simulateFrameTransaction`, and maps node rejections with
  `explainRejection`. The eight probes settle: opcode support, the MAX_COST fee formula, staked vs
  unstaked VERIFY reads, the first-use key cost boundary (97,919 vs 97,920), the sequence ceiling, the
  replacement bump, solvency rejection, and reputation counters. `deployments/probes.json` carries a
  `selectorFallback` flag: if FRAMEPARAM/FRAMEDATALOAD do not work on chain 1337 but TXPARAM does, VERIFY
  takes `(positionId, roundId)` in its own calldata and checks `NONCE_KEY_0 == H(market,id) >> 8`, and
  `selfLiquidate` re-checks the key with TXPARAM. The probe sources are excluded from the kit's typecheck
  until the package is built against a devnet.

- **SwapVM fork (M5/N3).** `1inch/swap-vm` @ `f9f4acf`, `1inch/aqua` @ `v1.0.2-rc.2`,
  `1inch/solidity-utils` @ `v7.0.3` and OpenZeppelin `v5.6.1` are vendored. The real fork lives in
  `aqua-fork/` (its own Foundry profile, solc 0.8.30, `via_ir`, OZ 5.6.1 — isolated from the main
  project whose bundled OZ remapping would clash) under the SwapVM-1.1 license (`aqua-fork/LICENSES/`,
  which requires modifications to stay under it). `AutolysisAquaRouterGated` forks `AquaSwapVMRouter`
  (extends `Simulator, SwapVM, AquaOpcodes`) and overrides `_dispatch` to handle a `LiquidationGate`
  opcode — `ctx.query.taker == hook && IGateVenue(venue).liquidationActive()` — before `_runOpcode`.
  `FOUNDRY_PROFILE=aqua forge test` (`just aqua`) compiles it against the real SwapVM/Aqua and runs the
  gate test (hook + active passes; stranger / inactive revert). **Remaining for the full 1inch track:**
  makers ship their strategy into Aqua with the gate as the first instruction, the hook acts as taker,
  and the order-hash template check (the hook rebuilds the expected program from a template plus the
  maker's registered parameters and accepts only if `hash(order)` matches) replaces the EIP-1167 clone
  allowlist; then run SwapVM's own suite with the opcode. This wiring crosses the 0.8.30/0.8.26 boundary
  (a deployment concern). ### R5 progress and the exact remaining recipe

Done and verified: the gated fork compiles against upstream SwapVM/Aqua; the `LiquidationGate` opcode
(`0xf9`) is checked at `_dispatch` (hook+active passes, stranger/inactive revert, `just aqua`); and
`src/aqua/ISwapVMRouter.sol` is the ABI-exact 0.8.26 seam the hook uses to call the 0.8.30 router across
the solc boundary (the hook only needs the ABI; deploy the router in a 0.8.26 test with
`vm.deployCode("aqua-fork/out/AutolysisAquaRouterGated.sol/AutolysisAquaRouterGated.json", args)`).

Remaining (written up, not yet run end to end): a maker `ship`s an order whose program is the gate as
the first instruction — a bare `hex"f900"` header passed as the `prefix` to
`Strategies.buildXYCConcentrateOrder` (or `buildLimitOrder`), then the oracle-pricing instruction
(`OraclePriceAdjuster` / an `Extruction` reading `venue.liquidationPrice()`), then the swap. `BackstopHook`
tier 1 calls `ISwapVMRouter.swap` as the taker for each registered order; the order-hash template check
(rebuild the expected program from a template + the maker's registered parameters, accept only if
`hash(order)` matches) replaces the EIP-1167 clone allowlist. Exit test: a full liquidation moves USDC out
of the maker's wallet and WETH into it, and a stranger calling the router directly reverts
`LiquidationGateClosed`. This uses SwapVM's Aqua test-base order/ship encoding, so it is built in the
`aqua` (0.8.30) profile. `src/aqua` stays as the fast-test model with the same guarantees.

# Autolysis v4

Self-liquidating lending. A keyless carrier builds each liquidation, only the alternative mempool admits
it, the borrower's `AutolysisAccount` validates and pays from a borrower-funded gas tank, and the market
sells a slice of collateral through a Uniswap v4 pool whose hook fills from 1inch Aqua makers first, then
its own deposits, then the plain curve.

- Design and the one real trade-off: [`docs/DESIGN.md`](docs/DESIGN.md)
- Phase-by-phase status (what is proven locally vs. needs a devnet): [`docs/STATUS.md`](docs/STATUS.md)
- Build plan: [`docs/BUILD_PLAN.md`](docs/BUILD_PLAN.md)
- Building on Uniswap v4: [`docs/FEEDBACK.md`](docs/FEEDBACK.md) · AI usage: [`docs/AI_USAGE.md`](docs/AI_USAGE.md)
- Lab chart (EXO-010 with/without reputation): `app/lab-exo010.html`

## Where each guarantee lives

| Guarantee | Source | Test |
| --- | --- | --- |
| One tx shape approved per (position, step) | `src/libraries/FirewallRules.sol` | `test/fuzz/FirewallRules.t.sol` |
| A step never lowers HF (close factor 10%→100%) | `src/libraries/LiquidationMath.sol` | `test/fuzz/LiquidationMath.t.sol` |
| Kit math equals Solidity to the wei | `kit/src/math.ts` | `test/fuzz/Differential.t.sol` |
| A liquidation never uses an out-of-band price | `src/core/RoundFeed.sol` | `test/unit/RoundFeed.t.sol` |
| Never-revert execution envelope | `src/core/AutolysisAccount.sol` | `test/integration/Liquidation.t.sol` |
| Collateral/debt conserved, only the account liquidates | `src/core/AutolysisMarket.sol` | `test/invariant/Market.invariant.t.sol` |
| Tank conservation + headroom | `src/libraries/TankLedger.sol` | `test/unit/TankLedger.t.sol` |
| Outside swapper sees a normal pool; deltas net to zero | `src/backstop/BackstopHook.sol` | `test/backstop/BackstopHook.t.sol` |
| No one outside a liquidation fills a maker; quote==fill | `src/aqua/AutolysisAquaRouter.sol` | `test/aqua/AquaRouter.t.sol`, `test/invariant/RouterInvariant.t.sol` |
| Adversarial scenarios (rescue, key-append, fee grief, …) | — | `test/scenarios/Adversarial.t.sol` |

## Layout

| Path | What |
| --- | --- |
| `src/frame/` | `IFrameEnv` (the one door for frame-opcode reads), devnet adapter, cell assembler |
| `src/core/` | Market, account, round feed |
| `src/libraries/` | Pure liquidation math, firewall rules, tank ledger |
| `src/backstop/` | Uniswap v4 `BaseHook` + `BackstopHook` (three-tier waterfall) |
| `src/aqua/` | `AutolysisAquaRouter` (gated SwapVM redeploy), maker template + factory, pricing |
| `src/adapters/` | `ICollateralAdapter` + second-collateral skeleton |
| `src/generated/` | Constants generated from `deployments/probes.json` |
| `deployments/` | `1337.json` (addresses), `probes.json`, `pins.json` |
| `kit/` | autolysis-kit (TypeScript): frame-tx codec, carrier, probes, EXO-010 simulator, scenes |
| `app/` | dApp pages (Borrow, Backstop, Lab, Rescue) |

## Commands

```bash
just test         # unit + fuzz + differential, every commit
just invariants   # stateful invariants (~3 min at default depth)
just fuzz-deep    # 100k runs per property
just sim          # run the EXO-010 simulator, refresh the Lab chart data
just probe        # devnet probes (needs RPC_URL); then `just gen`
just scene <name> # one devnet scene     ·     just e2e   # whole demo
just reset        # redeploy + seed
```

Toolchain: Foundry (solc 0.8.26, cancun), `just`, Node 22. Dependencies are pinned to exact commits in
`foundry.toml` / `deployments/pins.json`. On-chain explorer links and `deployments/1337.json` addresses
are filled in by the deploy scripts once a devnet is available (see `docs/STATUS.md`).

## Submission checklist

- [x] Core engine: math, firewall, feed, market, account, tank — local suites green
- [x] Mempool behavior: replacement carrier, attack builders, adversarial scenes
- [x] Uniswap backstop: v4 hook, both currency orders, deltas net to zero, FEEDBACK.md
- [x] Aqua tier: gated router, oracle pricing, template allowlist, maker scripts, waterfall
- [x] Product/research: EXO-010 simulator + with/without chart, collateral-adapter seam
- [x] Submission docs: README (this file), DESIGN.md, FEEDBACK.md, AI_USAGE.md
- [ ] Devnet: first self-paid liquidation included on-chain, explorer links, live app, demo video

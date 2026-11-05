# Status

Autolysis v4 — what is proven where. Nothing is proven on a live devnet yet (none is available in this
build), so the honest split is **proven by local suite** vs **needs a devnet**.

## Proven by local suite (Foundry + v4-core/SwapVM + kit vitest)

| Area | Where | Suite |
| --- | --- | --- |
| Liquidation math (close factor, HF, slippage step, insolvency) | `src/libraries/LiquidationMath.sol` | `test/fuzz/LiquidationMath.t.sol`, `test/fuzz/Differential.t.sol` (kit↔Solidity) |
| Firewall: one tx shape per (position, step), ALLOWED_SCOPE rule | `src/libraries/FirewallRules.sol` | `test/fuzz/FirewallRules.t.sol` (mutation fuzzer) |
| Round feed: band + two-round breaker + VERIFY window | `src/core/RoundFeed.sol` | `test/unit/RoundFeed.t.sol`, `test/scenarios/H1_verify_round.t.sol` |
| Account: caller guard, VERIFY round/health gate, never-revert envelope via `maxCost()` | `src/core/AutolysisAccount.sol` | `test/scenarios/{C1,C2,H1,N5_N6}.t.sol`, `test/integration/Liquidation.t.sol` |
| Market: gas billed in collateral/ETH, surplus + bad-debt, one attempt per round, conservation | `src/core/AutolysisMarket.sol` | `test/scenarios/{C6_haircut,H3_surplus_baddebt,N5_N6}.t.sol`, `test/invariant/Market.invariant.t.sol` (11 invariants @ 1000×200) |
| v4 BackstopHook: authorize on sender+flag, waterfall, makers/house paid real tokens, deltas net to zero | `src/backstop/{BackstopHook,V4Venue}.sol` | `test/backstop/BackstopHook.t.sol`, `test/integration/V4Liquidation.t.sol` |
| Aqua model router (gate, oracle pricing quote==fill, template allowlist, stipends, skip rules) | `src/aqua/*` | `test/aqua/AquaRouter.t.sol`, `test/invariant/RouterInvariant.t.sol` |
| Real SwapVM/Aqua fork compiles; LiquidationGate opcode (hook+active passes, else reverts) | `aqua-fork/src/AutolysisAquaRouterGated.sol` | `just aqua` (`FOUNDRY_PROFILE=aqua forge test`) |
| Frame tx built with the real hegota-support encoder (round-trips); replacement carrier; EXO-010 sim | `kit/src/*` | `kit` vitest (frametx round-trip, carrier, probes-with-mock, exo010) |

## Needs a devnet (code written to the real interfaces; not run here)

| Item | State |
| --- | --- |
| First self-paid liquidation included on chain 1337 | pending RPC |
| Probes run on the sidecar (`eth_sendFrameTransaction` / `ethrex_simulateFrameTransaction`) | code ready (`kit/src/probes`); pins only fields a real probe confirms this run, never assumptions |
| Account staking (ERC-8421 STORAGE-032) so VERIFY may read the market/feed | `IAccountStaking` + deploy step documented; probe 3 confirms on chain |
| `deployments/1337.json` addresses + explorer links | filled by deploy scripts on a devnet |
| Live app pages (Borrow/Backstop/Rescue); Lab EXO-010 chart is already published | pending RPC |

## Open (from the second review)

- **Full 1inch Aqua integration (N3 remainder):** makers ship their strategy into Aqua with the
  LiquidationGate as the first instruction, the hook acts as taker, and an order-hash template check
  replaces the clone allowlist; then run SwapVM's own suite with the opcode. The fork compiles and the
  gate is verified; the wiring crosses the 0.8.30/0.8.26 boundary (a deployment concern). See
  `docs/DESIGN.md`.
- Everything else from the first and second reviews (C1–C6, H1–H5, M1–M3, N1, N2, N4–N9) is addressed and
  covered by the local suites above.

## Commands

```bash
just test         # unit + fuzz + differential + integration + backstop + aqua model (every commit)
just invariants   # stateful invariants (~3 min at default depth)
just aqua         # the real SwapVM/Aqua fork build + LiquidationGate test (solc 0.8.30)
just sim          # EXO-010 simulator -> Lab chart data
just probe        # devnet probes (needs RPC_URL + ACCOUNT); then `just gen`
cd kit && npx vitest run    # kit unit tests
```

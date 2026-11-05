# Status

Autolysis v4 — what is proven where. Nothing is proven on a live devnet yet (none is available in this
build), so the honest split is **proven by local suite** vs **needs a devnet**.

> **Devnet facts (Nov 5): see [`docs/DEVNET.md`](./DEVNET.md).** The Hegota alt-mempool devnet is now real
> (chain 1337, endpoints + predeployed Uniswap v4 + `NaiveStakingRegistry`), read from the vendored
> `forshtat/mempool-workshop` (`bcfe02a`) and `-sidecar` (`2e22ff0`). Those facts override assumptions in
> `PLAN-v4.3.md` / `REVIEW-3`. The load-bearing one: **`MAX_VERIFY_GAS = 100,000`, no 1M staked allowance
> in this sidecar.** After A1 (slim VERIFY, `loadCanonical()`), the **mock only** VERIFY gas is
> **70,728** (outside reads) and **49,321** (storage-only), both under 99,900 on the mock. Which path ships
> is decided in A5 from the devnet's `ethrex_simulateFrameTransaction` `frames[0].gasUsed` (**written, not run**).

## Proven by local suite (Foundry + v4-core/SwapVM + kit vitest)

| Area | Where | Suite |
| --- | --- | --- |
| Liquidation math (close factor, HF, slippage step, insolvency) | `src/libraries/LiquidationMath.sol` | `test/fuzz/LiquidationMath.t.sol`, `test/fuzz/Differential.t.sol` (kit↔Solidity) |
| Firewall: one tx shape per (position, step), ALLOWED_SCOPE rule, on the fixed `CanonicalView` (A1) | `src/libraries/FirewallRules.sol`, `src/frame/CanonicalReader.sol` | `test/fuzz/FirewallRules.t.sol` (mutation fuzzer + mock/reference agreement) |
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

## Devnet-readiness pass (third review, R1–R5)

Labels: **on devnet** · **local test** (runs on anvil / Foundry here) · **mock only** · **written, not run**.

| Item | State | Label |
| --- | --- | --- |
| R1 deploy + seed | `script/Deploy.s.sol` + `kit/src/seed.ts` run end to end on anvil: all addresses have code, 3 borrowers at HF 1.03/1.06/1.10, liquidity, house, makers | **local test** |
| R2 staking | `NaiveStakingRegistry` at `0xD51c…D2F`, minStake 0.01 ETH, keyed on msg.sender; deploy calls `account.stake{0.012 ETH}(86400)` and defaults the registry to the devnet address. **MAX_VERIFY_GAS = 100k, NOT 1M.** A1 mock gas: outside reads 70,728, storage-only 49,321 (`A1_verify_gas.t.sol`, **mock only**); path chosen in A5 from devnet simulate. | staking build **local test**; the 100k cap vs real `frames[0].gasUsed` **written, not run** (devnet simulate) |
| R3 probes | `ProbeOpcodes.sol` (real `HegotaSupport`) deploys on anvil; probes rewritten on `ethrex_simulateFrameTransaction([tx,"latest",{trace:true}])` reading `{succeeded,gasUsed,violation}`; added a VERIFY-gas probe (`frames[0].gasUsed` ≤ 99,900) | opcode deploy **local test**; probe execution **written, not run** (needs the devnet) |
| R4 signature | keyless liquidation = one ARBITRARY entry `{scheme:0,…}` by **default** (per devnet facts), empty-list is the probed stretch form; ARBITRARY costs 100 gas toward MAX_VERIFY_GAS | **local test** (build/encode); whether empty-list is admitted **written, not run** |
| R5 Aqua fork | gated fork compiles vs upstream SwapVM/Aqua; LiquidationGate verified at `_dispatch`; full maker-ship swap through the real `Aqua.ship`/`swap` ABI | gate + **full fill** **local test** (see W2 below) |

Nothing is **on devnet** yet (no RPC in this environment). Fresh clone: run `just setup` once (builds the
vendored hegota-support package), then `just test` / `just aqua`.

## PLAN-v4.3 pass (W1–W3): prove each sponsor track on a real chain environment

Unichain mainnet/Sepolia RPC is unreachable from this container
(`cast chain-id --rpc-url https://mainnet.unichain.org` fails), so W2.0's local-chain fallback applies to
W2 and W3: the proofs run against a fresh local PoolManager / a fresh `new Aqua()` with the official
contract code, and the user reruns the official-address fork variant on the laptop. No address was
assumed — unknowns are `TODO(ask:)` in `docs/PLAN-v4.3.md`.

| Item | What is proven | Where | Label |
| --- | --- | --- | --- |
| W2.1 gated router vs real Aqua | maker ships a gated program into `new Aqua()`; hook fills (tokens move); stranger + inactive venue revert `LiquidationGateClosed` | `aqua-fork/test/GatedAquaFill.t.sol` | **local test** |
| W2.2–2.3 oracle pricer + maker program | `LiquidationPricer` (IExtruction/IStaticExtruction) prices off the feed; program `[gate][Extruction→pricer][Salt]`; fill == oracle rate (not reserves), quote == swap, fill tracks an oracle move | `aqua-fork/src/LiquidationPricer.sol`, `aqua-fork/test/OraclePricedFill.t.sol` | **local test** |
| W2.4 hook → router ABI seam | `ISwapVMRouter` interface; `swap`/`quote` selectors verified equal to the compiled gated router (`0xa69f95bd` / `0xb7ebf0c5`) so the hook can call it cross-solc | `src/interfaces/ISwapVMRouter.sol` | seam **local test**; hook calling it end-to-end across the 0.8.26/0.8.30 boundary **written, not run** (laptop/devnet toolchain) |
| W2.5 template allowlist | a non-allowlisted strategy template is rejected; canonical clone-codehash allowed | `test/aqua/AquaRouter.t.sol::test_nonAllowlistedTemplateRejected` | **local test** |
| W3.1–3.2 v4 liquidation | BackstopHook mined to the flag bits, pool initialized + seeded, full liquidation: maker USDC drops, maker paid real collateral, hook left holding no claims | `test/integration/V4Liquidation.t.sol` | **local test** (fresh PoolManager); official PoolManager/PositionManager addresses **written, not run** (laptop fork) |
| W1.5 storage-only VERIFY | behind `storageOnlyVerify`, VERIFY reads the round/health gate from a snapshot in the account's own storage (pushed outside VERIFY); proven to approve even when every market read is mocked to revert, so VERIFY touches no outside contract and needs no staked read | `src/core/AutolysisAccount.sol`, `test/scenarios/W1_storage_only_verify.t.sol` | **local test** |

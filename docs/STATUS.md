# Status

Autolysis v4 — what is proven where. Nothing is proven on a live devnet yet (none is available in this
build), so the honest split is **proven by local suite** vs **needs a devnet**.

> **Devnet facts (Nov 5): see [`docs/DEVNET.md`](./DEVNET.md).** The Hegota alt-mempool devnet is now real
> (chain 1337, endpoints + predeployed Uniswap v4 + `NaiveStakingRegistry`), read from the vendored
> `forshtat/mempool-workshop` (`bcfe02a`) and `-sidecar` (`2e22ff0`). Those facts override assumptions in
> `PLAN-v4.3.md` / `REVIEW-3`. The load-bearing one: **`MAX_VERIFY_GAS = 100,000`, no 1M staked allowance
> in this sidecar.** After A1 (slim VERIFY, `loadCanonical()`), the **mock only** VERIFY gas is
> **71,822** (outside reads) and **50,414** (storage-only), both under 99,900 on the mock. Which path ships
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
| R2 staking | `NaiveStakingRegistry` at `0xD51c…D2F`, minStake 0.01 ETH, keyed on msg.sender; deploy calls `account.stake{0.012 ETH}(86400)` and defaults the registry to the devnet address. **MAX_VERIFY_GAS = 100k, NOT 1M.** A1 mock gas: outside reads 71,822, storage-only 50,414 (`A1_verify_gas.t.sol`, **mock only**); path chosen in A5 from devnet simulate. | staking build **local test**; the 100k cap vs real `frames[0].gasUsed` **written, not run** (devnet simulate) |
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
| W2.4 hook → router ABI seam | `ISwapVMRouter` interface; `swap`/`quote` selectors verified equal to the compiled gated router (`0xa69f95bd` / `0xb7ebf0c5`) so the hook can call it cross-solc; `hash` added (upstream `ISwapVM.hash`, view) | `src/interfaces/ISwapVMRouter.sol` | seam **local test**; hook calling it end-to-end: see C1 |
| W2.5 template allowlist | a non-allowlisted strategy template is rejected; canonical clone-codehash allowed | `test/aqua/AquaRouter.t.sol::test_nonAllowlistedTemplateRejected` | **local test** |
| W3.1–3.2 v4 liquidation | BackstopHook mined to the flag bits, pool initialized + seeded, full liquidation: maker USDC drops, maker paid real collateral, hook left holding no claims | `test/integration/V4Liquidation.t.sol` | **local test** (fresh PoolManager); official PoolManager/PositionManager addresses **written, not run** (laptop fork) |
| W1.5 storage-only VERIFY | behind `storageOnlyVerify`, VERIFY reads the round/health gate from a snapshot in the account's own storage (pushed outside VERIFY); proven to approve even when every market read is mocked to revert, so VERIFY touches no outside contract and needs no staked read | `src/core/AutolysisAccount.sol`, `test/scenarios/W1_storage_only_verify.t.sol` | **local test** |

## PLAN-v4.4 pass

| Item | What is proven | Where | Label |
| --- | --- | --- | --- |
| A1 slim VERIFY | `IFrameEnv.loadCanonical()` → fixed-size `CanonicalView` (15 opcode reads, no dynamic ABI), one shared `CanonicalReader` for devnet + mock; `FirewallRules` on the view (+ `EXEC_VALUE`); `Approved` event dropped; mutation fuzz green, plus mock/reference agreement. Gas: outside reads **71,822**, storage-only **50,414** (cold start) | `src/frame/CanonicalReader.sol`, `test/scenarios/A1_verify_gas.t.sol` | **mock only** (gas); rules **local test** |
| A1 follow-up: frame 0 MODE | frame 0 MODE == VERIFY is read again (one extra FRAMEPARAM) and checked (`Reject.VERIFY_FRAME`), so the rules no longer rely on APPROVE being VERIFY-only. Sender / frame-0 target stay implied by APPROVE (`resolved_target == tx.sender`) | `test/fuzz/FirewallRules.t.sol::test_mut_verifyMode` | **local test** |
| C1 hook tier 1 → gated SwapVM router | full liquidation market → V4Venue → v4 pool → `BackstopHook` tier 1 → `AutolysisAquaRouterGated` + `Aqua` (0.8.30, from `out-aqua` artifacts via `vm.deployCode`); maker ships `[gate][Extruction→LiquidationPricer(venue.price())][Salt]`. Maker wallet USDC −116.49, collateral +71.91 at the cited 1.62; tiers 2/3 untouched; hook keeps 0 tokens / 0 claims / 0 allowance; stranger and hook-outside-liquidation fills revert `LiquidationGateClosed` | `src/backstop/BackstopHook.sol` (`_tier1SwapVM`), `test/integration/C1_SwapVMTier1.t.sol` | **local test** |
| C2 same against official Aqua `0x1111…a90a` on Unichain | the C1 flow (3 tests) passes on a Unichain mainnet fork (chain 130, block 63190327) with the **official** Aqua: `rawBalances`/`pull`/`push` hit `0x1111113C…6a90a`; our gated router, pricer, hook, market and a fresh PoolManager are deployed on the fork. Same fill: 71.91 COL → 116.49 USDC at 1.62 | `test/fork/C2_OfficialAqua.t.sol`, `just fork-c2`, trace `deployments/c2-fork-trace.txt` | **on fork** |
| `just gate-a` | one unattended, idempotent Phase A run: preflight → deploy (`USE_PREDEPLOYED_V4` on 1337) → stake 0.012 ETH (recorded tx) → fund account + fee cap → seed 2 ETH-backed positions + house tier → crash rounds → VERIFY snapshots → simulate BOTH paths, choose by the rule (outside reads if gas + 100 ≤ 97,000) → canonical `eth_sendRawTransaction` (exact body saved) → `eth_sendFrameTransaction` → receipt (all frames 0x1 + `LiquidationOk`) → before/after balances, all into `deployments/1337.json`; stops on the first error with its text, resumes a sent tx by hash | `kit/src/gateA/*`, `kit/test/gateA.test.ts` (8 tests, fake chain + fake frame node) | state machine **local test**; devnet run **written, not run** (keys unfunded) |
| `just gate-a-local` | the same command against anvil + a MOCK frame node: deploy, stake (real NaiveStakingRegistry bytecode etched at the devnet address), seeding, rounds, snapshots and the SENDER-frame liquidation run for real on anvil (HF 0.96 → 1.055, tier 2 paid); simulate gas, the canonical rejection text and VERIFY are **mock**. Second run is a no-op | `kit/scripts/gate-a-local.sh`, `kit/src/gateA/mockNode.ts` | **local test** (+ **mock only** frame RPCs) |
| Fixes found while building gate-a | (1) `IStakingRegistry.getDepositInfo` declared `(uint256,bool,uint32)`; the devnet registry returns `(uint256 stake,uint32 unstakeDelaySec,uint64 withdrawTime)` — aligned, mock rewritten to the real rules. (2) simulate was sent the JSON wire form and parsed `valid`/`violation`; it takes the raw 0x06 bytes and returns `canonicalMempool*` — fixed (`kit/src/sim.ts`). (3) Deploy now writes `deployments/<id>.addresses.json` so the run record is never clobbered | `src/frame/IStakingRegistry.sol`, `kit/src/sim.ts`, `script/Deploy.s.sol` | **local test** |
| Phase B commands | `just scene crash` (12 ETH-backed positions on 12 keys, one in-band crash round, canonical `eth_sendRawTransaction` then alt `eth_sendFrameTransaction` for each, all receipts, reputation before/after), `just scene replace` (same key + sequence, both fees +10%+1, newer round; statuses of both), `just scene attacks` (appended key, wrong selector, fee over cap, stale round, frame-0 DEFAULT mode: simulate + send, decoded `Rejected(...)` reason; an attack VERIFY would approve is never broadcast), `just scene uniswap-balances` (B4 table: borrower, PoolManager, hook tokens + ERC-6909 claims, house), `just reputation <label>` (`skandha_explorer_listReputation` snapshot → measured EXO-010 series), `just e2e` (all of them) | `kit/src/scenes/phaseB.ts`, `kit/test/scenes.test.ts` (7 tests, mocked RPC with VERIFY shape rules + keyed replacement) | logic **local test**; devnet **written, not run** |
| Phase B on anvil | `just gate-a-local` also runs crash (12/12 SENDER-frame liquidations emulated, LiquidationOk), uniswap-balances (hook ends with 0 WETH, 0 claims) and reputation against the mock node. attacks/replace need real VERIFY + the real mempool: devnet only | `kit/scripts/gate-a-local.sh` | **local test** (frame RPCs **mock only**) |
| D1 `classicLiquidate()` | lender fallback: opens to anyone only when the position was unhealthy for 3 consecutive rounds (counted on chain by the keeper poke `markUnhealthy`, reset by any position change or a successful self-liquidation; failed attempts do not hold it shut) and HF < 0.95; repays ≤ 50% of the debt for collateral at a 5% bonus at the latest valid round; capped at the collateral, with the shortfall written off as bad debt (found by `invariant_noDanglingDebt`) | `src/core/AutolysisMarket.sol`, `test/scenarios/D1_classic.t.sol` (11 tests) | **local test** |
| D1 invariant | `invariant_classicNeverPreemptsSelfLiquidation`: an independent handler ghost counts the rounds the carrier could have liquidated at; every classic fill needs ≥ 3 of them and HF < 0.95. Non-vacuity: every real "carrier offline" opportunity must open the fallback (16,724 starves in the full 1,000 × 200 campaign, 0 misses) | `test/invariant/*` | **local test** |
| D3 dashboard | one page (`app/dashboard`, `just dashboard` / `just demo-local`): crash button + 12 positions, canonical-vs-alt exact texts, per-tx lifecycle from receipt frames + logs, net saved vs a 5% classic bonus, EXO-010 simulated beside measured; light/dark validated; no overflow at 375 px | `app/` | **local test** (on anvil + mock node); devnet = switch `CHAIN_ID`/`RPC_URL` |
| D4/D5 drafts | README rewritten (problem with numbers, net-cost table, diagram, sponsor table with file:line, `ISelfLiquidatingMarket` note, limitations, history note); FEEDBACK.md updated with the friction actually hit; `docs/EF_WRITEUP.md` (app, tooling, scoped EXO-010). Explorer links are `TBD` placeholders | `README.md`, `docs/FEEDBACK.md`, `docs/EF_WRITEUP.md` | **written** (devnet numbers pending) |

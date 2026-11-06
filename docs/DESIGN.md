# DESIGN.md: Autolysis

Autolysis is a self-liquidating lending market. An unhealthy position is wound down by a **keyless frame
transaction** (EIP-8141). The position's own `AutolysisAccount` validates it in a VERIFY frame and pays for
it as the sender. The SENDER frame sells a slice of collateral through a Uniswap v4 pool, whose
`BackstopHook` fills from 1inch Aqua makers first, then the house's deposits, then the pool's curve. Gas is
billed from the collateral being sold. If the carrier stays offline, a classic 5%-bonus fallback opens to
anyone.

This document records the current design, the one place two stated guarantees conflict, and the threat
model. What runs where is in [`STATUS.md`](STATUS.md); the devnet facts are in [`DEVNET.md`](DEVNET.md).

## One liquidation, end to end

```
carrier (no key) ─eth_sendFrameTransaction─▶ alt mempool (miner sidecar; the account is staked)
                                               │
  frame 0  VERIFY  AutolysisAccount.verifyLiquidation()   read-only; APPROVE(EXECUTION_AND_PAYMENT)
  frame 1  SENDER  AutolysisAccount.selfLiquidate(id, R)  never reverts
                     └─ AutolysisMarket.executeLiquidation(id, R, MAX_COST)
                          ├─ LiquidationMath.computeStep at round R's price
                          ├─ V4Venue.sellCollateral  → PoolManager.unlock
                          │     settle collateral first, then swap exact-in with the liquidation flag
                          │     BackstopHook._beforeSwap waterfall:
                          │        tier 1  gated SwapVM router → Aqua makers (oracle-priced)
                          │        tier 2  house deposits (priced at R)
                          │        tier 3  the pool's own curve (minOut enforced by the venue)
                          └─ bill gas: min(MAX_COST, 0.3% of collateral sold) of WETH → unwrap → account
```

## The design, piece by piece

- **VERIFY approves exactly one shape per (position, step).** `FirewallRules.check`
  (`src/libraries/FirewallRules.sol`) is a pure function over a fixed-size `CanonicalView`: 15 frame-opcode
  reads via `IFrameEnv.loadCanonical()`, with no dynamic ABI decoding. It requires:
  - exactly two frames: frame 0 in VERIFY mode with scope EXECUTION_AND_PAYMENT, frame 1 in SENDER mode
    targeting the account with no value;
  - frame 1 calling `selfLiquidate(positionId, roundId)` (68 bytes);
  - exactly one nonce key, `H(market, positionId)` with the top byte cleared;
  - MAX_COST within the account's fee cap;
  - a state budget for a first-use key.

  APPROVE itself enforces that the sender and frame-0 target are the account (`resolved_target ==
  tx.sender`). Then the round/health gate checks that the cited round R is newer than `lastAttemptRound`,
  and that the position is unhealthy at R's price and at the latest price. That data comes either from
  the market directly (outside reads, which need the account staked) or from a snapshot in the account's
  own storage (storage-only). On the devnet, simulate measured 94,168 and 71,892 VERIFY gas; outside
  reads is the path in use.
- **One nonce lane per position.** EIP-8250 keyed nonces let 12 liquidations of 12 positions sit pending
  from one sender without blocking each other. A newer round replaces a pending tx on the same key with
  a +10% fee bump.
- **The SENDER frame never reverts.** `selfLiquidate` accepts calls only from the account itself (C1). It
  calls `executeLiquidation` in a try/catch. On failure it bills `min(MAX_COST, maxFailedGasBill)` and
  records the attempt, so a failing liquidation cannot loop or drain anything.
- **Gas is billed from the collateral being sold (H2).** No separate gas tank. The market takes `min(MAX_COST,
  0.3% of collateral sold)` of WETH collateral, unwraps it and sends the ETH to the account, which keeps
  the account funded for its next frame tx. The borrower never pays more than the MAX_COST they implicitly
  accept by being liquidatable.
- **One attempt per round, success or failure.** `lastAttemptRound[id]` advances on every attempt.
  VERIFY rejects any round at or below it, so a failed attempt cannot be retried at the same price, and a
  new round is needed (C2/H1).
- **The oracle can't be spiked into a liquidation.** `RoundFeed` caps a move at 10% per round. A larger
  move trips a two-round breaker, VERIFY only accepts the last K = 4 rounds, and the SENDER path rejects
  rounds older than one hour.
- **Gradual sale.** `LiquidationMath` raises the close factor from 10% at HF 1.00 to 100% at HF 0.95 and
  targets HF 1.05. Proceeds go to the debt first. Surplus is credited to the borrower; if the whole
  position is sold and debt remains, the shortfall is written off as bad debt (H3).
- **Settle-before-swap (N4).** `V4Venue.unlockCallback` settles the collateral into the PoolManager
  *before* `swap`. So inside `beforeSwap` the hook can pay makers and the house real tokens; the hook ends
  every swap holding no tokens and no ERC-6909 claims. The swap's collateral debit nets against that
  credit.
- **The hook is invisible to everyone else.** `BackstopHook._beforeSwap` fills only when the caller
  (`sender`, the unlock caller) is a registered venue, that venue reports a liquidation in progress (a
  transient flag), and the swap is exact-in into the debt token. Otherwise it returns `ZERO_DELTA`, so an
  outside swapper, even one claiming to be a liquidation in `hookData`, sees a normal pool.
- **Tier 1 is gated SwapVM over Aqua.** `AutolysisAquaRouterGated` (`aqua-fork/`, solc 0.8.30, SwapVM-1.1
  licence) is 1inch's `AquaSwapVMRouter` plus one opcode. `LiquidationGate` (`0xf9`) reverts unless the
  taker is the hook and the venue reports a live liquidation. A maker ships the program
  `[gate][Extruction → LiquidationPricer(venue.price())][Salt]` into Aqua, with funds staying in the
  maker's wallet. For each owner-registered order the hook:
  1. sizes the fill to the maker's Aqua balance at the cited price;
  2. quotes it and skips the order unless it pays at least the cited price;
  3. takes exactly that much collateral and approves exactly that much;
  4. swaps as the taker, under a gas cap;
  5. settles back any unused collateral, and reverts the whole liquidation if a fill underpays.

  The hook calls the 0.8.30 router across the compiler boundary through an ABI-only interface
  (`src/interfaces/ISwapVMRouter.sol`).
- **The classic fallback (D1).** If the carrier is offline, a keeper calls `markUnhealthy(id)` each round.
  The streak counts consecutive rounds in which the position was unhealthy at that round's live price.
  Any position change, or a successful self-liquidation, resets it; failed attempts don't. After 3 such
  rounds, and with HF below 0.95, **anyone** may repay up to 50% of the debt for collateral at a 5% bonus.
  The streak is counted on chain rather than reconstructed, so the fallback opens only on rounds where
  self-liquidation really was possible and didn't happen. A stateful invariant enforces this.

## The one real conflict: HF-preservation vs protocol-favouring rounding

The two properties *a step never lowers the health factor* and *rounding always favours the protocol*
are opposed at the wei for a single no-bonus sale:
- rounding the collateral sold **up** favours the protocol, but lowers HF;
- rounding it **down** protects HF, but hands the borrower a sliver.

The resolution: **HF-preservation is the headline guarantee for a step**, because self-liquidation exists
to protect the borrower. In the operating regime (over-collateralized by value, HF between the
liquidation threshold and 1), a step never lowers HF. The only erosion is sub-wei rounding of integer
collateral, bounded by one indivisible collateral unit and absorbed by the value margin; the fuzz test
asserts exactly that bound. Protocol-favouring rounding is applied where it belongs instead: the venue's
`minOut` and the debt/collateral accounting. Deeply underwater positions are bad debt that no fair-value
sale can repair; the close factor is already 100% there.

## Threat model

| # | Threat | Mitigation | Where | Proof |
| --- | --- | --- | --- | --- |
| T1 | A stranger triggers a liquidation or bills the account | only the account may call `executeLiquidation`; `selfLiquidate` only from the account itself | `AutolysisMarket.sol`, `AutolysisAccount.sol` | `C1_execute_guard.t.sol::test_strangerCannotCallExecute`; invariants `strangerExecuteNeverBills`, the stranger-liquidation path |
| T2 | A mutated frame tx gets approved (appended key, wrong selector, value, fee over cap, frame-0 mode, calldata) | the fixed canonical shape in VERIFY | `FirewallRules.sol` | `test/fuzz/FirewallRules.t.sol` (single-field mutation fuzz); `Adversarial.t.sol::test_keyAppendRejected`, `test_feeGriefingRejected`; `just scene attacks` |
| T3 | Oracle spike or stale price | 10% band, two-round breaker, K = 4 VERIFY window, 1 h SENDER max age | `RoundFeed.sol` | `RoundFeed.t.sol` (`test_breakerNeedsTwoRounds`, `test_staleRejected`, …); `H1_verify_round.t.sol` |
| T4 | Replaying a round, or retrying a failure at the same price | `lastAttemptRound` advances on success and failure; VERIFY requires a newer round | `AutolysisMarket.sol`, `AutolysisAccount.sol` | `H1::test_alreadyUsedRoundRejected`, `C2_nonce_freeze.t.sol` (`test_failedAttemptBlocksSameRoundRetry`, `test_failedAttemptDoesNotFreezePosition`) |
| T5 | Gas drain through failing liquidations | billing ≤ `min(MAX_COST, cap)` per attempt, one attempt per round, fee cap checked in VERIFY | `AutolysisMarket.sol` | `Adversarial::test_failedAttemptBillingWithinCap`; invariant `feeBilledEqualsAccountEth` |
| T6 | Forged `hookData` claiming a liquidation | authorization on `sender` + the venue's transient flag, never on `hookData` | `BackstopHook.sol` | `BackstopHook.t.sol::test_forgedHookDataGetsVanillaPath`, `test_outsideSwapperMatchesVanilla`; fork `test_outsideSwapperSeesNormalPool` |
| T7 | Sandwiching the sale | tiers 1 and 2 price from the cited oracle round, not reserves; tier 3 is bounded by the venue's `minOut` | `LiquidationPricer.sol`, `BackstopHook.sol`, `V4Venue.sol` | `aqua-fork/test/OraclePricedFill.t.sol` |
| T8 | A hostile or broken maker program in tier 1 | the gate opcode; owner-registered orders; quote gate (≥ cited price); exact approval; per-order gas cap; underpay → revert; leftover settled back | `AutolysisAquaRouterGated.sol`, `BackstopHook.sol` | `C1_SwapVMTier1.t.sol` (stranger / outside-liquidation reverts); fork `C2_OfficialAqua.t.sol` |
| T9 | Reentrancy during the sale | the market's transient "active" flag; the hook's `nonReentrant`; caller checks in the venue | `AutolysisMarket.sol`, `BackstopHook.sol`, `V4Venue.sol` | invariant `activeFlagClear` |
| T10 | Borrower rescue races a pending liquidation | the pending tx's VERIFY re-checks health at execution; a repaid position no longer approves | `AutolysisAccount.sol` | `Adversarial::test_rescueInvalidatesPending` |
| T11 | The classic fallback pre-empting self-liquidation | an on-chain streak of rounds the carrier could act on, reset by any change or success, plus HF < 0.95 | `AutolysisMarket.sol` | `D1_classic.t.sol` (11 tests); invariant `classicNeverPreemptsSelfLiquidation` (non-vacuous) |
| T12 | Insolvent positions leave debt behind | write the shortfall off as bad debt on a full sale, in both paths | `AutolysisMarket.sol` | `H3::test_badDebtWrittenOff`; invariant `noDanglingDebt` (it found the classic-path case) |
| T13 | Conservation errors | totals = sums of positions; the token balance equals total collateral; fees billed = ETH received | `AutolysisMarket.sol` | invariants `collateralConserved`, `debtConserved`, `feeBilledEqualsAccountEth`, `usdcCoversWithdrawable` |

**Trust assumptions and residual risks (not mitigated by code):**
- **Oracle updater:** a single key posts rounds. The band and breaker bound how fast it can move the
  price, not whether it lies.
- **Hook owner:** registers venues and tier-1 orders, and owns the house deposits.
- **Keeper liveness:** the classic fallback only opens if someone calls `markUnhealthy`.
- **Alt mempool behaviour:** admission, relaying and reputation rules are the sidecar's. On the devnet a
  keyed tx sent to the manual-bundling gateway was never relayed; the miner sidecar included one in block
  2865. EXO-010 (keeping honest carriers from being throttled by a market-wide bounce) is a proposal,
  simulated only.
- **Tokens on the devnet are ours** (ETH-backed WETH, mock USDC). The fork proofs use the official v4
  PoolManager and Aqua with test tokens.

# Autolysis v4 build plan

Nov 4, 2026 · @Jay Makwana

What to build for v4, in what order, and how to prove each piece correct. The rule for priority: anything the Ethereum Foundation track depends on comes first, then the Uniswap backstop, then the 1inch Aqua tier, then product polish; streams can still run in parallel, but no phase is called done until its exit tests pass.

## Architecture

&#91;embedded content: Autolysis v4 architecture · one liquidation, three backstop tiers\]

A carrier with no key builds the liquidation; only the alternative mempool admits it; the account validates and pays; the market sells a slice of collateral through the v4 pool, whose hook fills from Aqua makers first, then its own deposits, then the normal curve. The dashed line is the price data the market and the account's VERIFY frame read.

## Components to build

Each component has one guarantee it must never break; the tests in the fuzzing section are written against these.

| Component | What's new in v4 | Must always hold |
| --- | --- | --- |
| `FrameEnv` interface | All frame-opcode reads go through one interface: real opcodes (hegota-support) on the devnet, an injected mock in Foundry | Lets the whole firewall be fuzzed locally even though Forge can't run frame opcodes |
| `FirewallRules` (pure) | Key count exactly 1 and key = H(market, id) with a zero top byte; sequence = liquidation count; first-use state budget; fee cap per the devnet's fee format | Approves exactly one transaction shape per (position, step) |
| `LiquidationMath` (pure) | Close factor rising from 10% at HF 1.00 to 100% at HF 0.95 | A step never lowers the health factor; sells no more than needed |
| `RoundFeed` | Round band, plus a breaker: a move over 10% needs two rounds | A liquidation never uses a price outside the band |
| `AutolysisAccount` | VERIFY with the new checks; never-revert envelope around execution | A failed liquidation can't drain the gas tank |
| `AutolysisMarket` | Gradual sale; transient "liquidation active" flag; settle-before-swap; `TankLedger` (refill, failed-attempt billing, headroom) | Only the account can liquidate; collateral and debt are conserved |
| `BackstopHook` | Custom accounting following OpenZeppelin's base patterns; strategy allowlist; capped maker loop with gas stipends | Any other swapper sees a normal pool; deltas net to zero |
| `AutolysisAquaRouter` | Redeployed SwapVM at one pinned commit with a `LiquidationGate` opcode (taker must be the hook, flag must be on); Decay surcharge | No one outside a liquidation can fill a maker strategy |
| Oracle pricing (`view` Extruction) | Oracle price minus base spread plus volatility add-on | Same quote in `quote()` and `swap()` |
| autolysis-kit | Replacement-based carrier (same key, fee bump on a new round); tank-aware concurrency | Never more pending liquidations than the tank can pay for |
| EXO-010 simulator | Replays crash and bounce traces through the ERC-8421 reputation rules, with and without the proposed rule | Reproducible numbers for the EF write-up |
| App | Borrow (auto-deleverage, rescue), Backstop (coverage, shared-liquidity ratio, reliability), Lab (tank and reputation gauges, attacks), Rescue page | Every number shown comes from on-chain events |

## Phases in priority order

Phases 0–2 secure the Ethereum Foundation track and come first; 3 secures Uniswap, 4 secures 1inch. Streams can start early in parallel (for example, deploying SwapVM during phase 1), but a phase is only done when its exit tests pass.

| Phase | Priority | Build | Exit criteria |
| --- | --- | --- | --- |
| 0. Probe and scaffold | P0 | Repo, `justfile`, deployment registry, `FrameEnv`, devnet probe suite | Probe table pinned: opcode support, fee format, keyed-nonce form, staked external reads, replacement behavior |
| 1. Core engine | P0 (EF) | `LiquidationMath`, `FirewallRules`, `RoundFeed`, `AutolysisMarket`, `AutolysisAccount`, never-revert envelope, `TankLedger` | Unit, fuzz and invariant suites green; **first self-paid liquidation included on the devnet** through the plain v4 curve |
| 2. Mempool behavior | P0 (EF) | Replacement carrier, gradual steps, crash mode, attack builders, tank headroom gauge | Scenes green: rescue, gradual three-step sale, crash (canonical 0, alt 12), replacement keeps reputation flat, every attack rejected |
| 3. Uniswap backstop | P1 (Uniswap) | `BackstopHook` with deposits tier, settle-before-swap, registered-market check, FEEDBACK.md | Hook invariants green for both currency orders; pool-manipulation attack harmless; outside swapper sees a normal pool |
| 4. Aqua tier | P1 (1inch) | Pinned SwapVM redeploy, `AutolysisAquaRouter` with `LiquidationGate`, oracle pricing, template allowlist, maker scripts, waterfall in the hook | SwapVM core invariants green with the gate; outside taker reverts; a fill moves USDC from a maker's wallet; an emptied maker is skipped |
| 5. Product and research | P2 | App pages, EXO-010 simulator, `ISelfLiquidatingMarket` interface, second-collateral adapter skeleton | `just e2e` runs the whole demo; simulator produces the with/without chart |
| 6. Submission | P0 at the end | README with explorer links and line pointers, DESIGN.md, FEEDBACK.md, AI\_USAGE.md, video | All sponsor requirements checked off |

If something must slip, it slips from the bottom of P2 first, and phase 6 is never skipped.

## Fuzzing and test plan

The tests are written before or alongside each component and are the contract the agents build against. Default fuzz runs: 10,000 per property locally, 100,000 in a nightly-style `just fuzz-deep`. Invariant runs: depth 200, 1,000 runs.

### Pure math (Phase 1)

| Property | How |
| --- | --- |
| A liquidation step never lowers the health factor | Fuzz C, D, P, price round, close-factor position; assert HF after ≥ HF before |
| Sell amount is minimal | For computed x, assert selling x − 1 wei would leave HF below target (when the target is reachable) |
| Rounding always favors the protocol | x rounds up, minOut rounds down; fuzz at 1-wei and 1e30 extremes |
| Close factor is monotonic | Fuzz HF in \[0.90, 1.00\]; fraction never decreases as HF falls; exactly 10% at 1.00 and 100% at 0.95 |
| Differential check | The same 50,000 random cases through the Solidity math (via `forge` FFI or exported vectors) and the TypeScript kit; outputs must match to the wei |

### Firewall (Phase 1)

Start from a valid frame context in the `FrameEnv` mock, mutate exactly one field, and assert VERIFY rejects. The mutation fuzzer covers: frame count, frame order, frame mode, target, selector, calldata length, position id, round outside the band, round older than the last liquidation, sequence number, key value, a second nonce key appended, the key's top byte, value not zero, fee above the cap, state limit below the first-use cost, expiry missing or late. **Positive property:** the unmutated canonical transaction always approves when the position is unhealthy at both prices.

### Stateful market invariants (Phase 1–2)

A handler randomly calls borrow, repay, deposit, withdraw, price update, liquidation through the account, direct calls from strangers, and tank refills. After every call:

- Total collateral held by the market equals the sum of position collateral plus sold-out amounts accounted for.
- Total debt equals the sum of position debts; the market's USDC covers what it owes depositors.
- The liquidation count for a position only rises by exactly one per successful step.
- The "liquidation active" flag is never set outside a liquidation call.
- Only the account's calls to `executeLiquidation` change position state via liquidation.
- The envelope never reverts: any failure inside a liquidation returns cleanly and bills at most the failed-attempt cap.
- Tank ledger: tank balance plus all billed fees equals deposits; after 1,000 random liquidations, drift stays within one fee-cap unit.

### Uniswap hook (Phase 3)

- Deltas net to zero for every swap, in **both** currency orderings (deploy pools with WETH as currency0 and as currency1).
- An outside swapper's result matches a vanilla pool with identical liquidity, to the wei.
- A call from an unregistered market follows the vanilla path (ZERO\_DELTA).
- Settle-before-swap: removing the settle step must make the test fail (a mutation check proving the test is meaningful).
- Reentrancy: a malicious token or maker callback attempting to re-enter the market or the hook reverts.

### Aqua and SwapVM (Phase 4)

- Run the pinned SwapVM repository's own core invariants with the `LiquidationGate` opcode added; they must still pass.
- Outside taker: any fill attempt when the taker is not the hook, or when the flag is off, reverts.
- Quote equals fill: fuzz oracle prices and volatility; `quote()` and `swap()` agree.
- Malicious program bytes: fuzz random strategy programs; only allowlisted templates are ever tried.
- Maker withdraws between quote and fill: that maker is skipped, the next tier is used, the liquidation still completes.
- Gas bomb: a maker strategy that burns gas is cut off by the stipend and skipped.
- Waterfall order is respected: tier 2 is touched only when tier 1 can't cover, tier 3 only when both can't.

## Devnet probes and adversarial scenarios

### Probes (Phase 0, rerun before every demo)

The devnet is new and the sidecar follows a draft that differs from the published ERC, so assumptions are checked on chain, not trusted.

| # | Probe | What it settles |
| --- | --- | --- |
| 1 | Opcode support | Which of APPROVE, TXPARAM, FRAMEPARAM, FRAMEDATALOAD, SIGPARAM work on chain 1337 |
| 2 | Fee format | Whether TXPARAM 0x06 returns the total cost or a per-gas price, so the fee cap is computed correctly |
| 3 | Staked external reads | Whether a staked sender's VERIFY can read the market and feed |
| 4 | First-use key cost | That a new key really charges 97,920 state gas from the approving frame's limit |
| 5 | Sequence ceiling | The maximum sequence value accepted per key |
| 6 | Keyed replacement | That a same-key transaction with a 10% higher fee replaces the pending one |
| 7 | Solvency rejection | That a pending set exceeding the tank is rejected, matching SOLVENCY-010 |
| 8 | Reputation counters | That seen and included counters move as expected, including on replacement |

Each probe writes its result to `deployments/probes.json`; the kit and contracts read their constants from there, and a changed result fails the build.

### Adversarial scenarios (Phase 2, extended in 3–4)

| Scenario | Expected outcome |
| --- | --- |
| Rescue in the same block | Borrower repays; the pending liquidation becomes invalid and is dropped without a fee |
| Key-append rebroadcast | An attacker copies the transaction and adds a key; VERIFY rejects it |
| Oracle bounce with 150 pending | Price recovers; pending liquidations invalidate; reputation stays above the throttle line (the EXO-010 chart) |
| Rival with a fake round | A transaction citing an out-of-band round is rejected |
| Fee griefing | A transaction with a fee above the cap is rejected; billing for failed attempts never exceeds the cap |
| Maker rug | A maker empties their wallet before the fill; the waterfall moves to tier 2 |
| Gas-bomb maker | The stipend cuts it off; liquidation completes via the next maker |
| Pool manipulation | Someone moves the v4 pool price; the liquidation's minimum output protects the borrower or the step waits |
| Outside swapper on the backstop pool | Normal swap; makers untouched |
| Classic comparison | The same crash on the classic market pays a 5% bonus to a keeper; the dashboard shows the difference |

## How the harness fits together

| Layer | Runs where | Command | Gate |
| --- | --- | --- | --- |
| 0. Probes | Devnet | `just probe` | Must pass before any deploy |
| 1. Unit and fuzz | Local Foundry with the `FrameEnv` mock | `just test` | Every commit |
| 2. Integration and invariants | Local Foundry with v4 and pinned SwapVM deployed in tests | `just invariants` | Before a phase is closed |
| 3. Devnet scenes | Devnet through the kit | `just scene <name>` / `just e2e` | Before a phase is closed and before the demo |

Supporting rules:

- **One source of addresses.** `deployments/1337.json` is written by deploy scripts and read by the kit, app and scenes; nothing hard-codes an address.
- **Reset fast.** `just reset` redeploys and seeds everything in under three minutes, so a broken devnet state never blocks a demo.
- **Mock and reality agree.** Every firewall scene on the devnet has a matching mock test; if a scene passes on-chain but its mock fails (or the reverse), the mock is fixed before anything else.
- **Agents work against tests.** Each workstream's agent gets its component's "must always hold" row and its tests first; it isn't done until `just test` and its scenes pass.
- **Pinned versions.** v4-core, SwapVM, Aqua and hegota-support are pinned to exact commits in `foundry.toml` and `package.json`.

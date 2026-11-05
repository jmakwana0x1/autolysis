# Autolysis plan v4.4

This plan replaces the schedule in PLAN-v4.3. Where they differ, DEVNET.md wins. Label every status line with one of: **on devnet**, **on fork**, **local test**, **mock only**, **written, not run**.

## Where we are (HEAD 512b522)
- **Locally:** core, firewall, math, hook/venue, gated Aqua fill and EXO-010 sim are green in local tests.
- **Devnet facts are applied:** ARBITRARY signature, staking registry, predeployed v4 flag, simulate-based probes.
- **On a real chain:** nothing yet. `deployments/1337.json` is empty.
- **VERIFY gas** is measured only on the mock (131k with outside reads, 98.5k storage-only). The real number is unknown.
- **Not built:** VERIFY slimming (`loadCanonical`), the hook calling the gated SwapVM router, the backstop-vault shares, the lender fallback `classicLiquidate`, the dashboard and the video.

## Who runs what
- **Laptop agent** (Claude Code on the user's laptop, which can reach the devnet; uses a devnet-only key): everything that needs the devnet or the Unichain RPC.
- **Cloud agent:** everything that doesn't, in parallel.

---

## Phase A: devnet bring-up
| # | Who | Step | Exit |
|---|---|---|---|
| A1 | cloud | **Slim VERIFY.** `IFrameEnv.loadCanonical()` returns a FIXED-size struct: frameCount; frame0 allowedScope and stateLimit; frame1 mode, resolvedTarget, value, dataLength and 3 calldata words; nonceKeyCount; nonceKey0; nonce seq; maxCost. That's about 13 opcode reads instead of ~24, with no dynamic ABI encoding. Adapt FirewallRules and keep the mutation fuzz green. Drop the `Approved` event. Make MockFrameEnv cost-realistic (immutables, not one cold SLOAD per field). | Both paths' mock gas reported; suites green; pushed |
| A2 | laptop | Faucet the deployer and owner keys → `Deploy.s.sol` with `USE_PREDEPLOYED_V4=true`. Use legacy txs at 0.002 gwei and up to 6M gas per deploy (`--skip-simulation` if forge misjudges state gas). | `deployments/1337.json` filled; every address has code (**on devnet**) |
| A3 | laptop | Stake the account: owner legacy tx → `account.stake{value: 0.012 ether}(86400)` | `getDepositInfo` shows the stake; `skandha_explorer_listReputation` shows it staked |
| A4 | laptop | Pull A1, redeploy the account if needed. `ethrex_simulateFrameTransaction` on **both** VERIFY paths: record `frames[0].gasUsed`, `valid` and `violation`. | Numbers recorded in `probes.json` |
| A5 | laptop | **Decision.** If the outside-reads path is at most 99,900 minus a small margin, ship it. Otherwise use storage-only, with the snapshot written by the price push (`RoundFeed` → market → account), so no separate pusher is needed. | Path chosen and written in STATUS |
| A6 | laptop | Send the same liquidation to the canonical mempool (`eth_sendRawTransaction`) and record the exact result. | Exact text saved for the dashboard |
| A7 | laptop | **First liquidation:** push an unhealthy price round → build → simulate → `eth_sendFrameTransaction` → receipt → explorer link | **Gate A: one keyless self-paid liquidation included, through the official PoolManager** |

If gate A fails, stop and report the exact violation text. Don't keep piling on changes.

## Phase B: EF and Uniswap scenes on the devnet
| # | Scene | Exit |
|---|---|---|
| B1 | **Crash:** 12 positions on 12 keys; canonical result for each; alt result for each; all 12 included | Explorer links; the exact canonical-vs-alt numbers (whatever A5 and A6 make true) |
| B2 | **Replacement:** same key and sequence, both fees +10%, new round → the old tx is replaced | `skandha_frameTransactionStatus` shows the replacement |
| B3 | **Attacks:** appended second key, wrong selector, fee over cap, stale round; each rejected | Rejection text for each, via simulate or send |
| B4 | **Uniswap proof:** for one liquidation, before/after balances for borrower, pool, hook (0 tokens, 0 claims) and maker/house; it goes through the official PoolManager `0x6bF9…9848` | Links plus balance table in the README |
| B5 | **Live reputation:** `skandha_explorer_listReputation` before and after the crash; feed the real counters into the EXO-010 chart beside the simulation | Chart shows "measured" and "simulated" |

## Phase C: 1inch (cloud agent first, then the laptop runs the fork test)
| # | Step | Exit |
|---|---|---|
| C1 | One forge test: deploy Aqua and `AutolysisAquaRouterGated` from the aqua-fork artifacts (`vm.deployCode`); BackstopHook tier 1 calls it through `ISwapVMRouter` as taker inside a full V4Venue liquidation | Maker wallet USDC down, WETH up; stranger fill reverts with `LiquidationGateClosed` (**local test**) |
| C2 | The same test as a fork test against the **official Aqua registry** `0x1111113ccf1426a8e30e2bff5e005d929bf6a90a` on Unichain (`--fork-url`) | Laptop runs it; trace saved (**on fork**) |
| C3 | Stretch, only if B is done: deploy Aqua (official source) and the gated router on the devnet so tier 1 fills live in the crash scene | **on devnet**, labelled "official source, self-deployed" |

## Phase D: protect and package
| # | Item | Cut order if needed |
|---|---|---|
| D1 | `classicLiquidate()`: below HF 0.95, after 3 rounds with no self-liquidation, a 5% bonus opens to anyone, with a test | 2nd to cut; otherwise list it as a limitation |
| D2 | Backstop vault with pro-rata shares and `earned` (the LP-value story) | 1st to cut; then pitch the house tier verbally |
| D3 | **One dashboard page** from on-chain events: crash button, 12 positions, canonical-vs-alt panel with real texts, tx lifecycle, tier filled, net saved, EXO-010 chart | Never cut (it can be minimal) |
| D4 | README: problem with numbers; net-cost table; diagram; explorer links per environment; sponsor table with file:line pointers; limitations; history note (below) | Never cut |
| D5 | `FEEDBACK.md` (Uniswap, with real friction) + the form; DESIGN.md threat model; EF write-up (app + tooling + scoped EXO-010); `AI_USAGE.md` | Never cut |

**History note for the README (required):** "This repository was restored after the original was accidentally deleted. The commits were replayed in their original order, so their timestamps show the restore rather than when each change was first written."

Feature freeze after Phase D.

## Phase E: ship
- Record the 3-minute video: devnet crash, then the transaction in the explorer, then the Uniswap balances, then the Aqua fork fill, then net savings and EXO-010.
- Record a labelled backup run on a local chain as well.
- Submit with three sponsors: EF alt mempool, Uniswap, 1inch. Fill in the Uniswap feedback form.

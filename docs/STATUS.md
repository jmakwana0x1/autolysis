# Status

| Phase | State | Notes |
| --- | --- | --- |
| 0. Probe and scaffold | Scaffold done; probes unpinned | Probe suite written; not run against a devnet (none in this build env). `deployments/probes.json` holds the plan's assumptions with `pinned: false`. Sidecar `alt_*` RPC names in probes 2–8 are placeholders to confirm against the real sidecar. |
| 1. Core engine | Local suites green | LiquidationMath, FirewallRules, RoundFeed, TankLedger, AutolysisMarket, AutolysisAccount (never-revert envelope), MockFrameEnv/MockCurve. Unit + fuzz (10k) + differential (kit vs Solidity) + stateful invariants (1000 runs × depth 200, 200k calls) all green. First self-paid liquidation proven locally through the plain curve via the canonical VERIFY→SENDER frame tx. **Devnet inclusion still pending** (needs RPC). |

| 2. Mempool behavior | Local suites green | Replacement carrier (tank-aware concurrency, 10% fee-bump keyed replacement), attack builders, and the adversarial scenarios as Foundry mock tests: rescue invalidates a pending liquidation, gradual three-step sale (HF never falls), key-append / fake-round / fee-griefing rejected, failed-attempt billing within the cap. Carrier + attack builders covered by vitest. Devnet scenes stubbed (need RPC); each names its matching local test. |

## Running the suites

```bash
just test         # unit + fuzz + differential (every commit)
just invariants   # stateful market invariants (~3 min at default depth)
FOUNDRY_PROFILE=quick forge test   # fast local loop
cd kit && npx vitest run           # kit unit tests
cd kit && VECTORS=50000 npx tsx scripts/gen-vectors.mjs   # regenerate full differential vectors
```

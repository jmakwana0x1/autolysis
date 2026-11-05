# AI_USAGE.md

This project was built in a single agent session with Claude Code (Claude Opus).

## How the agent worked

- **Test-first, against the plan's guarantees.** Each component's "must always hold" row from the build
  plan was turned into fuzz/invariant properties before or alongside the implementation. Where a
  property could not hold as literally stated (see the HF-vs-rounding conflict in `DESIGN.md`), the
  agent surfaced the conflict, chose a resolution, and encoded the honest bounded version rather than
  weakening the test silently.
- **Phase by phase.** Phases 0–5 were implemented, tested green locally, committed, and pushed in order.
  Every commit records the model and session.
- **Real dependencies where available.** The Uniswap v4 hook is built and fuzzed against the vendored
  `v4-core` `PoolManager`; the agent debugged a real `manager.take` reserve-underflow against the live
  manager and documented the fix in `FEEDBACK.md`.

## What the agent generated

All Solidity, the TypeScript kit (frame-tx codec, replacement carrier, probes, EXO-010 simulator), the
test suites, the `justfile`/harness wiring, and the docs. The architecture and phase priorities come
from the human-authored `docs/BUILD_PLAN.md`.

## Limits and honesty

The Hegota devnet frame opcodes and the 1inch SwapVM/Aqua engine are not available in the build
environment, so they are modeled behind interfaces and pinned in `deployments/probes.json`, not vendored
(see `DESIGN.md`). `docs/STATUS.md` states precisely what is proven locally versus what still requires a
devnet (notably on-chain liquidation inclusion and the live app pages). No test is skipped or weakened to
appear green; the devnet-only scenes throw a clear "requires RPC" error and each names its matching local
mock test.

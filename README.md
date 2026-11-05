# Autolysis v4

Self-liquidating lending: a keyless carrier builds each liquidation, only the alternative mempool
admits it, the `AutolysisAccount` validates and pays from the borrower-funded gas tank, and the
market sells a slice of collateral through a Uniswap v4 pool whose hook fills from 1inch Aqua makers
first, then its own deposits, then the normal curve.

See `docs/BUILD_PLAN.md` for the phase plan. Status per phase is tracked in `docs/STATUS.md`.

## Layout

| Path | What |
| --- | --- |
| `src/frame/` | `IFrameEnv` (the one door for frame-opcode reads), devnet adapter, cell assembler |
| `src/generated/` | Constants generated from `deployments/probes.json` (`just gen`) |
| `deployments/` | `1337.json` (addresses, written by deploy scripts), `probes.json`, `pins.json` |
| `test/` | Foundry unit / fuzz / invariant suites (`test/mocks/MockFrameEnv.sol` stands in for frame opcodes) |
| `kit/` | autolysis-kit (TypeScript): frame-tx codec, carrier, probes, scenes |

## Commands

```bash
just test         # unit + fuzz, every commit
just invariants   # stateful invariants
just fuzz-deep    # 100k runs per property
just probe        # devnet probes (needs RPC_URL); then `just gen`
just scene <name> # one devnet scene
just e2e          # whole demo
just reset        # redeploy + seed
```

Toolchain: Foundry (solc 0.8.26, cancun), `just`, Node 22.

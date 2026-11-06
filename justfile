set dotenv-load := true

export PATH := env_var('HOME') + "/.foundry/bin:" + env_var('PATH')

default:
    @just --list

# One-time setup for a fresh clone: build the vendored hegota-support TS package (its dist/ is gitignored)
setup:
    cd lib/hegota-support && npm install --no-audit --no-fund && npm run build
    cd kit && npm install --no-audit --no-fund

# Regenerate Solidity constants from deployments/probes.json
gen:
    node kit/scripts/gen-constants.mjs

build:
    forge build

# Build the 0.8.30 SwapVM/Aqua fork into out-aqua/ (the main suite deploys it via vm.deployCode)
aqua-build:
    FOUNDRY_PROFILE=aqua forge build

# Unichain mainnet fork proofs against OFFICIAL contracts, pinned to block 63190327 (override rpc/block).
# Each prints PASS/FAIL and a before/after balance table, and saves the full trace in deployments/.
# Uniswap: a full self-liquidation through the official v4 PoolManager 0x1F98…0004.
fork-uniswap rpc="https://mainnet.unichain.org" block="63190327":
    UNICHAIN_RPC_URL={{rpc}} UNICHAIN_FORK_BLOCK={{block}} ./scripts/fork-test.sh "Uniswap: official PoolManager" test/fork/UniswapOfficialPoolManager.t.sol deployments/uniswap-fork-trace.txt

# 1inch (C2): hook tier 1 through our gated SwapVM router into the official Aqua 0x1111…a90a, on the official PoolManager.
fork-c2 rpc="https://mainnet.unichain.org" block="63190327": aqua-build
    UNICHAIN_RPC_URL={{rpc}} UNICHAIN_FORK_BLOCK={{block}} ./scripts/fork-test.sh "1inch: official Aqua (C2)" test/fork/C2_OfficialAqua.t.sol deployments/c2-fork-trace.txt

# Both fork proofs
fork-all: fork-uniswap fork-c2

# Layer 1: unit + fuzz (10,000 runs per property), every commit
test: aqua-build
    forge test --no-match-path "test/invariant/*"

# Layer 2: integration + stateful invariants (depth 200, 1,000 runs)
invariants:
    forge test --match-path "test/invariant/*"

# Nightly-style deep fuzz (100,000 runs per property)
fuzz-deep:
    FOUNDRY_PROFILE=deep forge test

# Fast local loop
quick:
    FOUNDRY_PROFILE=quick forge test

# Phase A on the devnet in one unattended, idempotent run: deploy, stake, simulate both VERIFY paths and
# choose, canonical attempt, first liquidation. Records everything in deployments/1337.json.
gate-a:
    cd kit && CHAIN_ID=1337 npx tsx src/gateA/run.ts

# D3 dashboard on http://127.0.0.1:5173 for CHAIN_ID (default 1337) via RPC_URL (default the gateway)
dashboard:
    CHAIN_ID=${CHAIN_ID:-1337} node app/server.mjs

# Local demo: anvil + mock frame node, gate-a, crash, reputation, then the dashboard (stays up)
demo-local:
    KEEP_RUNNING=1 ./kit/scripts/gate-a-local.sh

# gate-a against anvil + a MOCK frame node (frame RPCs canned / SENDER frame emulated), run twice
gate-a-local:
    ./kit/scripts/gate-a-local.sh

# Layer 0: devnet probes (needs RPC_URL and PROBE_PK); writes deployments/probes.json
probe:
    cd kit && npm run --silent probe
    just gen

# Phase B, one devnet scene: crash | replace | attacks | uniswap-balances (needs a passed `just gate-a`)
scene name arg="":
    cd kit && CHAIN_ID=${CHAIN_ID:-1337} npx tsx src/scenes/run.ts {{name}} {{arg}}

# Snapshot skandha_explorer_listReputation for the account (label e.g. before/after) into the EXO-010 data
reputation label="manual":
    cd kit && CHAIN_ID=${CHAIN_ID:-1337} npx tsx src/scenes/run.ts reputation {{label}}

# Phase B end to end on the devnet
e2e:
    just reputation before
    just scene crash
    just scene replace
    just scene attacks
    just scene uniswap-balances
    just reputation after

# Run the EXO-010 reputation simulator and refresh the Lab chart data (no devnet needed)
sim:
    cd kit && node scripts/gen-exo010-chart.mjs

# Redeploy and seed everything on a local anvil (writes deployments/<chainid>.addresses.json)
reset:
    forge script script/Deploy.s.sol:Deploy --rpc-url $RPC_URL --broadcast --slow --private-key $PRIVATE_KEY
    cd kit && npm run --silent seed

# Build/test the isolated SwapVM/Aqua fork (solc 0.8.30, OZ 5.6.1) under the SwapVM-1.1 license
aqua:
    FOUNDRY_PROFILE=aqua forge test

fmt:
    forge fmt

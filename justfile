set dotenv-load := true

export PATH := env_var('HOME') + "/.foundry/bin:" + env_var('PATH')

default:
    @just --list

# Regenerate Solidity constants from deployments/probes.json
gen:
    node kit/scripts/gen-constants.mjs

build:
    forge build

# Layer 1: unit + fuzz (10,000 runs per property), every commit
test:
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

# Layer 0: devnet probes (needs RPC_URL and PROBE_PK); writes deployments/probes.json
probe:
    cd kit && npm run --silent probe
    just gen

# Layer 3: one devnet scene through the kit
scene name:
    cd kit && npm run --silent scene -- {{name}}

e2e:
    cd kit && npm run --silent e2e

# Run the EXO-010 reputation simulator and refresh the Lab chart data (no devnet needed)
sim:
    cd kit && node scripts/gen-exo010-chart.mjs

# Redeploy and seed everything on the devnet (target: < 3 minutes)
reset:
    forge script script/Deploy.s.sol --rpc-url $RPC_URL --broadcast --slow
    cd kit && npm run --silent seed

fmt:
    forge fmt

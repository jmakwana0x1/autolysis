#!/usr/bin/env bash
# `just gate-a-local`: run the real gate-a flow against anvil + the MOCK frame node, twice (the second run
# proves idempotence). Writes deployments/31337.json (gitignored). Labels: deploy/legacy/SENDER emulation
# are local test; every frame-RPC answer is mock.
set -euo pipefail
export PATH="$HOME/.foundry/bin:$PATH"
cd "$(dirname "$0")/../.."
REG=0xD51c04d7A0B01124E84DE152F4e56d9eeCB22D2F
PK0=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80   # anvil's well-known key 0
forge build >/dev/null
rm -f deployments/31337.json deployments/31337.addresses.json
anvil --port 8546 --chain-id 31337 --block-base-fee-per-gas 0 --silent & ANVIL=$!
trap 'kill $ANVIL ${MOCK:-} 2>/dev/null || true' EXIT
for _ in $(seq 50); do cast chain-id --rpc-url http://127.0.0.1:8546 >/dev/null 2>&1 && break; sleep 0.2; done
cast rpc --rpc-url http://127.0.0.1:8546 anvil_setCode $REG \
  "$(jq -r .deployedBytecode.object out/NaiveStakingRegistry.sol/NaiveStakingRegistry.json)" >/dev/null
(cd kit && ANVIL_URL=http://127.0.0.1:8546 MOCK_PORT=8547 exec node --import tsx src/gateA/mockNode.ts) & MOCK=$!
for _ in $(seq 50); do cast chain-id --rpc-url http://127.0.0.1:8547 >/dev/null 2>&1 && break; sleep 0.2; done
run() { (cd kit && CHAIN_ID=31337 PRIVATE_KEY=$PK0 RPC_URL=http://127.0.0.1:8547 ETHREX_URL=http://127.0.0.1:8547 FRAME_RPC_URL=http://127.0.0.1:8547 \
  STAKING_REGISTRY=$REG GATE_A_POLL_MS=200 npx tsx src/gateA/run.ts); }
echo "=== gate-a run 1"; run
echo "=== gate-a run 2 (idempotence)"; run
# Phase B scenes that anvil + the mock node can actually execute (crash: 12 SENDER-frame liquidations
# emulated; uniswap-balances; reputation). attacks/replace need real VERIFY + the real mempool: unit-tested
# in kit/test/scenes.test.ts, devnet only.
scene() { (cd kit && CHAIN_ID=31337 PRIVATE_KEY=$PK0 RPC_URL=http://127.0.0.1:8547 ETHREX_URL=http://127.0.0.1:8547 FRAME_RPC_URL=http://127.0.0.1:8547 \
  GATE_A_POLL_MS=200 npx tsx src/scenes/run.ts "$@"); }
if [ "${PHASE_B:-1}" = "1" ]; then
  echo "=== scene crash";            scene crash | tail -12
  echo "=== scene uniswap-balances"; scene uniswap-balances | tail -4
  echo "=== reputation after";       scene reputation after | tail -2
fi
# `just demo-local`: keep anvil + the mock node up and serve the dashboard against them (Ctrl-C stops all).
if [ "${KEEP_RUNNING:-0}" = "1" ]; then
  echo "=== dashboard (local chain 31337, frame RPCs mocked)"
  CHAIN_ID=31337 RPC_URL=http://127.0.0.1:8547 ETHREX_URL=http://127.0.0.1:8547 FRAME_RPC_URL=http://127.0.0.1:8547 PRIVATE_KEY=$PK0 GATE_A_POLL_MS=200 \
    node app/server.mjs
fi

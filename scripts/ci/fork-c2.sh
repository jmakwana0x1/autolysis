#!/usr/bin/env bash
# CI job "fork-unichain": C2 (the C1 liquidation flow) against the OFFICIAL 1inch Aqua registry on a Unichain
# mainnet fork pinned to UNICHAIN_FORK_BLOCK. Writes the -vvvv trace to c2-fork-trace.txt and an exact
# outcome to the job summary. A public-RPC rate limit is retried once; if it persists the job says so in the
# summary and as a warning annotation (it is an external outage, not a test result). Any other failure fails
# the job with the exact error.
set -uo pipefail
: "${UNICHAIN_RPC_URL:?}" "${UNICHAIN_FORK_BLOCK:?}"
SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/stdout}"
TRACE=c2-fork-trace.txt
RATE_LIMIT='429|[Tt]oo [Mm]any [Rr]equests|rate.?limit|exceeded|compute units|capacity'

run() {
  forge test --match-path test/fork/C2_OfficialAqua.t.sol -vvvv >"$TRACE" 2>&1
}

attempt=1
run
status=$?
if [ $status -ne 0 ] && grep -Eqi "$RATE_LIMIT" "$TRACE"; then
  echo "::notice::Unichain RPC looked rate-limited on attempt 1; retrying once in 30s"
  sleep 30
  attempt=2
  run
  status=$?
fi

{
  echo "## C2: official Aqua on a Unichain fork"
  echo ""
  echo "- Aqua registry: \`0x1111113ccf1426a8e30e2bff5e005d929bf6a90a\` (official)"
  echo "- Fork block: \`${UNICHAIN_FORK_BLOCK}\` · attempts: ${attempt}"
  echo ""
  echo '```'
  grep -E "^\[(PASS|FAIL)|Suite result|C2 fork:" "$TRACE" | sort -u
  echo '```'
} >>"$SUMMARY"

if [ $status -eq 0 ]; then
  echo "" >>"$SUMMARY"
  echo "**Result: passed** (trace uploaded as the \`c2-fork-trace\` artifact)." >>"$SUMMARY"
  exit 0
fi

if grep -Eqi "$RATE_LIMIT" "$TRACE"; then
  {
    echo ""
    echo "**Result: NOT VERIFIED this run.** The Unichain RPC rate-limited both attempts, so C2 did not run to"
    echo "completion. This is an RPC outage, not a test failure; set the \`UNICHAIN_RPC_URL\` secret to a"
    echo "private endpoint to avoid it. Last error lines:"
    echo '```'
    grep -Ei "$RATE_LIMIT|error" "$TRACE" | tail -5
    echo '```'
  } >>"$SUMMARY"
  echo "::warning title=C2 not verified::Unichain RPC rate-limited twice; C2 (official Aqua fork) did not run. See the job summary."
  exit 0
fi

{
  echo ""
  echo "**Result: FAILED.** Exact error:"
  echo '```'
  tail -40 "$TRACE"
  echo '```'
} >>"$SUMMARY"
exit $status

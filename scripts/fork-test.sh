#!/usr/bin/env bash
# Run one Unichain-mainnet fork proof against OFFICIAL contracts, pinned to a block.
#   scripts/fork-test.sh <title> <test-path> <trace-file>
# Env: UNICHAIN_RPC_URL (required), UNICHAIN_FORK_BLOCK (required, e.g. 63190327).
# Prints PASS/FAIL lines and the test's before/after balance table, saves the -vvvv trace. In CI
# (GITHUB_STEP_SUMMARY set) it also writes the table and result to the job summary, retries once if the
# public RPC rate-limits, and if it still cannot reach the RPC says so loudly (summary + warning) instead of
# failing on an outage. Any real test failure exits non-zero with the exact error.
set -uo pipefail
TITLE="$1"; TEST="$2"; TRACE="$3"
: "${UNICHAIN_RPC_URL:?}" "${UNICHAIN_FORK_BLOCK:?}"
export UNICHAIN_RPC_URL UNICHAIN_FORK_BLOCK
SUMMARY="${GITHUB_STEP_SUMMARY:-}"
RATE_LIMIT='429|[Tt]oo [Mm]any [Rr]equests|rate.?limit|exceeded|compute units|capacity'

run() { forge test --match-path "$TEST" -vvvv >"$TRACE" 2>&1; }
table() { sed -n '/^  ### /,/^  \(Waterfall\|Aqua\):/p' "$TRACE" | sed 's/^  //'; }

attempt=1
run; status=$?
if [ $status -ne 0 ] && [ -n "$SUMMARY" ] && grep -Eqi "$RATE_LIMIT" "$TRACE"; then
  echo "::notice::Unichain RPC looked rate-limited on attempt 1; retrying once in 30s"
  sleep 30; attempt=2
  run; status=$?
fi

grep -E "^\[(PASS|FAIL)|Suite result|fork: Unichain block" "$TRACE" | sort -u
echo
table

if [ -n "$SUMMARY" ]; then
  {
    echo "## ${TITLE}"
    echo ""
    echo "Unichain mainnet fork, block \`${UNICHAIN_FORK_BLOCK}\`, official contracts · attempts: ${attempt}"
    echo ""
    echo '```'
    grep -E "^\[(PASS|FAIL)|Suite result" "$TRACE" | sort -u
    echo '```'
    echo ""
    table
    echo ""
  } >>"$SUMMARY"
fi

[ $status -eq 0 ] && exit 0

if [ -n "$SUMMARY" ] && grep -Eqi "$RATE_LIMIT" "$TRACE"; then
  {
    echo "**Result: NOT VERIFIED this run.** The Unichain RPC rate-limited both attempts (an outage, not a test"
    echo "result). Set the \`UNICHAIN_RPC_URL\` secret to a private endpoint. Last error lines:"
    echo '```'; grep -Ei "$RATE_LIMIT|error" "$TRACE" | tail -5; echo '```'
  } >>"$SUMMARY"
  echo "::warning title=${TITLE} not verified::Unichain RPC rate-limited twice; see the job summary."
  exit 0
fi

echo "FAILED. Exact error:"; tail -40 "$TRACE"
if [ -n "$SUMMARY" ]; then
  { echo "**Result: FAILED.** Exact error:"; echo '```'; tail -40 "$TRACE"; echo '```'; } >>"$SUMMARY"
fi
exit $status

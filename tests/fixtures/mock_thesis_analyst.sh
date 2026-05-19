#!/usr/bin/env bash
# tests/fixtures/mock_thesis_analyst.sh
#
# Stand-in for the `praescientia-thesis-analyst` Haiku sub-agent during
# scripts/orchestrator_smoke.sh. Reads tick_id + thesis_id (+ optional
# ticker) from argv, emits a deterministic valid decision JSON to stdout.
#
# The output is the same shape an operator's prose-stripping pipeline
# (see .claude/skills/praescientia-orchestrate/tick.md § step 8.a) would
# produce after running the real agent's response through
# `python3 -c "...re.search(r'\{.*\}', stdin, DOTALL)..."`.
#
# We deliberately emit a tiny leading prose blurb + closing remark so the
# smoke harness exercises the prose-stripping path end-to-end. Real Haiku
# does this in practice — both the thesis-analyst and loss-reflector dry
# runs (tests/fixtures/agent_outputs/*_dry_run.json) confirm.
#
# Usage:
#   mock_thesis_analyst.sh <tick_id> <thesis_id> [ticker]
#
# Exit codes:
#   0  — emitted decision JSON
#   2  — bad arguments

set -euo pipefail

if [[ $# -lt 2 ]]; then
    echo "usage: $0 <tick_id> <thesis_id> [ticker]" >&2
    exit 2
fi

TICK_ID="$1"
THESIS_ID="$2"
TICKER="${3:-SAMPLE}"

# Sanity-check tick_id length (must be 26-char ULID).
if [[ ${#TICK_ID} -ne 26 ]]; then
    echo "tick_id must be 26-char ULID; got ${#TICK_ID} chars" >&2
    exit 2
fi

cat <<EOF
Here is my analysis for thesis ${THESIS_ID}:

{"tick_id":"${TICK_ID}","confidence_bp":5000,"rationale":"[mock] smoke-test decision for ${THESIS_ID}: confidence at 50%, one small buy on ${TICKER} at 50c.","commentary_body":"Mock sub-agent output used by scripts/orchestrator_smoke.sh. Validates the full lifecycle (begin → fan-out → validate → execute → finish → status → rollback) without calling a real Haiku endpoint.","commentary_tags":["smoke","mock"],"orders":[{"ticker":"${TICKER}","side":"yes","action":"buy","size":1,"limit_cents":50,"reason":"smoke test"}]}

That concludes the analysis.
EOF

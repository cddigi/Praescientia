#!/usr/bin/env bash
# tests/fixtures/mock_loss_reflector.sh
#
# Stand-in for the `praescientia-loss-reflector` Haiku sub-agent during
# scripts/orchestrator_smoke.sh's settlement scenario. Reads tick_id +
# thesis_id + ticker from argv, emits a deterministic valid §8 reflection
# wrapped in deliberate prose so the smoke exercises step 8.a's
# prose-stripping pipeline against the loss-reflector path too.
#
# Usage:
#   mock_loss_reflector.sh <tick_id> <thesis_id> <ticker>
#
# Exit codes:
#   0  — emitted reflection JSON
#   2  — bad arguments

set -euo pipefail

if [[ $# -lt 3 ]]; then
    echo "usage: $0 <tick_id> <thesis_id> <ticker>" >&2
    exit 2
fi

TICK_ID="$1"
THESIS_ID="$2"
TICKER="$3"

if [[ ${#TICK_ID} -ne 26 ]]; then
    echo "tick_id must be 26-char ULID; got ${#TICK_ID} chars" >&2
    exit 2
fi

cat <<EOF
Performing the diagnostic audit before emitting the reflection.

{"tick_id":"${TICK_ID}","what_we_believed":"Smoke-mock: we held confidence at 1800bp NO on ${TICKER} for several ticks despite material volume movement.","what_actually_happened":"Smoke-mock: ${TICKER} resolved YES; the bid drifted from 28c to 65c with volume showing up at 22c we did not act on.","why_we_were_wrong":"Smoke-mock: We mistook the liquidity-cap quote at the lower rung for a probability signal, then failed to re-evaluate when fresh volume arrived. The framework permitted a 100bp update per tick; we never issued one because we applied a static interpretation.","decision_pattern_to_avoid":"Smoke-mock: When the market condition that anchored the thesis (thin liquidity here) changes, force a re-evaluation in the next tick.","tags":["smoke","mock","illiquidity-edge-invalidation"]}

This concludes the post-mortem.
EOF

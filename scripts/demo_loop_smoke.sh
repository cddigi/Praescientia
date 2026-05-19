#!/usr/bin/env bash
# scripts/demo_loop_smoke.sh — exercise the full KB demo loop against the
# Kalshi demo API. Verifies that the pieces wired up in PRs #34/#36/#40
# actually communicate end-to-end: init → add-market → add-thesis → poll →
# predict → divergence.
#
# Prerequisites:
#   - .secret/kalshi_api_key_id.txt + .secret/kalshi_api_key_private.txt
#   - `zig build` has produced the praescientia-* binaries in ./zig-out/bin/
#   - Network access to demo-api.kalshi.co
#   - jq on $PATH (for ticker discovery)
#
# Exit codes:
#   0 — every step succeeded; market reality, thesis reality, and prediction
#       chains all grew; divergence call returned a sensible answer.
#   1 — something failed; check stderr for which step.

set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/zig-out/bin"

if [ ! -x "$BIN/praescientia-test-conn" ]; then
    echo "FAIL: ./zig-out/bin/praescientia-test-conn missing — run 'zig build' first" >&2
    exit 1
fi
if [ ! -f "$ROOT/.secret/kalshi_api_key_id.txt" ] || [ ! -f "$ROOT/.secret/kalshi_api_key_private.txt" ]; then
    echo "FAIL: .secret/kalshi_api_key_{id,private}.txt missing" >&2
    exit 1
fi

# 1) Baseline connectivity. If this fails, no point continuing.
echo "==> 1/7 baseline connectivity to demo-api.kalshi.co"
"$BIN/praescientia-test-conn" --env=demo >/dev/null

# 2) Pick the first actively-trading demo ticker. validateMarket now accepts
#    alphanumeric + `-` + `.`, which covers every Kalshi ticker shape observed
#    so far (including threshold suffixes like `T87.99`).
echo "==> 2/7 discover a demo market ticker"
TICKER=$(
    "$BIN/praescientia-markets" list --limit=10 --status=open --env=demo |
    jq -r '.markets[].ticker' |
    head -n1
)
if [ -z "$TICKER" ]; then
    echo "FAIL: no open demo market available" >&2
    exit 1
fi
echo "    using $TICKER"

# 3) Fresh tmp kb_root; cleanup on exit.
TMPROOT=$(mktemp -d)
KB_ROOT="$TMPROOT/kb"
trap "rm -rf $TMPROOT" EXIT

echo "==> 3/7 init kb_root at $KB_ROOT"
"$BIN/praescientia-kb" init "$KB_ROOT" >/dev/null
"$BIN/praescientia-kb" add-market "$TICKER" --kb-root="$KB_ROOT" >/dev/null
"$BIN/praescientia-kb" add-thesis demo-smoke \
    --description="demo loop smoke" \
    --weights="{\"$TICKER\":10000}" \
    --confidence-delta-bp=100 \
    --kb-root="$KB_ROOT" >/dev/null

# 4) Poll the live demo API and write to the kb.
echo "==> 4/7 poll demo API"
"$BIN/praescientia-poll-markets" --kb-root="$KB_ROOT" --env=demo

# 5) Verify both chains grew.
MARKET_JSONL="$KB_ROOT/markets/$TICKER/reality/main.jsonl"
THESIS_JSONL="$KB_ROOT/theses/demo-smoke/reality/main.jsonl"
market_count=$(wc -l < "$MARKET_JSONL" | tr -d ' ')
thesis_count=$(wc -l < "$THESIS_JSONL" | tr -d ' ')

echo "==> 5/7 chain sizes: market=$market_count thesis=$thesis_count"
if [ "$market_count" -lt 1 ]; then
    echo "FAIL: market reality chain did not grow" >&2
    exit 1
fi
if [ "$thesis_count" -lt 1 ]; then
    echo "FAIL: thesis reality chain did not grow (rollup registration?)" >&2
    exit 1
fi

# 6) Record a prediction and confirm the prediction chain has one entry.
echo "==> 6/7 record a prediction"
"$BIN/praescientia-kb" predict demo-smoke \
    --confidence-bp=6500 \
    --rationale="demo_loop_smoke baseline" \
    --kb-root="$KB_ROOT" >/dev/null
PRED_JSONL="$KB_ROOT/theses/demo-smoke/prediction/main.jsonl"
pred_count=$(wc -l < "$PRED_JSONL" | tr -d ' ')
if [ "$pred_count" -ne 1 ]; then
    echo "FAIL: expected 1 prediction, found $pred_count" >&2
    exit 1
fi

# 7) Compute divergence. We don't assert a specific drift because demo-market
#    pricing changes between runs; we only assert the command exits 0 and
#    prints either a divergence row or the no-divergence sentinel.
echo "==> 7/7 compute divergence"
DIVOUT=$("$BIN/praescientia-kb" divergence \
    "$KB_ROOT/theses/demo-smoke/prediction" \
    "$KB_ROOT/theses/demo-smoke/reality" \
    --threshold-bp=100 \
    --kb-root="$KB_ROOT")
echo "    $DIVOUT" | tr '\n' ' '
echo ""
if ! echo "$DIVOUT" | grep -qE "drift_idx:|no divergence"; then
    echo "FAIL: divergence output didn't match either expected shape" >&2
    echo "$DIVOUT" >&2
    exit 1
fi

echo "==> PASS — full demo loop completed against Kalshi demo API"

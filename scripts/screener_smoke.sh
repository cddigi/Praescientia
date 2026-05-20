#!/usr/bin/env bash
# scripts/screener_smoke.sh — end-to-end smoke for the market-screener
# pipeline. Exercises every step the operator would run by hand:
#
#   1. praescientia-markets candidates    (live demo API call)
#   2. mock screener-agent output         (deterministic — no Agent call)
#   3. praescientia-screener validate
#   4. praescientia-screener apply --dry-run
#
# Step 2 is a deterministic Python stub that consumes the candidates
# output, picks the first 2 as safe + 1 as moderate (with the seed
# commentaries the agent would have authored), and writes a valid
# ScreenerOutput JSON. This keeps the smoke deterministic — no real
# Agent calls, no Anthropic API spend.
#
# Prerequisites:
#   - `zig build` has produced praescientia-{markets,screener} in
#     ./zig-out/bin/
#   - jq and python3 on $PATH
#   - .secret/kalshi_api_key_{id,private}.txt for the demo API call
#
# Exit codes:
#   0 — every step succeeded
#   1 — a step failed (stderr names which)
#   2 — prerequisites missing

set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/zig-out/bin"
KB_ROOT="${KB_ROOT:-$ROOT/kb}"
TMP="$(mktemp -d -t screener_smoke.XXXXXX)"
trap "rm -rf '$TMP'" EXIT

# --- Prerequisite checks ----------------------------------------------------

if [ ! -x "$BIN/praescientia-markets" ] || [ ! -x "$BIN/praescientia-screener" ]; then
  echo "missing binaries — run 'zig build' first" >&2
  exit 2
fi
if ! command -v jq >/dev/null || ! command -v python3 >/dev/null; then
  echo "jq and python3 are required" >&2
  exit 2
fi
if [ ! -d "$KB_ROOT" ]; then
  echo "kb root not found at $KB_ROOT — run 'praescientia-kb init --kb-root=$KB_ROOT' first" >&2
  exit 2
fi

step() { printf "\n=== %s ===\n" "$1"; }

# --- Step 1: candidates -----------------------------------------------------

step "1: praescientia-markets candidates (against demo)"
"$BIN/praescientia-markets" candidates --kb-root="$KB_ROOT" --demo \
    --min-volume=5 --max-spread-cents=10 --max-candidates=20 --max-pages=15 \
    > "$TMP/candidates.json"

CAND_COUNT=$(jq '.candidates | length' "$TMP/candidates.json")
SCAN_ID=$(jq -r '.scan_id' "$TMP/candidates.json")
SCAN_TS=$(jq -r '.scan_ts_ms' "$TMP/candidates.json")
echo "scan_id=$SCAN_ID  candidates=$CAND_COUNT"
jq '.gate_summary' "$TMP/candidates.json"

# --- Step 2: mock screener-agent output ------------------------------------

step "2: synthesize deterministic screener output (stand-in for agent)"

python3 - "$TMP/candidates.json" "$TMP/screener_output.json" <<'PY'
import json, sys
src = json.load(open(sys.argv[1]))
cands = src.get('candidates', [])
out = {
    "scan_id": src['scan_id'],
    "scan_ts_ms": src['scan_ts_ms'],
    "candidates_evaluated": len(cands),
    "buckets": {"safe": [], "moderate": [], "high_risk": []},
    "skipped": [],
}

def entry(c, bucket, signal, conf, size_pct, edge_target):
    bid = c['yes_bid_cents']
    implied = (bid + c['yes_ask_cents']) // 2
    our = max(0, min(100, implied + edge_target))
    edge = abs(our - implied)
    return {
        "ticker": c['ticker'],
        "proposed_thesis_id": "smoke-" + bucket + "-" + ''.join(ch.lower() if ch.isalnum() else '-' for ch in c['ticker'])[:48].strip('-'),
        "primary_signal": signal,
        "implied_yes_cents": implied,
        "our_estimate_yes_cents": our,
        "edge_cents": edge,
        "confidence_bp": conf,
        "research_required": "smoke-test synthetic — no live model",
        "suggested_seed_commentary": [
            f"Framing (smoke): {c.get('title','')[:160]}. Bucket={bucket}, signal={signal}. Live mid {implied}c, our fair {our}c.",
            f"Base rate (smoke): synthetic. {bucket} bucket synthesis uses fixed edge_target={edge_target}c. Position cap suggested {size_pct}% of thesis cap.",
        ],
        "suggested_size_pct_of_cap": size_pct,
    }

# safe: first 2 (if available)
for c in cands[:2]:
    out['buckets']['safe'].append(entry(c, "safe", "synthetic-structural", 8200, 60, 3))
# moderate: next 1
for c in cands[2:3]:
    out['buckets']['moderate'].append(entry(c, "moderate", "synthetic-fundamental", 6500, 35, 4))
# high_risk: next 1
for c in cands[3:4]:
    out['buckets']['high_risk'].append(entry(c, "high-risk", "synthetic-contrarian", 4500, 10, 5))

# Skipped: everything past the first 4
for c in cands[4:]:
    out['skipped'].append({
        "ticker": c['ticker'],
        "reason": "smoke-test: beyond the first 4 candidates",
    })

json.dump(out, open(sys.argv[2], 'w'), indent=2)
print(f"  wrote {sys.argv[2]} with "
      f"safe={len(out['buckets']['safe'])} "
      f"moderate={len(out['buckets']['moderate'])} "
      f"high_risk={len(out['buckets']['high_risk'])} "
      f"skipped={len(out['skipped'])}")
PY

# --- Step 3: validate -------------------------------------------------------

step "3: praescientia-screener validate"
"$BIN/praescientia-screener" validate --output="$TMP/screener_output.json" --kb-root="$KB_ROOT"

# --- Step 4: dry-run apply --------------------------------------------------

step "4: praescientia-screener apply --dry-run"
"$BIN/praescientia-screener" apply --output="$TMP/screener_output.json" --kb-root="$KB_ROOT" --dry-run

# --- Summary ---------------------------------------------------------------

step "summary"
PLANNED=$("$BIN/praescientia-screener" apply --output="$TMP/screener_output.json" --kb-root="$KB_ROOT" --dry-run | jq '.planned')
echo "smoke complete: $PLANNED entries planned (scan_id=$SCAN_ID)"

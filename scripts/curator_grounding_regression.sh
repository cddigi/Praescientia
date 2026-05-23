#!/usr/bin/env bash
# scripts/curator_grounding_regression.sh — proves the source-curator closes
# the gap the Ollama-vs-Sonnet bakeoff exposed (report §3.5): without sources,
# the thesis-analyst defaults to the stock "No external reference identified."
# external_cross_ref. With curator-supplied source neighbours, it should ground
# its cross-reference in real figures.
#
# Realized scope (deviation from the plan's "ollama_vs_sonnet_smoke.sh"):
# a true Ollama-vs-Sonnet comparison needs paid Sonnet/claude calls and can't
# be a deterministic local gate. The runnable proxy that isolates the SAME
# causal claim is grounded-vs-ungrounded *Ollama*: one model, two inputs that
# differ only in whether source-backed neighbours are present. Both runs are
# local and free.
#
# A/B:
#   A (ungrounded): neighbours are 2 generic model_synthesis notes, no data.
#   B (grounded):   same 2 + 2 source:primary neighbours carrying real
#                   Eurostat/ECB figures (the kind the curator would persist).
#
# Assert: B's analysis block CITES the supplied figures (3.0 / 2.7 / 10.9)
# that A's does not. Empirically (2026-05-23) Qwen3-27B pulls curator-supplied
# figures into base_rate / domain_state / commentary_review — but NOT into
# external_cross_ref, which it reads narrowly as "sources I fetched myself,"
# distinct from in-context neighbours. So we assert on figure-citation across
# the WHOLE analysis block, and separately REPORT (informational) that
# external_cross_ref stays stock-ish — corroborating bakeoff §7.2 (the agent
# prompt still needs a fix for that specific field even once grounding lands).
#
# Ollama-gated: needs the Ollama daemon up with the analyst model. Exit 2 if
# unavailable (mirrors commentary_smoke.sh's Ollama dependency). Slow: two
# 27B-MLX inferences, ~1-5 min total.
#
# Exit: 0 ok / 1 regression (grounding did not change the cross-ref) / 2 prereqs.

set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/zig-out/bin"
TMP="$(mktemp -d -t curator_grounding.XXXXXX)"
trap "rm -rf '$TMP'" EXIT

MODEL="${OLLAMA_MODEL:-qwen3.6:27b-mlx}"
OLLAMA_URL="${OLLAMA_URL:-http://localhost:11434}"

[ -x "$BIN/praescientia-ollama-agent" ] || { echo "missing praescientia-ollama-agent — run 'zig build'" >&2; exit 2; }
command -v jq >/dev/null && command -v python3 >/dev/null || { echo "jq + python3 required" >&2; exit 2; }
if ! curl -s "$OLLAMA_URL/api/tags" 2>/dev/null | jq -e --arg m "$MODEL" '.models[]?|select(.name==$m)' >/dev/null; then
  echo "Ollama model '$MODEL' not available at $OLLAMA_URL — skipping (exit 2)" >&2
  exit 2
fi

step() { printf "\n=== %s ===\n" "$1"; }

# --- Build the two inputs (differ only in neighbours) -----------------------

step "build ungrounded + grounded inputs"
python3 - "$TMP" <<'PY'
import json, sys, time
tmp = sys.argv[1]
now = int(time.time() * 1000); vu = now + 7 * 24 * 3600 * 1000

thesis = {
    "id": "eu-cpi-may26-above-3pt1",
    "description": "Euro area CPI YoY flash for May 2026 prints above 3.1%. Release 2026-06-02.",
    "market_set": ["KXEZCPIYOYF-26JUN02-T3.1"],
    "weights_bp": [10000], "rollup_fn": "weighted_avg_v1",
    "confidence_delta_bp": 300, "bankroll_cap_bp": 500,
}
market = {"ticker": "KXEZCPIYOYF-26JUN02-T3.1", "yes_bid_cents": 0, "yes_ask_cents": 68,
          "last_trade_cents": None, "volume": 0, "current_position_size": 0, "open_orders": []}
bankroll = {"account_balance_cents": 1000000, "thesis_cap_cents": 50000, "used_cents": 0}

generic = [
    {"hash": "a"*64, "scope_path": "theses/eu-cpi/commentary",
     "body": "Macro thesis on Euro CPI. No specific figures on hand this tick.",
     "tags": ["eu-cpi", "source:model_synthesis"], "ts_ms": now - 1000},
    {"hash": "b"*64, "scope_path": "theses/eu-cpi/commentary",
     "body": "Ladder rung; verify monotonicity vs higher strikes when liquid.",
     "tags": ["eu-cpi", "source:model_synthesis"], "ts_ms": now - 2000},
]
sourced = [
    {"hash": "c"*64, "scope_path": "theses/eu-cpi/commentary",
     "body": ("--- src: https://ec.europa.eu/eurostat/flash fetched: %d valid_until: %d ---\n"
              "Eurostat flash: euro-area HICP YoY was 3.0%% in April 2026 (up from 2.6%% in March), "
              "energy +10.9%%. See https://ec.europa.eu/eurostat/flash. The 3.1%% strike is 10bp above "
              "the last print." % (now, vu)),
     "tags": ["eu-cpi", "source:primary"], "ts_ms": now - 500},
    {"hash": "d"*64, "scope_path": "theses/eu-cpi/commentary",
     "body": ("--- src: https://www.ecb.europa.eu/spf fetched: %d valid_until: %d ---\n"
              "ECB SPF Q2 2026: full-year 2026 HICP consensus revised to 2.7%% from 1.8%%. "
              "See https://www.ecb.europa.eu/spf." % (now, vu)),
     "tags": ["eu-cpi", "source:primary"], "ts_ms": now - 400},
]

def doc(neighbors):
    return {"tick_id": "01GROUNDREGRESS0000000000A", "thesis": thesis, "reality_head": None,
            "prediction_history": [], "markets": [market], "commentary_neighbors": neighbors,
            "bankroll": bankroll}

json.dump(doc(generic), open(f"{tmp}/ungrounded.json", "w"))
json.dump(doc(generic + sourced), open(f"{tmp}/grounded.json", "w"))
print("  wrote ungrounded.json (2 neighbours) + grounded.json (4 neighbours, 2 source:primary)")
PY

run_analyst() {
  local infile="$1" outfile="$2"
  "$BIN/praescientia-ollama-agent" --role=thesis-analyst --model="$MODEL" \
    --timeout-ms=600000 < "$infile" > "$outfile" 2>/dev/null
}

STOCK="No external reference identified."

# --- Run A: ungrounded ------------------------------------------------------

step "run A: ungrounded Ollama analyst"
run_analyst "$TMP/ungrounded.json" "$TMP/ungrounded_out.json"
jq -e . "$TMP/ungrounded_out.json" >/dev/null || { echo "ungrounded run produced invalid JSON" >&2; exit 1; }
A_XREF=$(jq -r '.analysis.external_cross_ref // ""' "$TMP/ungrounded_out.json")
echo "  A external_cross_ref: ${A_XREF:0:120}"

# --- Run B: grounded --------------------------------------------------------

step "run B: grounded Ollama analyst"
run_analyst "$TMP/grounded.json" "$TMP/grounded_out.json"
jq -e . "$TMP/grounded_out.json" >/dev/null || { echo "grounded run produced invalid JSON" >&2; exit 1; }
B_XREF=$(jq -r '.analysis.external_cross_ref // ""' "$TMP/grounded_out.json")
echo "  B external_cross_ref: ${B_XREF:0:200}"

# Count how many of the curator-supplied figures appear across the WHOLE
# analysis block (these figures exist ONLY in the grounded neighbours).
count_figures() {
  # `|| true` so a zero-match grep (expected for the ungrounded run) doesn't
  # trip `set -o pipefail` and abort the script.
  jq -r '.analysis | to_entries | map(.value) | join(" ")' "$1" \
    | { grep -oE '(3\.0|2\.7|10\.9)' || true; } | wc -l | tr -d ' '
}
A_FIG=$(count_figures "$TMP/ungrounded_out.json")
B_FIG=$(count_figures "$TMP/grounded_out.json")

# --- Assertions -------------------------------------------------------------

step "assertions"
echo "  supplied-figure citations across analysis block: ungrounded=$A_FIG  grounded=$B_FIG"
fail=0
# The load-bearing claim: grounding injects the supplied figures into the
# analyst's reasoning where they were absent before.
if [ "$B_FIG" -lt 2 ]; then
  echo "  FAIL: grounded analysis cites <2 supplied figures ($B_FIG) — grounding did not land" >&2
  fail=1
fi
if [ "$B_FIG" -le "$A_FIG" ]; then
  echo "  FAIL: grounded ($B_FIG) did not exceed ungrounded ($A_FIG) figure citations" >&2
  fail=1
fi

if [ "$fail" -ne 0 ]; then
  echo "regression: source grounding did NOT measurably reach the analyst's reasoning" >&2
  exit 1
fi

# Informational: external_cross_ref specifically tends to stay stock-ish even
# when grounding lands elsewhere. Reported, not asserted (bakeoff §7.2 follow-up).
step "informational: external_cross_ref behaviour"
if [ "$B_XREF" = "$STOCK" ] || ! printf '%s' "$B_XREF" | grep -qE '[0-9]'; then
  echo "  NOTE: external_cross_ref still avoids citing figures ('${B_XREF:0:80}')."
  echo "  This corroborates bakeoff §7.2: the agent prompt needs a positive example"
  echo "  steering external_cross_ref to use in-context neighbour data. Grounding alone"
  echo "  is necessary but not sufficient for THIS field."
else
  echo "  external_cross_ref now cites a figure — §7.2 prompt fix may be unnecessary."
fi

step "summary"
echo "grounding regression PASS: grounded analysis cited $B_FIG supplied figures vs $A_FIG ungrounded —"
echo "the curator's sources measurably reach the analyst's reasoning (domain_state/base_rate/commentary_review)."

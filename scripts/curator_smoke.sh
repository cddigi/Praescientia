#!/usr/bin/env bash
# scripts/curator_smoke.sh — end-to-end smoke for the source-curator
# validate→apply pipeline. Deterministic: no Agent call, no WebFetch, no
# Anthropic spend. A Python stub synthesizes a valid curator output (two
# primary-tier entries with now-relative TTLs), then we run the real
# praescientia-curator validate + apply against a throwaway kb_root and
# assert the entries landed as source-backed commentary.
#
# This is the Stage 3 gate: it proves the validator accepts a well-formed
# envelope and the applier writes frontmatter-prefixed, source:<tier>-tagged
# commentary that round-trips back out of the chain.
#
# Prerequisites:
#   - `zig build` has produced praescientia-{kb,curator} in ./zig-out/bin/
#   - jq and python3 on $PATH
#
# Exit codes:
#   0 — every step succeeded
#   1 — a step failed (stderr names which)
#   2 — prerequisites missing

set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/zig-out/bin"
TMP="$(mktemp -d -t curator_smoke.XXXXXX)"
trap "rm -rf '$TMP'" EXIT

KB="$TMP/kb"
OUT="$TMP/curator_output.json"
TICK_ID="01CURATORSMOKE00000000000A"
THESIS="sample"

if [ ! -x "$BIN/praescientia-kb" ] || [ ! -x "$BIN/praescientia-curator" ]; then
  echo "missing binaries — run 'zig build' first" >&2
  exit 2
fi
if ! command -v jq >/dev/null || ! command -v python3 >/dev/null; then
  echo "jq and python3 are required" >&2
  exit 2
fi

step() { printf "\n=== %s ===\n" "$1"; }

# --- Step 1: throwaway kb_root with a sample thesis -------------------------

step "1: init throwaway kb_root with sample thesis"
"$BIN/praescientia-kb" init "$KB" --with-sample
test -d "$KB/theses/$THESIS" || { echo "sample thesis not created" >&2; exit 1; }

# --- Step 2: synthesize a deterministic curator output ----------------------

step "2: synthesize deterministic curator output (stand-in for agent)"
python3 - "$OUT" "$TICK_ID" "$THESIS" <<'PY'
import json, sys, time
out_path, tick_id, thesis = sys.argv[1], sys.argv[2], sys.argv[3]
now_ms = int(time.time() * 1000)
valid_until = now_ms + 7 * 24 * 60 * 60 * 1000  # +7d, within primary (30d) bound

def entry(url, body):
    return {
        "scope": "thesis", "scope_key": thesis,
        "source_url": url, "source_tier": "primary",
        "fetch_ts_ms": now_ms, "valid_until_ms": valid_until,
        "body": body, "tags": ["smoke", "source:primary"], "references": [],
    }

out = {
    "tick_id": tick_id,
    "entries": [
        entry("https://example.test/release-a",
              "Smoke source A: official release, see https://example.test/release-a for the figure."),
        entry("https://example.test/release-b",
              "Smoke source B: consensus forecast, see https://example.test/release-b for detail."),
    ],
    "fetches_consumed": 2,
    "summary": "smoke: two synthetic primary sources for the sample thesis.",
}
json.dump(out, open(out_path, "w"), indent=2)
print(f"  wrote {out_path} with {len(out['entries'])} entries (now_ms={now_ms})")
PY

# --- Step 3: validate -------------------------------------------------------

step "3: praescientia-curator validate"
VRES=$("$BIN/praescientia-curator" validate --output="$OUT" --tick-id="$TICK_ID")
echo "$VRES"
echo "$VRES" | jq -e '.ok == true and .entries == 2 and .counts.primary == 2' >/dev/null \
  || { echo "validate did not accept the envelope as expected" >&2; exit 1; }

# --- Step 4: validate rejects a tampered tick_id ----------------------------

step "4: validate rejects a mismatched tick_id (negative check)"
if "$BIN/praescientia-curator" validate --output="$OUT" --tick-id="01WRONGTICK0000000000000ZZ" >/dev/null 2>&1; then
  echo "validate should have rejected a mismatched tick_id" >&2
  exit 1
fi
echo "  correctly rejected mismatched tick_id"

# --- Step 5: apply ----------------------------------------------------------

step "5: praescientia-curator apply --thesis=$THESIS"
ARES=$("$BIN/praescientia-curator" apply --output="$OUT" --tick-id="$TICK_ID" --kb-root="$KB" --thesis="$THESIS")
echo "$ARES"
echo "$ARES" | jq -e '.ok == true and .written == 2 and .skipped == 0' >/dev/null \
  || { echo "apply did not write both entries" >&2; exit 1; }

# --- Step 6: verify entries landed in the chain -----------------------------

step "6: verify source-backed commentary in the chain"
CHAIN="$KB/theses/$THESIS/commentary/main.jsonl"
test -f "$CHAIN" || { echo "commentary chain not found at $CHAIN" >&2; exit 1; }

LINES=$(grep -c . "$CHAIN")
echo "  chain has $LINES entries"
[ "$LINES" -eq 2 ] || { echo "expected 2 chain entries, got $LINES" >&2; exit 1; }

# Each entry's body must carry the provenance frontmatter and the source tag.
grep -q -- '--- src: https://example.test/release-a' "$CHAIN" \
  || { echo "frontmatter not found for source A" >&2; exit 1; }
grep -q 'source:primary' "$CHAIN" \
  || { echo "source:primary tag not stamped" >&2; exit 1; }
echo "  frontmatter + source:primary tag present"

# --- Summary ---------------------------------------------------------------

step "summary"
echo "curator smoke complete: validate accepted, apply wrote 2 source-backed entries, chain verified (tick_id=$TICK_ID)"

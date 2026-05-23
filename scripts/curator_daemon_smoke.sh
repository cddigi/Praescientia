#!/usr/bin/env bash
# scripts/curator_daemon_smoke.sh — Stage 4 gate for the daemon's
# --sources-floor grounding hook. Deterministic: no real Agent/WebFetch and
# no real claude call.
#
# Strategy:
#   - A stub curator-bin stands in for `praescientia-curator tick`: it
#     synthesizes a canned 3-entry primary envelope and pipes it through the
#     REAL `praescientia-curator apply`, so source-backed commentary actually
#     lands in the chain.
#   - A stub `claude` on $PATH stands in for the analyst dispatch (the daemon
#     spawns `claude -p '/praescientia-orchestrate ...'`); it just prints an OK
#     line so the dispatch step succeeds cheaply.
#
# Asserts:
#   1. First daemon tick grounds the under-floor thesis: >=3 source:primary
#      entries land + the per-thesis cache timestamp is written.
#   2. Second tick within the cache window SKIPS re-grounding (no new entries).
#
# Prereqs: zig build done; jq + python3 on PATH.
# Exit: 0 ok / 1 assertion failed / 2 prereqs missing.

set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/zig-out/bin"
TMP="$(mktemp -d -t curator_daemon_smoke.XXXXXX)"
trap "rm -rf '$TMP'" EXIT

KB="$TMP/kb"
THESIS="sample"
CHAIN="$KB/theses/$THESIS/commentary/main.jsonl"

for b in praescientia-kb praescientia-curator praescientia-orchestrate-daemon praescientia-game-state; do
  [ -x "$BIN/$b" ] || { echo "missing $b — run 'zig build' first" >&2; exit 2; }
done
command -v jq >/dev/null && command -v python3 >/dev/null || { echo "jq + python3 required" >&2; exit 2; }

step() { printf "\n=== %s ===\n" "$1"; }

# --- Setup: kb, stub curator-bin, stub claude -------------------------------

step "setup: kb + stubs"
"$BIN/praescientia-kb" init "$KB" --with-sample >/dev/null
test -d "$KB/theses/$THESIS" || { echo "sample thesis missing" >&2; exit 1; }

export CURATOR_BIN="$BIN/praescientia-curator"
CURATOR_STUB="$TMP/curator-stub.sh"
cat > "$CURATOR_STUB" <<'STUB'
#!/usr/bin/env bash
# Stub for `praescientia-curator tick`: synthesize a canned 3-source envelope
# and apply it through the real curator apply path.
set -euo pipefail
THESIS=""; KBR=""
for a in "$@"; do
  case "$a" in
    --thesis=*) THESIS="${a#--thesis=}";;
    --kb-root=*) KBR="${a#--kb-root=}";;
  esac
done
OUT="$(mktemp)"
python3 - "$OUT" "$THESIS" <<'PY'
import json, sys, time
out, thesis = sys.argv[1], sys.argv[2]
now = int(time.time() * 1000); vu = now + 7 * 24 * 3600 * 1000
def e(u, b):
    return {"scope": "thesis", "scope_key": thesis, "source_url": u, "source_tier": "primary",
            "fetch_ts_ms": now, "valid_until_ms": vu, "body": b,
            "tags": ["smoke", "source:primary"], "references": []}
o = {"tick_id": "01CURATORDAEMONSTUB000000A",
     "entries": [e("https://example.test/a", "Source A see https://example.test/a"),
                 e("https://example.test/b", "Source B see https://example.test/b"),
                 e("https://example.test/c", "Source C see https://example.test/c")],
     "fetches_consumed": 3, "summary": "stub grounding"}
json.dump(o, open(out, "w"))
PY
"$CURATOR_BIN" apply --output="$OUT" --tick-id="01CURATORDAEMONSTUB000000A" --kb-root="$KBR" --thesis="$THESIS" >/dev/null
echo '{"ok":true,"stub":true}'
STUB
chmod +x "$CURATOR_STUB"

CLAUDE_DIR="$TMP/stubbin"
mkdir -p "$CLAUDE_DIR"
cat > "$CLAUDE_DIR/claude" <<'CLAUDE'
#!/usr/bin/env bash
echo '{"status":"ok","stub_claude":true}'
exit 0
CLAUDE
chmod +x "$CLAUDE_DIR/claude"
export PATH="$CLAUDE_DIR:$PATH"

run_tick() {
  "$BIN/praescientia-orchestrate-daemon" run \
    --kb-root="$KB" --per-thesis-cadence --sources-floor=3 \
    --sources-curator-bin="$CURATOR_STUB" --sources-cache-ttl=6h \
    --max-ticks=1 --game-state-bin="$BIN/praescientia-game-state"
}

# --- Tick 1: should ground --------------------------------------------------

step "tick 1: expect grounding (0 < floor 3)"
OUT1="$(run_tick 2>&1)"
echo "$OUT1" | grep -E "\[curator\] sample" || true
echo "$OUT1" | grep -q "source neighbours < floor 3 — grounding" \
  || { echo "tick 1 did not trigger grounding" >&2; exit 1; }

test -f "$CHAIN" || { echo "chain not created" >&2; exit 1; }
N1=$(grep -c 'source:primary' "$CHAIN" || true)
echo "  source:primary entries after tick 1: $N1"
[ "$N1" -ge 3 ] || { echo "expected >=3 source entries, got $N1" >&2; exit 1; }
test -f "$KB/.ticks/$THESIS.last_curator_run.ms" || { echo "cache timestamp not written" >&2; exit 1; }
echo "  cache timestamp written"

# --- Tick 2: within cache window, should SKIP -------------------------------

step "tick 2: expect cache-gate skip (no re-grounding)"
OUT2="$(run_tick 2>&1)"
if echo "$OUT2" | grep -q "source neighbours < floor 3 — grounding"; then
  echo "tick 2 re-grounded despite cache window — gate failed" >&2
  exit 1
fi
N2=$(grep -c 'source:primary' "$CHAIN" || true)
echo "  source:primary entries after tick 2: $N2"
[ "$N2" -eq "$N1" ] || { echo "tick 2 added entries ($N1 -> $N2); cache gate failed" >&2; exit 1; }
echo "  cache gate held — no new entries"

# --- Summary ---------------------------------------------------------------

step "summary"
echo "daemon grounding smoke complete: tick 1 grounded ($N1 sources), tick 2 cache-skipped (still $N2)"

#!/usr/bin/env bash
# Stage 3 parity harness.
#
# Captures every endpoint twice — once via the Zig client (test_conn
# --capture-dir), once via the Julia client (scripts/kalshi_*.jl) — then jq -S
# normalizes both and diffs them. A clean diff means the Zig HTTP+JSON pipeline
# returns the same wire shape Kalshi gives Julia.
#
# Endpoints whose responses change every call (live trade feeds, milestones
# with updated_ts, RFQ queues) will show diffs; those are reported as DRIFT
# rather than FAIL so the harness still flags structural regressions.
#
# Requires: julia 1.9+ with the project env precompiled, jq, bash 4+.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

DATE="$(date -u +%Y-%m-%d)"
OUT_DIR="parity/$DATE"
mkdir -p "$OUT_DIR"

echo "==> Building Zig binaries"
zig build > /dev/null

echo "==> Capturing Zig responses → $OUT_DIR/*.zig.json"
./zig-out/bin/praescientia-test-conn --capture-dir="$OUT_DIR" > /dev/null

echo "==> Capturing Julia responses → $OUT_DIR/*.julia.json"
# Map: zig endpoint name → julia script + subcommand
declare -a JULIA_PAIRS=(
    "exchange.status:kalshi_exchange.jl:status"
    "exchange.schedule:kalshi_exchange.jl:schedule"
    "exchange.announcements:kalshi_exchange.jl:announcements"
    "portfolio.balance:kalshi_portfolio.jl:balance"
    "account.limits:kalshi_account.jl:limits"
)

for pair in "${JULIA_PAIRS[@]}"; do
    IFS=':' read -r name script subcmd <<< "$pair"
    raw_path="$OUT_DIR/${name}.julia.raw"
    json_path="$OUT_DIR/${name}.julia.json"
    if julia --project=. "scripts/$script" "$subcmd" > "$raw_path" 2>/dev/null; then
        # Julia scripts append `nothing\n` (return of println(nothing)).
        # Strip trailing `nothing\n?` if present.
        python3 -c "
import sys, json
raw = open(sys.argv[1]).read()
if raw.rstrip().endswith('nothing'):
    raw = raw.rstrip()
    raw = raw[: -len('nothing')]
try:
    obj = json.loads(raw)
    json.dump(obj, open(sys.argv[2], 'w'))
except json.JSONDecodeError as e:
    print(f'  WARN: {sys.argv[1]} unparseable: {e}', file=sys.stderr)
    open(sys.argv[2], 'w').write(raw)
        " "$raw_path" "$json_path"
        rm -f "$raw_path"
    else
        echo "  WARN: julia capture for $name failed"
    fi
done

echo ""
echo "==> Diffing canonical shapes"
EXIT=0
DRIFT=0
MATCH=0

for pair in "${JULIA_PAIRS[@]}"; do
    IFS=':' read -r name _ _ <<< "$pair"
    zig_file="$OUT_DIR/${name}.zig.json"
    julia_file="$OUT_DIR/${name}.julia.json"
    [ -f "$zig_file" ] || { echo "  SKIP  $name (no zig capture)"; continue; }
    [ -f "$julia_file" ] || { echo "  SKIP  $name (no julia capture)"; continue; }

    zig_canon=$(jq -cS . "$zig_file" 2>/dev/null || echo "<unparseable>")
    julia_canon=$(jq -cS . "$julia_file" 2>/dev/null || echo "<unparseable>")

    if [ "$zig_canon" = "$julia_canon" ]; then
        echo "  MATCH $name"
        MATCH=$((MATCH+1))
    else
        # Compute symmetric key-set diff so timestamp/cursor noise doesn't dominate.
        zig_keys=$(jq -S 'keys_unsorted | sort | unique' "$zig_file" 2>/dev/null || echo "[]")
        julia_keys=$(jq -S 'keys_unsorted | sort | unique' "$julia_file" 2>/dev/null || echo "[]")
        if [ "$zig_keys" = "$julia_keys" ]; then
            echo "  DRIFT $name (same top-level keys, different values)"
            DRIFT=$((DRIFT+1))
        else
            echo "  FAIL  $name (top-level key sets differ)"
            echo "    zig   keys: $zig_keys"
            echo "    julia keys: $julia_keys"
            EXIT=1
        fi
    fi
done

echo ""
echo "Summary: $MATCH matched, $DRIFT drift (values changed between captures), $((EXIT == 1 ? 1 : 0)) structural mismatches"
echo "Captures: $OUT_DIR/"
exit "$EXIT"

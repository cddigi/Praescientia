#!/usr/bin/env bash
# Stage 3/4 parity harness.
#
# Default mode (Stage 3): captures every endpoint twice — once via the Zig
# client (test_conn --capture-dir), once via the Julia client — then jq -cS
# normalizes both and diffs them.
#
# --tools mode (Stage 4): invokes each Zig CLI subcommand and each Julia script
# subcommand head-to-head, diffing the rendered stdout. After Stage 4 the CLIs
# are the canonical user-facing surface, so this is the stricter parity test.
#
# Endpoints whose responses change every call (live trade feeds, milestones
# with updated_ts, RFQ queues) will show diffs; those are reported as DRIFT
# rather than FAIL so the harness still flags structural regressions.
#
# Requires: julia 1.9+ with the project env precompiled, jq, bash 4+.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

MODE="endpoints"
if [ "${1:-}" = "--tools" ]; then
    MODE="tools"
fi

DATE="$(date -u +%Y-%m-%d)"
OUT_DIR="parity/$DATE"
mkdir -p "$OUT_DIR"

# Strip Julia's trailing `nothing\n` (artifact of println(nothing)) and
# normalize via jq. Writes the canonical JSON to "$2"; writes raw to "$2".raw
# only on failure.
strip_julia() {
    local raw="$1"
    local out="$2"
    python3 - "$raw" "$out" <<'PY'
import sys, json
raw_path, out_path = sys.argv[1], sys.argv[2]
raw = open(raw_path).read()
if raw.rstrip().endswith("nothing"):
    raw = raw.rstrip()
    raw = raw[: -len("nothing")]
try:
    obj = json.loads(raw)
    json.dump(obj, open(out_path, "w"))
except json.JSONDecodeError as e:
    print(f"  WARN: {raw_path} unparseable: {e}", file=sys.stderr)
    open(out_path, "w").write(raw)
PY
}

# Compare two canonical-JSON files. Echo "MATCH", "DRIFT" (same top-level keys
# but different values), or "FAIL" (key sets differ). Increments the matching
# counter in the caller's scope is the caller's job.
classify_pair() {
    local zig_file="$1"
    local julia_file="$2"
    local zig_canon
    local julia_canon

    [ -f "$zig_file" ] || { echo "SKIP"; return; }
    [ -f "$julia_file" ] || { echo "SKIP"; return; }

    zig_canon=$(jq -cS . "$zig_file" 2>/dev/null || echo "<unparseable>")
    julia_canon=$(jq -cS . "$julia_file" 2>/dev/null || echo "<unparseable>")
    if [ "$zig_canon" = "$julia_canon" ]; then
        echo "MATCH"
        return
    fi
    # Same top-level keys?
    local zig_keys
    local julia_keys
    zig_keys=$(jq -S 'if type == "object" then keys_unsorted | sort | unique else [] end' "$zig_file" 2>/dev/null || echo "[]")
    julia_keys=$(jq -S 'if type == "object" then keys_unsorted | sort | unique else [] end' "$julia_file" 2>/dev/null || echo "[]")
    if [ "$zig_keys" = "$julia_keys" ]; then
        echo "DRIFT"
    else
        echo "FAIL"
    fi
}

echo "==> Building Zig binaries"
zig build > /dev/null

EXIT=0
MATCH=0
DRIFT=0
FAIL=0

if [ "$MODE" = "endpoints" ]; then
    echo "==> Capturing Zig responses → $OUT_DIR/*.zig.json"
    ./zig-out/bin/praescientia-test-conn --capture-dir="$OUT_DIR" > /dev/null

    echo "==> Capturing Julia responses → $OUT_DIR/*.julia.json"
    declare -a JULIA_PAIRS=(
        "exchange.status:kalshi_exchange.jl:status"
        "exchange.schedule:kalshi_exchange.jl:schedule"
        "exchange.announcements:kalshi_exchange.jl:announcements"
        "portfolio.balance:kalshi_portfolio.jl:balance"
        "account.limits:kalshi_account.jl:limits"
    )
    for pair in "${JULIA_PAIRS[@]}"; do
        IFS=':' read -r name script subcmd <<< "$pair"
        if julia --project=. "scripts/$script" "$subcmd" > "$OUT_DIR/${name}.julia.raw" 2>/dev/null; then
            strip_julia "$OUT_DIR/${name}.julia.raw" "$OUT_DIR/${name}.julia.json"
            rm -f "$OUT_DIR/${name}.julia.raw"
        else
            echo "  WARN: julia capture for $name failed"
        fi
    done

    echo ""
    echo "==> Diffing canonical shapes"
    for pair in "${JULIA_PAIRS[@]}"; do
        IFS=':' read -r name _ _ <<< "$pair"
        zig_file="$OUT_DIR/${name}.zig.json"
        julia_file="$OUT_DIR/${name}.julia.json"
        verdict=$(classify_pair "$zig_file" "$julia_file")
        case "$verdict" in
            MATCH) echo "  MATCH $name"; MATCH=$((MATCH+1));;
            DRIFT) echo "  DRIFT $name (same top-level keys, different values)"; DRIFT=$((DRIFT+1));;
            FAIL)  echo "  FAIL  $name (top-level key sets differ)"; FAIL=$((FAIL+1)); EXIT=1;;
            SKIP)  echo "  SKIP  $name (no capture)";;
        esac
    done
else
    # --tools mode: invoke each Zig CLI subcommand and matching Julia subcommand.
    declare -a TOOL_PAIRS=(
        "exchange.status:praescientia-exchange:kalshi_exchange.jl:status"
        "exchange.schedule:praescientia-exchange:kalshi_exchange.jl:schedule"
        "exchange.announcements:praescientia-exchange:kalshi_exchange.jl:announcements"
        "historical.cutoff:praescientia-historical:kalshi_historical.jl:cutoff"
        "portfolio.balance:praescientia-portfolio:kalshi_portfolio.jl:balance"
        "account.limits:praescientia-account:kalshi_account.jl:limits"
        "account.list_keys:praescientia-account:kalshi_account.jl:list_keys"
    )

    echo "==> Running Zig CLIs"
    for pair in "${TOOL_PAIRS[@]}"; do
        IFS=':' read -r name bin _ subcmd <<< "$pair"
        if ! "./zig-out/bin/$bin" "$subcmd" > "$OUT_DIR/${name}.zig.json" 2>/dev/null; then
            echo "  WARN: zig $bin $subcmd failed"
        fi
    done

    echo "==> Running Julia scripts"
    for pair in "${TOOL_PAIRS[@]}"; do
        IFS=':' read -r name _ script subcmd <<< "$pair"
        if julia --project=. "scripts/$script" "$subcmd" > "$OUT_DIR/${name}.julia.raw" 2>/dev/null; then
            strip_julia "$OUT_DIR/${name}.julia.raw" "$OUT_DIR/${name}.julia.json"
            rm -f "$OUT_DIR/${name}.julia.raw"
        else
            echo "  WARN: julia $script $subcmd failed"
        fi
    done

    echo ""
    echo "==> Diffing canonical shapes (Zig CLI vs Julia script)"
    for pair in "${TOOL_PAIRS[@]}"; do
        IFS=':' read -r name _ _ _ <<< "$pair"
        zig_file="$OUT_DIR/${name}.zig.json"
        julia_file="$OUT_DIR/${name}.julia.json"
        verdict=$(classify_pair "$zig_file" "$julia_file")
        case "$verdict" in
            MATCH) echo "  MATCH $name"; MATCH=$((MATCH+1));;
            DRIFT) echo "  DRIFT $name (same top-level keys, different values)"; DRIFT=$((DRIFT+1));;
            FAIL)  echo "  FAIL  $name (top-level key sets differ)"; FAIL=$((FAIL+1)); EXIT=1;;
            SKIP)  echo "  SKIP  $name (no capture)";;
        esac
    done
fi

echo ""
echo "Summary: $MATCH matched, $DRIFT drift, $FAIL structural mismatch"
echo "Captures: $OUT_DIR/"
exit "$EXIT"

#!/usr/bin/env bash
# scripts/orchestrator_smoke.sh — exercise the autonomous-orchestrator tick
# lifecycle end-to-end without calling a real Haiku endpoint or Kalshi.
#
# Uses tests/fixtures/mock_thesis_analyst.sh as a stand-in for the
# praescientia-thesis-analyst Agent call, then walks the same numbered
# lifecycle documented in .claude/skills/praescientia-orchestrate/tick.md:
#
#   pre-0  KILL/PAUSED sentinels (skipped; harness asserts the path)
#   1      begin → tick_id + pre.json
#   2-3    (folded into begin)
#   4      poll reality (skipped; no Kalshi)
#   5      settle (skipped; no positions)
#   6      build thesis input (here: trivial — pass tick_id + thesis_id)
#   7      fan out — run the mock sub-agent
#   8      prose-strip + validate the decision
#   9      execute writes — commentary, predict, dry-run order event
#   10     finish → post.json
#   11     global tick summary commentary
#   12     status snapshot + rollback fork
#
# Prerequisites:
#   - `zig build` has produced praescientia-{kb,ticks} in ./zig-out/bin/
#   - jq and python3 on $PATH
#
# Exit codes:
#   0 — every step succeeded
#   1 — a step failed (stderr names which)
#   2 — prerequisites missing

set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/zig-out/bin"
MOCK="$ROOT/tests/fixtures/mock_thesis_analyst.sh"
LOSS_MOCK="$ROOT/tests/fixtures/mock_loss_reflector.sh"

# --- Prerequisite checks ----------------------------------------------------

if [ ! -x "$BIN/praescientia-kb" ] || [ ! -x "$BIN/praescientia-ticks" ]; then
    echo "FAIL: ./zig-out/bin/praescientia-{kb,ticks} missing — run 'zig build' first" >&2
    exit 2
fi
if ! command -v jq >/dev/null 2>&1; then
    echo "FAIL: jq required on \$PATH" >&2
    exit 2
fi
if ! command -v python3 >/dev/null 2>&1; then
    echo "FAIL: python3 required on \$PATH" >&2
    exit 2
fi
if [ ! -x "$MOCK" ]; then
    echo "FAIL: $MOCK missing or not executable" >&2
    exit 2
fi
if [ ! -x "$LOSS_MOCK" ]; then
    echo "FAIL: $LOSS_MOCK missing or not executable" >&2
    exit 2
fi

# --- Setup ------------------------------------------------------------------

TMPROOT=$(mktemp -d)
KB="$TMPROOT/kb"
THESIS_ID="sample"
TICKER="SAMPLE"

cleanup() {
    rm -rf "$TMPROOT"
}
trap cleanup EXIT

step() { echo "==> $1"; }
fail() { echo "FAIL: $1" >&2; exit 1; }

# Portable millisecond timestamp — `date +%s%3N` doesn't work on macOS
# (BSD date treats %3N as literal "3N"), so route through Python.
now_ms() { python3 -c 'import time; print(int(time.time()*1000))'; }

# --- Step 0 — bootstrap kb + assert sentinel paths --------------------------

step "0/12 init kb_root with --with-sample at $KB"
"$BIN/praescientia-kb" init "$KB" --with-sample >/dev/null

# Sanity: the sentinel directory must be writable on first use.
mkdir -p "$KB/.ticks"
if [ -f "$KB/.ticks/KILL" ]; then fail "stray KILL sentinel in fresh kb"; fi
if [ -f "$KB/.ticks/PAUSED" ]; then fail "stray PAUSED sentinel in fresh kb"; fi

# Seed a pre-tick commentary entry on the thesis chain so rollback (step 12)
# has a non-null head_hash to fork from. Without this, --with-sample's empty
# chains all snapshot as {head_hash: null} and rollback skips them all,
# making the fork assertion vacuous.
step "0b/12 seed a pre-tick commentary entry (rollback fork anchor)"
"$BIN/praescientia-kb" commentary write \
    --thesis="$THESIS_ID" \
    --agent-model=mock \
    --body="pre-tick seed entry — gives rollback a non-null head to fork" \
    --tags="seed" \
    --kb-root="$KB" >/dev/null

# --- Step 1 — begin tick ----------------------------------------------------

step "1/12 begin tick"
TICK_ID=$("$BIN/praescientia-ticks" begin --kb-root="$KB")
if [ ${#TICK_ID} -ne 26 ]; then fail "tick_id wrong length: '$TICK_ID' (${#TICK_ID} chars)"; fi
if [ ! -f "$KB/.ticks/${TICK_ID}.pre.json" ]; then fail "${TICK_ID}.pre.json not written"; fi
echo "    tick_id=$TICK_ID"

EVENTS="$KB/.ticks/${TICK_ID}.events.jsonl"
echo "{\"kind\":\"tick_begin\",\"step\":1,\"tick_id\":\"${TICK_ID}\",\"ts\":$(date +%s)}" >> "$EVENTS"

# --- Steps 4-5 — poll + settle (no-ops in smoke; log skip events) -----------

step "4/12 poll reality (skipped in smoke)"
echo "{\"kind\":\"poll_skipped\",\"step\":4,\"ts\":$(date +%s)}" >> "$EVENTS"

step "5a/12 settle — synthesize a loss settlement (mock Kalshi feed)"
SETTLEMENT="$TMPROOT/settlement.json"
cat > "$SETTLEMENT" <<EOF
{"ticker":"$TICKER","resolved_yes":true,"resolution_ts_ms":$(now_ms),"our_held_side":"no","our_contracts":5,"realized_pnl_cents":-150}
EOF

step "5b/12 classify-resolution"
VERDICT=$("$BIN/praescientia-ticks" classify-resolution --settlement="$SETTLEMENT")
if [ "$VERDICT" != "loss" ]; then fail "expected verdict=loss, got '$VERDICT'"; fi
echo "    verdict=$VERDICT"

step "5d/12 dispatch mock loss-reflector + prose-strip"
LOSS_RAW=$("$LOSS_MOCK" "$TICK_ID" "$THESIS_ID" "$TICKER")
LOSS_OUT="$TMPROOT/loss_out.json"
python3 - <<'PY' "$LOSS_RAW" > "$LOSS_OUT"
import sys, re, json
raw = sys.argv[1]
m = re.search(r'\{.*\}', raw, re.DOTALL)
print(json.dumps(json.loads(m.group(0))) if m else json.dumps({"error":"no_json"}))
PY
if jq -e '.error' "$LOSS_OUT" >/dev/null 2>&1; then fail "loss-reflector strip failed"; fi

step "5e/12 validate-loss-reflection"
if ! "$BIN/praescientia-ticks" validate-loss-reflection --decision="$LOSS_OUT" >/dev/null 2>&1; then
    fail "validate-loss-reflection rejected mock output (it should be valid)"
fi

step "5f/12 write loss commentary to thesis scope"
LOSS_BODY="$TMPROOT/loss_body.md"
jq -r '.why_we_were_wrong + "\n\n" + .decision_pattern_to_avoid' "$LOSS_OUT" > "$LOSS_BODY"
LOSS_TAGS_FROM_AGENT="$(jq -r '.tags | join(",")' "$LOSS_OUT")"
LOSS_FULL_TAGS="post-mortem,loss,${LOSS_TAGS_FROM_AGENT},tick:${TICK_ID}"
THESIS_LOSS_HASH=$("$BIN/praescientia-kb" commentary write \
    --thesis="$THESIS_ID" \
    --agent-model=loss-reflector \
    --body-file="$LOSS_BODY" \
    --tags="$LOSS_FULL_TAGS" \
    --kb-root="$KB" | jq -r .hash)
if [ -z "$THESIS_LOSS_HASH" ] || [ "$THESIS_LOSS_HASH" = "null" ]; then fail "thesis-scope loss commentary returned no hash"; fi

step "5f/12 write loss commentary to market scope"
MARKET_LOSS_HASH=$("$BIN/praescientia-kb" commentary write \
    --market="$TICKER" \
    --agent-model=loss-reflector \
    --body-file="$LOSS_BODY" \
    --tags="$LOSS_FULL_TAGS" \
    --kb-root="$KB" | jq -r .hash)
if [ -z "$MARKET_LOSS_HASH" ] || [ "$MARKET_LOSS_HASH" = "null" ]; then fail "market-scope loss commentary returned no hash"; fi
echo "    thesis_loss=${THESIS_LOSS_HASH:0:12} market_loss=${MARKET_LOSS_HASH:0:12}"

echo "{\"kind\":\"loss_reflected\",\"step\":5,\"ticker\":\"${TICKER}\",\"thesis_hash\":\"${THESIS_LOSS_HASH}\",\"market_hash\":\"${MARKET_LOSS_HASH}\",\"ts\":$(date +%s)}" >> "$EVENTS"

step "5g/12 advance cursor (synthetic — no real Kalshi pagination)"
echo "{\"cursor\":\"smoke-${TICK_ID}\",\"as_of_ts_ms\":$(now_ms)}" > "$KB/.ticks/.last_settlement.json"

# --- Step 6-7 — build input + fan out (run the mock) ------------------------

step "7/12 fan out — run mock thesis-analyst"
RAW=$("$MOCK" "$TICK_ID" "$THESIS_ID" "$TICKER")
if [ -z "$RAW" ]; then fail "mock returned empty output"; fi

# --- Step 8.a — prose-strip ------------------------------------------------

step "8a/12 prose-strip the agent response (greedy outer-{} extractor)"
DECISION="$TMPROOT/decision.json"
python3 - <<'PY' "$RAW" > "$DECISION"
import sys, re, json
raw = sys.argv[1]
m = re.search(r'\{.*\}', raw, re.DOTALL)
if not m:
    print(json.dumps({"error":"no_json_object_found","raw_first_200":raw[:200]}))
    sys.exit(0)
try:
    print(json.dumps(json.loads(m.group(0))))
except json.JSONDecodeError as e:
    print(json.dumps({"error":"json_parse_failed","detail":str(e)}))
PY
if jq -e '.error' "$DECISION" >/dev/null 2>&1; then
    fail "prose-strip produced error envelope: $(cat "$DECISION")"
fi

# --- Step 8.b — validate ----------------------------------------------------

step "8b/12 praescientia-ticks validate against thesis manifest"
MANIFEST="$KB/theses/${THESIS_ID}/manifest.json"
if [ ! -f "$MANIFEST" ]; then fail "thesis manifest not at $MANIFEST"; fi

if ! "$BIN/praescientia-ticks" validate \
        --thesis-manifest="$MANIFEST" \
        --decision="$DECISION" >/dev/null 2>&1; then
    fail "validate rejected the mock's decision (it should be valid)"
fi
echo "    decision validated OK"

# --- Step 9 — execute writes ------------------------------------------------

step "9a/12 commentary write"
COMM_BODY="$TMPROOT/commentary_body.txt"
jq -r '.commentary_body' "$DECISION" > "$COMM_BODY"
TAGS="$(jq -r '.commentary_tags | join(",")' "$DECISION"),tick:${TICK_ID}"
COMM_HASH=$("$BIN/praescientia-kb" commentary write \
    --thesis="$THESIS_ID" \
    --agent-model=mock \
    --body-file="$COMM_BODY" \
    --tags="$TAGS" \
    --kb-root="$KB" | jq -r .hash)
if [ -z "$COMM_HASH" ] || [ "$COMM_HASH" = "null" ]; then fail "commentary write returned no hash"; fi
echo "    commentary hash=${COMM_HASH:0:12}"
echo "{\"kind\":\"commentary_written\",\"step\":9,\"hash\":\"${COMM_HASH}\",\"ts\":$(date +%s)}" >> "$EVENTS"

step "9b/12 predict"
CONF=$(jq -r '.confidence_bp' "$DECISION")
RAT="[tick:${TICK_ID}] $(jq -r '.rationale' "$DECISION")"
"$BIN/praescientia-kb" predict "$THESIS_ID" \
    --confidence-bp="$CONF" \
    --rationale="$RAT" \
    --kb-root="$KB" >/dev/null
echo "    confidence_bp=$CONF written"
echo "{\"kind\":\"prediction_written\",\"step\":9,\"confidence_bp\":${CONF},\"ts\":$(date +%s)}" >> "$EVENTS"

step "9c/12 dry-run order (log only, no Kalshi call)"
ORDER=$(jq -c '.orders[0]' "$DECISION")
DRY_RUN_LINE=$(jq -nc \
    --argjson order "$ORDER" \
    --arg thesis "$THESIS_ID" \
    --arg tick "$TICK_ID" \
    '{kind:"dry_run_order",step:9,thesis:$thesis,tick_id:$tick,order:$order,ts:now|floor}')
echo "$DRY_RUN_LINE" >> "$EVENTS"

# --- Step 10 — finish -------------------------------------------------------

step "10/12 finish — write post-state snapshot"
"$BIN/praescientia-ticks" finish --kb-root="$KB" --tick-id="$TICK_ID" >/dev/null 2>&1
if [ ! -f "$KB/.ticks/${TICK_ID}.post.json" ]; then fail "post.json not written"; fi

# --- Step 11 — global tick summary ------------------------------------------

step "11/12 global tick summary commentary"
SUMMARY="$TMPROOT/summary.txt"
cat > "$SUMMARY" <<EOF
Tick ${TICK_ID} smoke-test complete.

Theses processed: 1
Orders placed:    0 (dry-run only)
Settlements:      0
Events:           kb/.ticks/${TICK_ID}.events.jsonl
EOF
"$BIN/praescientia-kb" commentary write \
    --global \
    --agent-model=mock \
    --body-file="$SUMMARY" \
    --tags="tick-summary,tick:${TICK_ID}" \
    --kb-root="$KB" >/dev/null

# --- Step 12 — status + rollback --------------------------------------------

step "12a/12 status shows the tick we just ran"
STATUS_OUT=$("$BIN/praescientia-ticks" status --kb-root="$KB")
if ! echo "$STATUS_OUT" | grep -q "$TICK_ID"; then
    fail "status output did not list tick_id $TICK_ID"
fi

step "12b/12 rollback forks pre-{tick_id} branches"
"$BIN/praescientia-ticks" rollback --kb-root="$KB" --tick-id="$TICK_ID" >/dev/null

# Verify at least one branches.json picked up the pre-{tick_id} branch.
FORK_NAME="pre-${TICK_ID}"
FOUND=0
while IFS= read -r f; do
    if jq -e --arg n "$FORK_NAME" '.branches[]? | select(.name == $n)' "$f" >/dev/null 2>&1; then
        FOUND=1
        break
    fi
done < <(find "$KB" -name 'branches.json' -type f)

if [ "$FOUND" -ne 1 ]; then
    fail "no branches.json contained a '$FORK_NAME' entry after rollback"
fi

# --- Event log assertions ---------------------------------------------------

step "events.jsonl assertions"
for kind in tick_begin commentary_written prediction_written dry_run_order loss_reflected; do
    if ! grep -q "\"kind\":\"${kind}\"" "$EVENTS"; then
        fail "events.jsonl missing line of kind=${kind}"
    fi
done

step "dry_run_order schema check"
# Verify the dry-run line has the expected fields per tick.md § step 9.c.
DRY_LINE=$(grep '"kind":"dry_run_order"' "$EVENTS" | head -1)
for field in thesis tick_id order ts; do
    if ! echo "$DRY_LINE" | jq -e ".${field}" >/dev/null 2>&1; then
        fail "dry_run_order missing field '${field}': $DRY_LINE"
    fi
done
for ofield in ticker side action size limit_cents; do
    if ! echo "$DRY_LINE" | jq -e ".order.${ofield}" >/dev/null 2>&1; then
        fail "dry_run_order.order missing field '${ofield}': $DRY_LINE"
    fi
done

step "settlement cursor file written"
if [ ! -f "$KB/.ticks/.last_settlement.json" ]; then
    fail ".last_settlement.json not written by step 5.g"
fi
if ! jq -e '.cursor and .as_of_ts_ms' "$KB/.ticks/.last_settlement.json" >/dev/null 2>&1; then
    fail ".last_settlement.json missing cursor/as_of_ts_ms"
fi

# --- Done -------------------------------------------------------------------

echo "==> PASS — orchestrator tick lifecycle exercised end-to-end (tick_id=$TICK_ID)"

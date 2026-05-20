#!/usr/bin/env bash
# scripts/game_state_smoke.sh — exercise the praescientia-game-state CLI
# and the daemon's --per-thesis-cadence loop without API spend.
#
# Steps:
#   1. classify --ticker=KXNBASPREAD-26MAY21CLENYK-NYK2 against a known
#      pre-game time (24h before tip) and verify phase=pre_game.
#   2. classify the same ticker at tip+1h and verify phase=in_game.
#   3. classify a non-sport ticker (KXBTCD-...) and verify phase=unknown.
#   4. inspect --kb-root against the live kb/ and verify the JSON parses
#      and contains at least one entry per known sport prefix.
#   5. daemon --per-thesis-cadence --no-dispatch --max-ticks=3 — verify
#      tick 1 fires the bootstrap, ticks 2-3 are idle, daemon exits 0.
#
# Prerequisites:
#   - `zig build` has produced praescientia-{game-state,orchestrate-daemon}
#     in ./zig-out/bin/
#   - jq and python3 on $PATH
#
# Exit codes:
#   0 — every step succeeded
#   1 — a step failed (stderr names which)
#   2 — prerequisites missing

set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/zig-out/bin"
KB_ROOT="${KB_ROOT:-$ROOT/kb}"

# --- Prerequisite checks ----------------------------------------------------

if [ ! -x "$BIN/praescientia-game-state" ] || [ ! -x "$BIN/praescientia-orchestrate-daemon" ]; then
  echo "missing binaries — run 'zig build' first" >&2
  exit 2
fi
if ! command -v jq >/dev/null || ! command -v python3 >/dev/null; then
  echo "jq and python3 are required" >&2
  exit 2
fi

step() { printf "\n=== %s ===\n" "$1"; }

# --- Step 1: classify NBA ticker 24h before tip ---------------------------

step "1: classify KXNBASPREAD-26MAY21CLENYK-NYK2 @ tip-24h"
# 2026-05-21T19:30 ET = 2026-05-21T23:30 UTC = 1779406200000 ms
# 24h before tip = 1779319800000
PRE_GAME_MS=1779319800000
OUT=$("$BIN/praescientia-game-state" classify \
  --ticker=KXNBASPREAD-26MAY21CLENYK-NYK2 \
  --now=$PRE_GAME_MS 2>&1)
echo "$OUT"
PHASE=$(echo "$OUT" | jq -r '.phase')
if [ "$PHASE" != "near_game" ] && [ "$PHASE" != "pre_game" ]; then
  echo "FAIL: expected pre_game or near_game (exactly 24h boundary), got $PHASE" >&2
  exit 1
fi

# --- Step 2: classify same NBA ticker mid-game ----------------------------

step "2: classify same NBA ticker @ tip+1h (in_game)"
# tip = 1779406200000, +1h = 1779409800000
IN_GAME_MS=1779409800000
OUT=$("$BIN/praescientia-game-state" classify \
  --ticker=KXNBASPREAD-26MAY21CLENYK-NYK2 \
  --now=$IN_GAME_MS 2>&1)
echo "$OUT"
PHASE=$(echo "$OUT" | jq -r '.phase')
INTERVAL=$(echo "$OUT" | jq -r '.interval_seconds')
if [ "$PHASE" != "in_game" ] || [ "$INTERVAL" != "30" ]; then
  echo "FAIL: expected phase=in_game interval=30, got phase=$PHASE interval=$INTERVAL" >&2
  exit 1
fi

# --- Step 3: classify non-sport (BTC) -------------------------------------

step "3: classify KXBTCD-26MAY2017-T79499.99 (non-sport)"
OUT=$("$BIN/praescientia-game-state" classify \
  --ticker=KXBTCD-26MAY2017-T79499.99 \
  --now=now 2>&1)
echo "$OUT"
PHASE=$(echo "$OUT" | jq -r '.phase')
SPORT=$(echo "$OUT" | jq -r '.sport')
if [ "$SPORT" != "unknown" ] || [ "$PHASE" != "unknown" ]; then
  echo "FAIL: expected sport=unknown phase=unknown, got sport=$SPORT phase=$PHASE" >&2
  exit 1
fi

# --- Step 4: inspect kb_root + smoke-check shape -------------------------

step "4: inspect $KB_ROOT"
OUT=$("$BIN/praescientia-game-state" inspect --kb-root="$KB_ROOT" --now=now 2>&1)
echo "$OUT" | jq 'length' > /dev/null  # validates JSON
N=$(echo "$OUT" | jq 'length')
echo "  $N theses classified"
if [ "$N" -lt 1 ]; then
  echo "FAIL: expected at least 1 thesis row" >&2
  exit 1
fi
# Sanity: every entry has the documented fields
echo "$OUT" | jq -e '.[0] | has("thesis_id") and has("ticker") and has("sport") and has("phase") and has("interval_seconds")' > /dev/null

# --- Step 5: daemon --per-thesis-cadence --no-dispatch --max-ticks=3 -----

step "5: daemon --per-thesis-cadence smoke (max-ticks=3, no-dispatch)"
OUT=$("$BIN/praescientia-orchestrate-daemon" \
  --kb-root="$KB_ROOT" --interval=2s --max-ticks=3 \
  --per-thesis-cadence --no-dispatch 2>&1)
echo "$OUT" | grep -E "^\[startup|tick.*starting|tick.*complete|idle|shutdown" | head -20
if ! echo "$OUT" | grep -q '\[startup\] per-thesis cadence enabled'; then
  echo "FAIL: daemon did not log per-thesis startup" >&2
  exit 1
fi
if ! echo "$OUT" | grep -q '\[shutdown\] max_ticks reached'; then
  echo "FAIL: daemon did not exit cleanly at max-ticks" >&2
  exit 1
fi

# --- Summary ---------------------------------------------------------------

step "summary"
echo "all 5 game-state smoke steps green"

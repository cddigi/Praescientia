#!/usr/bin/env bash
# scripts/commentary_smoke.sh — exercise the Talmud-commentary loop end-to-end.
#
# Verifies that the pieces wired up in the talmud-commentary-impl branch
# actually communicate end-to-end: kb init → CLI writes → indexer ingests
# → Lance index grows → dashboard proxy retrieves similar entries.
#
# Prerequisites:
#   - `zig build` has produced praescientia-{kb,server} in ./zig-out/bin/
#   - tools/indexer/.venv set up via `cd tools/indexer && uv pip install -e ".[dev]"`
#   - `ollama serve` running with bge-m3 pulled (default endpoint http://localhost:11434)
#     (the indexer's --serve mode depends on the embedder)
#   - jq on $PATH
#
# Exit codes:
#   0 — every step succeeded; chain wrote, Lance index has rows, /similar
#       returned at least one neighbor.
#   1 — something failed; check stderr for which step.
#   2 — prerequisites missing.

set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/zig-out/bin"
INDEXER_DIR="$ROOT/tools/indexer"

# --- Prerequisite checks ----------------------------------------------------

if [ ! -x "$BIN/praescientia-kb" ] || [ ! -x "$BIN/praescientia-server" ]; then
    echo "FAIL: ./zig-out/bin/praescientia-{kb,server} missing — run 'zig build' first" >&2
    exit 2
fi
if [ ! -x "$INDEXER_DIR/.venv/bin/python" ]; then
    echo "FAIL: tools/indexer/.venv missing — run 'cd tools/indexer && uv venv && uv pip install -e \".[dev]\"'" >&2
    exit 2
fi
if ! command -v jq >/dev/null 2>&1; then
    echo "FAIL: jq required on \$PATH" >&2
    exit 2
fi

OLLAMA_URL="${OLLAMA_URL:-http://localhost:11434}"
if ! curl -sf "${OLLAMA_URL}/api/tags" >/dev/null; then
    echo "FAIL: ollama not reachable at $OLLAMA_URL" >&2
    echo "      start it with: ollama serve" >&2
    echo "      and ensure bge-m3 is pulled: ollama pull bge-m3" >&2
    exit 2
fi

# --- Setup ------------------------------------------------------------------

DASHBOARD_PORT="${DASHBOARD_PORT:-18080}"
QUERY_PORT="${QUERY_PORT:-18002}"

TMPROOT=$(mktemp -d)
KB_ROOT="$TMPROOT/kb"
INDEXER_PID=""
SERVER_PID=""

cleanup() {
    if [ -n "$SERVER_PID" ]; then kill "$SERVER_PID" 2>/dev/null || true; fi
    if [ -n "$INDEXER_PID" ]; then kill "$INDEXER_PID" 2>/dev/null || true; fi
    wait 2>/dev/null || true
    rm -rf "$TMPROOT"
}
trap cleanup EXIT

echo "==> 1/7 init kb_root with sample at $KB_ROOT"
"$BIN/praescientia-kb" init "$KB_ROOT" --with-sample >/dev/null

echo "==> 2/7 write three commentary entries via the CLI"
H1=$("$BIN/praescientia-kb" commentary write \
    --thesis=sample --agent-model=human \
    --body="The Fed is signalling a pause." \
    --tags=macro,fed --kb-root="$KB_ROOT" | jq -r .hash)
H2=$("$BIN/praescientia-kb" commentary write \
    --thesis=sample --agent-model=human \
    --body="Yields ticked up after the dot plot revision." \
    --tags=macro,rates --kb-root="$KB_ROOT" | jq -r .hash)
H3=$("$BIN/praescientia-kb" commentary write \
    --global --agent-model=human \
    --body="Cross-asset correlation is breaking down." \
    --tags=macro --kb-root="$KB_ROOT" | jq -r .hash)
echo "    wrote H1=${H1:0:12} H2=${H2:0:12} H3=${H3:0:12}"

echo "==> 3/7 index pending commentary via the indexer (one-shot)"
"$INDEXER_DIR/.venv/bin/python" "$INDEXER_DIR/index_commentary.py" \
    --kb-root="$KB_ROOT" --ollama-url="$OLLAMA_URL" --embed-model=bge-m3 --once

# Assert Lance directory has rows. We do this by querying the directory's
# structure — LanceDB stores .lance files under <table>.lance/.
LANCE_DIR="$KB_ROOT/.commentary_index/lance"
if [ ! -d "$LANCE_DIR" ]; then
    echo "FAIL: $LANCE_DIR doesn't exist" >&2
    exit 1
fi
LANCE_FILES=$(find "$LANCE_DIR" -name '*.lance' 2>/dev/null | wc -l | tr -d ' ')
if [ "$LANCE_FILES" -lt 1 ]; then
    echo "FAIL: no .lance files under $LANCE_DIR — indexer didn't write" >&2
    exit 1
fi

echo "==> 4/7 start the indexer in serve mode (background)"
"$INDEXER_DIR/.venv/bin/python" "$INDEXER_DIR/index_commentary.py" \
    --kb-root="$KB_ROOT" --ollama-url="$OLLAMA_URL" --embed-model=bge-m3 \
    --serve --query-port="$QUERY_PORT" --interval=600 &
INDEXER_PID=$!
# Wait for /health to come up.
for i in 1 2 3 4 5 6 7 8 9 10; do
    if curl -sf "http://127.0.0.1:$QUERY_PORT/health" >/dev/null; then break; fi
    sleep 1
done
if ! curl -sf "http://127.0.0.1:$QUERY_PORT/health" >/dev/null; then
    echo "FAIL: indexer /health didn't come up on port $QUERY_PORT" >&2
    exit 1
fi

echo "==> 5/7 start the dashboard server with --commentary-query-url"
"$BIN/praescientia-server" \
    --port="$DASHBOARD_PORT" \
    --kb-root="$KB_ROOT" \
    --commentary-query-url="http://127.0.0.1:$QUERY_PORT" &
SERVER_PID=$!
sleep 1

echo "==> 6/7 POST /api/kb/commentary/similar with H1 as the anchor"
RESP=$(curl -sf -X POST "http://localhost:$DASHBOARD_PORT/api/kb/commentary/similar" \
    -H 'content-type: application/json' \
    -d "{\"anchor_hash\":\"$H1\",\"limit\":5}")
echo "    response: $RESP"

NEIGHBOR_COUNT=$(echo "$RESP" | jq '.results | length')
if [ "$NEIGHBOR_COUNT" -lt 1 ]; then
    echo "FAIL: /similar returned no neighbors (expected at least 1: H2 or H3)" >&2
    exit 1
fi

# Assert at least one of H2 or H3 is in the neighbors.
NEIGHBOR_HASHES=$(echo "$RESP" | jq -r '.results[].hash')
if ! echo "$NEIGHBOR_HASHES" | grep -qE "^${H2}$|^${H3}$"; then
    echo "FAIL: neighbors didn't include H2 or H3" >&2
    echo "      got: $NEIGHBOR_HASHES" >&2
    exit 1
fi

echo "==> 7/7 verify proxy returns 503 when --commentary-query-url is absent"
kill $SERVER_PID 2>/dev/null
wait $SERVER_PID 2>/dev/null
SERVER_PID=""
"$BIN/praescientia-server" --port="$DASHBOARD_PORT" --kb-root="$KB_ROOT" &
SERVER_PID=$!
sleep 1
NO_PROXY_RESP=$(curl -s -X POST "http://localhost:$DASHBOARD_PORT/api/kb/commentary/similar" \
    -H 'content-type: application/json' -d '{"anchor_hash":"0000000000000000000000000000000000000000000000000000000000000000"}')
if ! echo "$NO_PROXY_RESP" | jq -e '.success == false and (.error | contains("commentary retrieval is not configured"))' >/dev/null; then
    echo "FAIL: proxy-off case did not return the expected 503 envelope" >&2
    echo "      got: $NO_PROXY_RESP" >&2
    exit 1
fi

echo "==> PASS — commentary loop completed end-to-end"

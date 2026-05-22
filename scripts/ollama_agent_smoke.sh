#!/usr/bin/env bash
# scripts/ollama_agent_smoke.sh — exercise praescientia-ollama-agent against a
# real local Ollama daemon (Stage 2 of the Ollama-routing implementation plan).
#
# This is the first test that drives callOllamaChat end-to-end against a real
# LLM. Unlike the other smoke scripts in this directory, it is gated by
# OLLAMA_SMOKE=1 because it requires a pulled model (gigabytes on disk) and is
# not safe to run unconditionally in CI. When the gate is not set, the script
# exits 0 with a skip message so it can be invoked from any harness.
#
# Syntax check (safe in any environment, no Ollama required):
#   bash -n scripts/ollama_agent_smoke.sh
#
# Run live (requires Ollama on :11434 with the model pulled):
#   OLLAMA_SMOKE=1 ./scripts/ollama_agent_smoke.sh
#   OLLAMA_SMOKE=1 OLLAMA_SMOKE_MODEL=llama3.1:8b ./scripts/ollama_agent_smoke.sh
#
# Exit codes:
#   0 — gate disabled (skip), OR the binary returned a JSON envelope.
#   1 — gated on, binary call failed or output wasn't an outer-{...} envelope.
#   2 — gated on, prerequisites missing (Ollama unreachable on :11434).

set -euo pipefail

if [[ "${OLLAMA_SMOKE:-0}" != "1" ]]; then
    echo "[smoke] skipping: set OLLAMA_SMOKE=1 to run"
    exit 0
fi

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

# --- Prerequisite checks ----------------------------------------------------

if ! curl -sf http://localhost:11434/api/tags >/dev/null; then
    echo "[smoke] FAIL: ollama not reachable at http://localhost:11434" >&2
    echo "      start it with: ollama serve" >&2
    exit 2
fi

# --- Build (only if missing) ------------------------------------------------

BIN="$REPO_ROOT/zig-out/bin/praescientia-ollama-agent"
if [[ ! -x "$BIN" ]]; then
    echo "[smoke] building praescientia-ollama-agent..."
    zig build
fi

# --- Run --------------------------------------------------------------------

MODEL="${OLLAMA_SMOKE_MODEL:-qwen3.6:27b-mlx}"
PROMPT='{"thesis_id":"smoke-thesis","markets":[],"reality_head":null,"now_ms":1747800000000}'

echo "[smoke] invoking praescientia-ollama-agent --role=thesis-analyst --model=$MODEL"

# NB: do NOT redirect stderr to /dev/null. The binary emits HTTP-status
# breadcrumbs on failure (model not pulled → 404, OOM → 500, etc.) and those
# are exactly the diagnostics an operator needs when the smoke fails.
if ! OUT="$(echo "$PROMPT" | "$BIN" --role=thesis-analyst --model="$MODEL")"; then
    echo "[smoke] FAIL: praescientia-ollama-agent exited non-zero" >&2
    echo "      likely causes:" >&2
    echo "        - model not pulled: ollama pull $MODEL" >&2
    echo "        - OOM (try a smaller model via OLLAMA_SMOKE_MODEL=...)" >&2
    echo "        - Ollama daemon crashed mid-request" >&2
    exit 1
fi

# --- Assert outer-{...} envelope -------------------------------------------

case "$OUT" in
    '{'*'}')
        echo "[smoke] PASS — envelope: ${OUT:0:80}..."
        ;;
    *)
        echo "[smoke] FAIL: output is not a JSON envelope" >&2
        echo "      got: ${OUT:0:200}" >&2
        exit 1
        ;;
esac

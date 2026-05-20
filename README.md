# Praescientia

**Latin:** *praescientia* (foreknowledge)

> "The hardware and software are, after all, only the tools with which we do the processing and should not occupy the primary position in our thinking. It's high time we began to turn our attention to the data and the information."
> — **Grace Hopper, 1982**

## Overview

Praescientia is a prediction market trading system built on [Kalshi](https://kalshi.com), the CFTC-regulated event contracts exchange. It features a state rollback architecture inspired by Grace Hopper's insights on the cost of incorrect information.

**Core Concept:** Discrete, hashed state checkpoints enable O(1) divergence identification instead of O(n) context reprocessing — narrowing the gap between human "obvious" pattern recognition and GenAI's brute-force approach.

## Architecture

### State Chains with Rollback

Instead of a monolithic conversation context, we use discrete, hashed state blocks. Each item's hash is a Merkle accumulator (`SHA-256(prev_item.hash || canonical_payload)`), so equal heads guarantee equal chains — divergence detection is O(1) in the common case.

```
┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐
│  Genesis Block  │────▶│  Prediction 1   │────▶│  Prediction 2   │
│  hash: 0x0000   │     │  hash: 0xa1b2   │     │  hash: 0xc3d4   │
│  confidence: 1.0│     │  confidence: 0.6│     │  confidence: 0.7│
└─────────────────┘     └─────────────────┘     └─────────────────┘
                                                         │
                                                         ▼
                        ┌─────────────────┐     ┌─────────────────┐
                        │  Prediction 4   │◀────│  Prediction 3   │
                        │  hash: 0xg7h8   │     │  hash: 0xe5f6   │
                        │  confidence: 0.8│     │  confidence: 0.75│
                        │  DIVERGENCE     │     │                 │
                        └─────────────────┘     └─────────────────┘
```

The Zig API:

```zig
const std = @import("std");
const praescientia = @import("praescientia");

var chain: praescientia.state_chain.Chain = .init(gpa);
defer chain.deinit();

try chain.append("{\"prediction\":0.6}");
try chain.append("{\"prediction\":0.7}");

if (chain.divergesAt(&reality_chain)) |idx| {
    // Fork from chain.items[0..idx]; no full reprocessing needed.
}
```

`src/txlog.zig` is the JSONL persistence layer with `tx_` Crockford-base32 ULIDs and chained `prev_hash` for tamper-evident replay.

### Kalshi Integration

Kalshi is a CFTC-regulated exchange for event contracts. Authentication uses RSA-PSS (SHA-256, MGF1-SHA256, salt = digest length) via vendored mbedTLS in `src/kalshi/auth.zig`.

| Environment | Base URL |
|-------------|----------|
| **Demo** | `https://demo-api.kalshi.co/trade-api/v2` |
| **Live** | `https://api.elections.kalshi.com/trade-api/v2` |

The trading dashboard (`praescientia-server`) is a single static binary that embeds `server/dashboard.html` and proxies authenticated requests through `src/kalshi/*`.

## Project Structure

```
praescientia/
├── build.zig                    # Build entry: library + 16 binaries
├── build.zig.zon                # Zig 0.16.0 pinned, fingerprint stable
├── src/
│   ├── root.zig                 # Public lib surface: praescientia.{state_chain,txlog,canonical_json,kalshi.*}
│   ├── state_chain.zig          # Merkle-accumulator chain
│   ├── txlog.zig                # JSONL persistence + ULID tx_ids
│   ├── canonical_json.zig       # Hash-stable JSON (sorted object keys, no whitespace)
│   ├── kb/                      # Knowledge base — per-market + per-thesis chains on top of txlog
│   │   ├── chain.zig            # Open/read/append/fork chains; flock single-writer; torn-tail recovery
│   │   ├── branches.zig         # branches.json + fork + switchActive
│   │   ├── manifest.zig         # market.manifest + thesis.manifest parsers + validators
│   │   ├── ingest.zig           # observeMarket/Resolution/Manual + recomputeThesisReality
│   │   ├── rollup.zig           # Compile-time registry of rollup fns (weighted_avg_v1)
│   │   ├── divergence.zig       # temporalDivergence + outcomeDivergence
│   │   ├── metrics.zig          # Prometheus counters: appends, contention, recoveries, requests
│   │   └── init.zig             # Bootstrap a fresh kb_root tree (with optional sample manifests)
│   └── kalshi/                  # Library wrappers — one file per Kalshi endpoint group
│       ├── auth.zig             # RSA-PSS signing (mbedTLS-backed)
│       ├── client.zig           # HTTP transport, env switching, auth headers
│       ├── exchange.zig         # /exchange/*
│       ├── markets.zig          # /markets/*
│       ├── events.zig           # /events/*
│       ├── orders.zig           # /portfolio/orders*
│       ├── order_groups.zig     # /portfolio/order_groups/*
│       ├── portfolio.zig        # /portfolio/{balance,positions,...}
│       ├── historical.zig       # /historical/* + /markets/trades
│       ├── account.zig          # /account/*, /api_keys
│       ├── communications.zig   # RFQ / quote workflow
│       ├── search.zig           # /series/*, /search/*
│       ├── live_data.zig        # /milestones, /live_data/*
│       └── testdata/            # Captured demo-API fixtures for inline tests
├── tools/
│   ├── common.zig               # Shared CLI scaffolding (Juicy Main + subcommand dispatch)
│   ├── exchange.zig             # praescientia-exchange CLI
│   ├── markets.zig              # praescientia-markets CLI
│   ├── events.zig               # praescientia-events CLI
│   ├── historical.zig           # praescientia-historical CLI
│   ├── portfolio.zig            # praescientia-portfolio CLI
│   ├── orders.zig               # praescientia-orders CLI
│   ├── account.zig              # praescientia-account CLI
│   ├── communications.zig       # praescientia-communications CLI
│   ├── order_groups.zig         # praescientia-order-groups CLI
│   ├── live_data.zig            # praescientia-live-data CLI
│   ├── search.zig               # praescientia-search CLI
│   ├── kb.zig                   # praescientia-kb CLI (inspect, branches, fork, divergence)
│   ├── poll_resolved_markets.zig  # praescientia-poll-resolved-markets (CoinGecko prices only)
│   ├── test_conn.zig            # End-to-end demo-API smoke harness
│   ├── signtest.zig             # RSA-PSS sign one-off
│   ├── verifytest.zig           # RSA-PSS verify one-off
│   └── bench_state_chain.zig    # 100k-entry divergesAt microbenchmark
├── server/
│   ├── main.zig                 # std.http.Server + Io.Threaded loop
│   ├── handlers.zig             # One handler per route, delegates to src/kalshi/*
│   └── dashboard.html           # @embedFile'd into praescientia-server
├── scripts/
│   ├── cross_verify.sh          # Stage 1: Zig ↔ OpenSSL RSA-PSS interop
│   └── parity_check.sh          # Stage 3/4: Zig ↔ external reference (historical)
├── vendor/
│   └── mbedtls/                 # 3.6 LTS submodule for RSA-PSS
├── .secret/                     # gitignored — Kalshi API key + key ID
├── portfolios/                  # gitignored runtime txlog data
├── README.md
├── CLAUDE.md
└── UNLICENSE
```

## Requirements

- **Zig 0.16.0** — `brew install zig@0.16` (Homebrew) or download from <https://ziglang.org/download/0.16.0/>. The toolchain is pinned via `minimum_zig_version` in `build.zig.zon`; later minor versions are not guaranteed compatible.
- **mbedTLS 3.6 LTS** — vendored as a git submodule at `vendor/mbedtls`. After cloning, run `git submodule update --init --recursive`.
- **Kalshi API key** — drop `kalshi_api_key_id.txt` and `kalshi_api_key_private.txt` into `.secret/`. Public endpoints work without them.

## Quick Start

```bash
# First-time setup
git submodule update --init --recursive

# Build everything (library + 16 binaries)
zig build

# Run all tests (73 inline + CLI --help smoke check)
zig build test --summary all

# Start the dashboard at http://localhost:8080
./zig-out/bin/praescientia-server --port=8080

# End-to-end demo-API smoke check
./zig-out/bin/praescientia-test-conn

# RSA-PSS sign-verify interop (Zig ↔ OpenSSL)
./scripts/cross_verify.sh

# 100k-entry divergesAt microbenchmark (sub-millisecond target)
zig build bench -Doptimize=ReleaseFast && ./zig-out/bin/praescientia-bench-state-chain
```

## CLI Tools

All Kalshi CLIs accept `--demo` (default), `--live`, `--verbose`, and `--help`.

| Command | Purpose |
|---------|---------|
| `zig build run-exchange -- status` | `/exchange/{status,schedule,announcements}` |
| `zig build run-markets -- list --limit=10` | `/markets/*` (list, get, trades, orderbook, orderbooks, candlesticks) |
| `zig build run-events -- list` | `/events/*` (list, multivariate, get, metadata, candlesticks, forecast, collection) |
| `zig build run-historical -- cutoff` | `/historical/*` (cutoff, candlesticks, fills, orders, trades, markets) |
| `zig build run-portfolio -- balance` | `/portfolio/*` (balance, positions, settlements, fills, resting_value, subaccounts, transfers, netting) |
| `zig build run-orders -- list` | `/portfolio/orders*` (list, create, get, cancel, amend, decrease, queue_positions) |
| `zig build run-account -- limits` | `/account/*`, `/api_keys` |
| `zig build run-communications -- list_rfqs` | RFQ + quote workflow |
| `zig build run-order-groups -- list` | Order group lifecycle |
| `zig build run-live-data -- milestones` | `/milestones`, `/live_data/*` |
| `zig build run-search -- series KXBTCD` | `/series/{ticker}`, `/search/*` |
| `zig build run-kb -- inspect <chain-dir>` | `kb/` chains: `inspect`, `branches`, `fork`, `divergence`, `init`, `predict`, `add-market`, `add-thesis`, `commentary` |
| `zig build run-kb -- commentary write --thesis=ID --agent-model=NAME --body="..."` | Append a commentary entry to a thesis/market/global chain; also `list` and `show` |
| `python tools/indexer/index_commentary.py --kb-root=./kb --once` | Run the commentary indexer once (requires llama-server on 8001) |
| `zig build run-poll-markets -- --kb-root=./kb` | Poll Kalshi for every market under `--kb-root`; recompute every thesis |
| `zig build run-poll -- prices` | CoinGecko BTC/ETH/SOL spot |
| `zig build run-server -- --port=8080` | Dashboard at `http://localhost:<port>/` |
| `./zig-out/bin/praescientia-test-conn` | End-to-end demo smoke (every endpoint, exit 0/1) |
| `./zig-out/bin/praescientia-signtest` | One-shot RSA-PSS signer |
| `./zig-out/bin/praescientia-verifytest` | One-shot RSA-PSS verifier |

## Knowledge Base

`src/kb/` builds a Git-like chain substrate on top of `txlog.zig` + `state_chain.zig`. Each market and each thesis owns its own append-only chain in a `kb_root` directory; branches enable forked "what-if" exploration without touching the canonical history.

```
<kb_root>/
├── markets/<TICKER>/
│   ├── manifest.json            # {kind, ticker, trigger.price_delta_cents}
│   └── reality/
│       ├── main.jsonl           # Hash-chained observations from Kalshi
│       └── branches.json        # Fork metadata
├── theses/<id>/
│   ├── manifest.json            # {kind, market_set, rollup_fn, weights, trigger.confidence_delta_bp}
│   ├── reality/                 # Reduced from market reality via rollup_fn
│   ├── prediction/              # Author's belief checkpoints
│   └── commentary/              # Free-form AI/operator notes (see Commentary below)
└── commentary/global/           # Cross-thesis macro observations
```

Markets also gain a `commentary/` subdir; the global path is created on first write.

The `praescientia-kb` CLI inspects chains, lists branches, forks, and computes temporal divergence:

```bash
zig build run-kb -- inspect    <kb_root>/markets/KXBTC/reality
zig build run-kb -- branches   <kb_root>/markets/KXBTC/reality
zig build run-kb -- divergence <kb_root>/theses/T/prediction <kb_root>/theses/T/reality --threshold-bp=1000
```

Bootstrap a fresh `kb_root` (optionally with a sample market + thesis):

```bash
zig build run-kb -- init ./kb --with-sample
```

When the dashboard server is started with `--kb-root=PATH`, four routes become available:

| Route | Returns |
|---|---|
| `GET /api/kb/markets/{ticker}/head` | Active branch head + last 3 payloads |
| `GET /api/kb/theses/{id}/branches` | branches.json for the thesis reality chain |
| `GET /api/kb/theses/{id}/divergence?threshold_bp=N` | First divergence between prediction and reality |
| `GET /metrics` | Prometheus text exposition: appends, lock contention, torn-tail recoveries, observe skips, per-route request counts, kb_root_configured gauge |

The dashboard sidebar exposes "KB Markets" and "KB Theses" panels backed by these routes.

### Commentary

The Talmud-style commentary chain layers AI/operator prose on top of the reality and prediction chains. A LanceDB vector index serves cross-context retrieval — "what *else* in this kb bears on this situation?" — without bundling text into the chain itself. The chain is canonical; the index is disposable.

Three scopes, all using the same `txlog` machinery as reality/prediction:

- `theses/<id>/commentary/` — observations tied to a specific thesis (most common)
- `markets/<TICKER>/commentary/` — observations about a specific market
- `commentary/global/` — macro observations not tied to any one thesis

Payload schema (canonical-JSON, alphabetical keys): `agent {model, run_id}`, `body` (≤ 16 KB), `inputs {market_set_heads, prediction_head}`, `kind: "commentary"`, `parent_hash`, `references[]`, `tags[]` (≤ 8 entries / ≤ 32 chars each), `ts` (int64 ms).

Operator workflow:

```bash
# 1. Write a commentary entry. --agent-model is required (use "human" if you're typing it).
zig build run-kb -- commentary write \
    --thesis=fed-jun --agent-model=human \
    --body="Yields ticked up after the dot plot revision." \
    --tags=macro,rates --kb-root=./kb
# → prints {"hash":"...","scope":"theses/fed-jun/commentary"} so an agent driver can chain.

# 2. List recent entries for a scope.
zig build run-kb -- commentary list --thesis=fed-jun --kb-root=./kb --limit=20

# 3. Show the full canonical payload by hash (searches all scopes).
zig build run-kb -- commentary show <hash> --kb-root=./kb

# 4. Bring up the indexer + query service. Requires a long-lived llama-server
#    embedding daemon (BGE-M3 GGUF, port 8001 by default).
llama-server --embeddings -m bge-m3-Q4_K_M.gguf --port 8001 --ctx-size 8192 &
python tools/indexer/index_commentary.py --kb-root=./kb --serve --query-port=8002 &

# 5. Start the dashboard with the retrieval proxy enabled.
zig build run-server -- --kb-root=./kb --commentary-query-url=http://127.0.0.1:8002

# 6. Hit /similar with one of your hashes to get ranked neighbors from other scopes.
curl -X POST http://localhost:8080/api/kb/commentary/similar \
    -H 'content-type: application/json' \
    -d '{"anchor_hash":"<hash>", "limit":5, "exclude_scopes":["theses/fed-jun/commentary"]}'
```

The dashboard server also exposes three POST write routes (gated behind `--kb-root`): `/api/kb/theses/{id}/commentary`, `/api/kb/markets/{ticker}/commentary`, `/api/kb/commentary/global`. Same JSON shape as the CLI flags translated into fields; the server fills in `kind` and `ts`.

`./scripts/commentary_smoke.sh` exercises the full loop end-to-end (requires a running `llama-server`).

### Demo Loop

Walk a fresh operator from zero to a running prediction-vs-reality chain in six commands. The loop is one-shot per invocation — wrap step 4 in `while sleep 60; do …; done` (or cron) to keep the reality chain current.

```bash
# 1. Bootstrap a fresh kb_root.
zig build run-kb -- init ./kb

# 2. Register a market. --price-delta-cents controls the observation-firing threshold.
zig build run-kb -- add-market KXBTC-26 --price-delta-cents=1 --kb-root=./kb

# 3. Register a thesis over that market. Weights are basis points; market_set is derived from the keys.
zig build run-kb -- add-thesis fed-jun \
    --description="Fed cuts in June FOMC" \
    --weights='{"KXBTC-26":10000}' \
    --confidence-delta-bp=500 --kb-root=./kb

# 4. Poll Kalshi once. Refreshes every market under ./kb/markets/ then recomputes every thesis.
zig build run-poll-markets -- --kb-root=./kb

# 5. Record your prediction. confidence_bp = how strongly you believe the thesis (1..10000).
zig build run-kb -- predict fed-jun --confidence-bp=7200 --rationale="initial belief" --kb-root=./kb

# 6. Inspect divergence between belief and reality.
zig build run-kb -- divergence ./kb/theses/fed-jun/prediction ./kb/theses/fed-jun/reality
```

Step 4 honors `manifest.confidence_delta_bp`: thesis reality only grows when the aggregate moves by at least that many basis points. Auth is loaded from `.secret/kalshi_api_key_id.txt` + `.secret/kalshi_api_key_private.txt`; without them the poller exits with the Kalshi 401.

To verify the loop wires up against a live demo API, run `./scripts/demo_loop_smoke.sh`. It picks a clean open-status ticker, drives the loop end-to-end against `demo-api.kalshi.co`, and asserts both chains grew + divergence returned a sensible result.

The full design and rationale lives in `docs/plans/done/2026-05-17-state-chain-knowledge-base-design.md`. The demo loop spec lives in `docs/plans/2026-05-18-kalshi-demo-loop-design.md`.

## Autonomous Prediction Agent

The autonomous loop turns observed market reality into recorded belief and placed orders without a human in the inner loop. The architecture is a three-tier hierarchy:

- **Opus orchestrator** — a Claude Code session driven by the `/praescientia-orchestrate` skill. Owns the tick clock, snapshots chain heads, polls Kalshi, settles, and persists. Re-enters itself via `ScheduleWakeup` between ticks.
- **Haiku sub-agents** — one `praescientia-thesis-analyst` per thesis (parallel, per tick) and one `praescientia-loss-reflector` per resolved-and-lost market. Sub-agents emit constrained JSON and never write to the chain directly.
- **Orchestrator-side executor** — runs after fan-out. Validates every sub-agent response, clamps oversize orders, and serializes the writes per thesis.

The asymmetry on resolution is doctrine: wins log one line to `events.jsonl` (no chain writes); losses dispatch a mandatory post-mortem whose output flows into commentary so future thesis-analyst dispatches encounter the lesson via similarity search.

### Launching

```bash
# Inside a Claude Code session pointed at the project root:
claude
> /praescientia-orchestrate --kb-root=./kb --interval=300s
```

Flags:

| Flag | Default | Meaning |
|---|---|---|
| `--kb-root=PATH` | `./kb` | Knowledge-base root |
| `--interval=DURATION` | `300s` | Wall-clock seconds between tick starts (clamped to `[60, 3600]`) |
| `--max-ticks=N` | unbounded | Stop after N ticks (sentinel file at `kb/.ticks/.ticks_remaining`) |
| `--theses=foo,bar` | all | Partial fan-out for debugging |
| `--dry-run` | off | Replace real `praescientia-orders` calls with `dry_run_order` event lines |
| `--once` | — | Alias for `--max-ticks=1` |
| `--pause` / `--resume` | — | Toggle `kb/.ticks/PAUSED`; exits without running a tick |

### Kill switches

Operator-controlled file sentinels, checked at every tick entry and at the end of each tick before scheduling the next:

| File | Effect |
|---|---|
| `kb/.ticks/KILL` | Abort immediately. No analysis, no writes, no `ScheduleWakeup`. |
| `kb/.ticks/PAUSED` | Run steps 1-8 + 10-12 normally; **skip** step 9 (execute). Belief signal still advances; orders are frozen. |
| `kb/.ticks/.daily_orders.json` | Auto-pause if today's order count ≥ 500. Resets at midnight UTC. |

To emergency-stop without entering the session:

```bash
touch ./kb/.ticks/KILL
```

### Where a tick lives on disk

Each tick produces a fixed set of artifacts under `kb/.ticks/{tick_id}.*`:

| File | Written at | Contents |
|---|---|---|
| `{tick_id}.pre.json` | step 1 (begin) | Snapshot of every chain head before the tick |
| `{tick_id}.post.json` | step 10 (finish) | Snapshot after all writes |
| `{tick_id}.events.jsonl` | throughout | Step-by-step event log, one JSON object per line |
| `{tick_id}.rejected.json` | step 7/8 failures | Array of sub-agent payloads that failed schema/validation |

Plus cross-tick state:

```
kb/.ticks/
├── .lock                       # flock held by `praescientia-ticks begin`
├── .last_settlement.json       # Settlement cursor (advances after loss reflection persists)
├── .daily_orders.json          # Daily-breaker counter
├── .ticks_remaining            # --max-ticks counter (deleted at terminal tick)
├── .global_events.jsonl        # Cross-tick events (kill-abort, daily-pause, …)
├── KILL                        # Operator sentinel — abort
└── PAUSED                      # Operator/breaker sentinel — skip execute
```

### Inspecting a tick

```bash
# Most recent 10 ticks
./zig-out/bin/praescientia-ticks status --kb-root=./kb

# Walk one tick top-to-bottom (events map 1:1 to numbered steps in tick.md)
jq -c . ./kb/.ticks/<tick_id>.events.jsonl

# Diff what changed: chain heads before vs after
diff <(jq -S . ./kb/.ticks/<tick_id>.pre.json) \
     <(jq -S . ./kb/.ticks/<tick_id>.post.json)

# Prepare a rollback anchor (forks each pre-tick head as branch `pre-<tick_id>`)
./zig-out/bin/praescientia-ticks rollback --kb-root=./kb --tick-id=<tick_id>
```

### End-to-end smoke

`./scripts/orchestrator_smoke.sh` exercises the full 12-step lifecycle without calling Anthropic or Kalshi. It uses canned sub-agent JSON via `tests/fixtures/mock_thesis_analyst.sh` and `tests/fixtures/mock_loss_reflector.sh`, then asserts every artifact above lands as expected — including the settlement → loss-reflection → two-scope commentary write path. The mocks deliberately wrap their JSON in prose so the smoke exercises the orchestrator's outer-`{}` extractor every run.

### Design + lifecycle reference

- **Design doc** (rationale, decision summary, asymmetries): `docs/plans/done/2026-05-19-autonomous-prediction-agent-design.md`
- **Per-tick checklist** (operator-readable steps with exact CLIs): `.claude/skills/praescientia-orchestrate/tick.md`
- **Sub-agent definitions**: `.claude/agents/praescientia-{thesis-analyst,loss-reflector}.md`

## Philosophy

The central insight is that **the gap between human and AI reasoning** in error identification isn't a fundamental limitation — it's an architectural choice.

Humans don't reprocess their entire life history when they realize they made a wrong turn. They have checkpoint systems: "I was fine until I turned left at the gas station."

This project gives GenAI the same capability for prediction markets:
1. Each prediction is a checkpoint
2. Reality provides ground truth
3. Divergence is identified by comparison, not reprocessing
4. Rollback forks from valid state

> "Who determines what is true and what is false? We can't. Who is the definitive source of truth?"

For prediction markets, the market IS the source of truth. When our model diverges from the market, we know exactly where we went wrong — because we have the checkpoints.

## License

[Unlicense](UNLICENSE) — Public Domain

---

*"Never let your sense of morals prevent you from doing what is right." — Salvor Hardin*

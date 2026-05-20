# Praescientia — Session Context

> **Last Updated:** 2026-05-19 — Autonomous prediction agent shipped (Stages 1-9 complete).
> **Platform:** Kalshi — CFTC-regulated event contracts exchange
> **Language:** Zig 0.16.0 (pinned).
> **GitHub:** https://github.com/cddigi/Praescientia

---

## Project Overview

**Praescientia** (Latin: foreknowledge) is a prediction market trading system on Kalshi with state rollback architecture, inspired by Grace Hopper's insights on the cost of incorrect information.

**Core Concept:** Discrete, hashed state checkpoints enable O(1) divergence identification instead of O(n) context reprocessing — narrowing the gap between human "obvious" pattern recognition and GenAI's brute-force approach.

---

## Project Structure

```
praescientia/
├── build.zig                    # Builds the library + 16 binaries
├── build.zig.zon                # Zig 0.16.0 pinned via minimum_zig_version
├── src/
│   ├── root.zig                 # Public lib surface (praescientia.{state_chain,txlog,canonical_json,kalshi.*})
│   ├── state_chain.zig          # Merkle-accumulator hashed chain (Hopper core)
│   ├── txlog.zig                # JSONL transaction log + ULID tx_ids
│   ├── canonical_json.zig       # Hash-stable JSON (sorted keys, no whitespace)
│   ├── kb/                      # Knowledge-base substrate on top of state_chain + txlog
│   │   ├── chain.zig            # Open/read/append/fork with flock + torn-tail recovery
│   │   ├── branches.zig         # branches.json metadata + fork + switchActive
│   │   ├── manifest.zig         # market.manifest + thesis.manifest parsers + validators
│   │   ├── ingest.zig           # observeMarket/Resolution/Manual + recomputeThesisReality
│   │   ├── rollup.zig           # Compile-time registry (weighted_avg_v1)
│   │   ├── divergence.zig       # temporalDivergence + outcomeDivergence
│   │   ├── metrics.zig          # Prometheus counters (appends, contention, requests, gauge)
│   │   ├── init.zig             # initTree(io, root, with_sample) — kb_root bootstrap
│   │   ├── predict.zig          # writePrediction (thesis.prediction checkpoint)
│   │   ├── commentary.zig       # Talmud-commentary chain type (writeCommentary, encode, validate, Scope)
│   │   └── ticks.zig            # Tick/SnapshotEntry/OrderIntent/Settlement + validate + classifyResolution
│   └── kalshi/                  # One file per Kalshi endpoint group
│       ├── auth.zig             # RSA-PSS signing via vendored mbedTLS
│       ├── client.zig           # HTTP transport, env switching, auth-header signing
│       ├── exchange.zig
│       ├── markets.zig
│       ├── events.zig
│       ├── orders.zig
│       ├── order_groups.zig
│       ├── portfolio.zig
│       ├── historical.zig
│       ├── account.zig
│       ├── communications.zig
│       ├── search.zig
│       ├── live_data.zig
│       └── testdata/            # Captured demo-API JSON fixtures (inline @embedFile tests)
├── tools/                       # One CLI per Kalshi endpoint group + a few utilities
│   ├── common.zig               # Shared scaffolding (Juicy Main + subcommand dispatch)
│   ├── exchange.zig             # praescientia-exchange
│   ├── markets.zig              # praescientia-markets
│   ├── events.zig               # praescientia-events
│   ├── historical.zig           # praescientia-historical
│   ├── portfolio.zig            # praescientia-portfolio
│   ├── orders.zig               # praescientia-orders
│   ├── account.zig              # praescientia-account
│   ├── communications.zig       # praescientia-communications
│   ├── order_groups.zig         # praescientia-order-groups
│   ├── live_data.zig            # praescientia-live-data
│   ├── search.zig               # praescientia-search
│   ├── kb.zig                   # praescientia-kb (inspect/branches/fork/divergence/init/predict/add-market/add-thesis/commentary)
│   ├── ticks.zig                # praescientia-ticks (snapshot/begin/finish/validate/validate-loss-reflection/classify-resolution/status/rollback)
│   ├── poll_markets.zig         # praescientia-poll-markets (Kalshi → kb_root demo loop)
│   ├── poll_resolved_markets.zig# praescientia-poll-resolved-markets (CoinGecko spot)
│   ├── test_conn.zig            # End-to-end demo-API smoke harness
│   ├── signtest.zig             # RSA-PSS sign one-off (Stage 1)
│   ├── verifytest.zig           # RSA-PSS verify one-off
│   ├── bench_state_chain.zig    # divergesAt 100k microbenchmark
│   └── indexer/                 # Python: commentary chain indexer (LanceDB + llama-server BGE-M3) + FastAPI /similar
│       ├── index_commentary.py  # tail/Cursors/LlamaServerEmbedder/run_once/run_loop/build_query_app
│       ├── test_indexer.py      # pytest — embed call is mocked; llama-server not required
│       └── pyproject.toml       # uv/pip-compatible
├── server/
│   ├── main.zig                 # std.http.Server + Io.Threaded accept loop
│   ├── handlers.zig             # One handler per route, delegates to src/kalshi/*
│   └── dashboard.html           # @embedFile'd into praescientia-server
├── scripts/
│   ├── cross_verify.sh          # Stage 1 Zig ↔ OpenSSL RSA-PSS interop check
│   ├── parity_check.sh          # Historical parity harness (vs Julia, pre-removal)
│   ├── demo_loop_smoke.sh       # End-to-end KB loop against Kalshi demo API
│   ├── commentary_smoke.sh      # End-to-end Talmud-commentary loop (requires llama-server)
│   └── orchestrator_smoke.sh    # End-to-end tick lifecycle (uses mock sub-agents; no Anthropic/Kalshi calls)
├── tests/
│   └── fixtures/
│       ├── agent_outputs/       # Captured Haiku dry-runs (thesis-analyst + loss-reflector)
│       ├── decisions/           # Golden inputs for praescientia-ticks validate
│       ├── loss_reflections/    # Golden inputs for praescientia-ticks validate-loss-reflection
│       ├── settlements/         # Golden inputs for praescientia-ticks classify-resolution
│       ├── mock_thesis_analyst.sh   # Mock sub-agent stand-in (prose-wrapped decision JSON)
│       └── mock_loss_reflector.sh   # Mock post-mortem stand-in (prose-wrapped reflection JSON)
├── .claude/
│   ├── agents/
│   │   ├── praescientia-thesis-analyst.md   # Haiku — one thesis per invocation, JSON decision
│   │   └── praescientia-loss-reflector.md   # Haiku — post-mortem per resolved-and-lost market
│   └── skills/
│       └── praescientia-orchestrate/        # Opus orchestrator skill (SKILL.md + tick.md)
├── vendor/
│   └── mbedtls/                 # 3.6 LTS submodule (RSA-PSS)
├── .secret/                     # gitignored — Kalshi API key + id
├── portfolios/                  # gitignored runtime txlog data
├── README.md
├── CLAUDE.md                    # This file
└── UNLICENSE
```

---

## Trading Principles

**You can sell contracts before resolution.** This is critical for risk management:

### When to Sell (Take Profits)
- Odds shift unexpectedly in your favor — lock in gains
- Position reaches target profit threshold (e.g., 50%+ return)
- New information validates your thesis early

### When to Cut Losses
- Thesis invalidated by new information
- Odds move significantly against you (limit losses to X%)
- Better opportunity emerges elsewhere

### When to Flip Position
- Confidence shifts based on new evidence
- Original thesis was wrong — switch to the other side
- Market dynamics changed fundamentally

### Unrealized P&L
Always know what you could sell for NOW, not just at resolution:
```
Unrealized P&L = (Current Price × Contracts) - Cost
```

---

## Build & Run

```bash
# First-time setup
git submodule update --init --recursive
zig build

# All tests (state-chain, txlog, canonical JSON, auth round-trip, parsers,
# server handler tests, CLI --help smoke check)
zig build test --summary all

# Dashboard at http://localhost:8080
./zig-out/bin/praescientia-server --port=8080 [--live]

# End-to-end live-API smoke against demo (every implemented endpoint)
./zig-out/bin/praescientia-test-conn

# RSA-PSS sign-verify interop (Zig ↔ OpenSSL)
./scripts/cross_verify.sh

# 100k-entry divergesAt microbenchmark — sub-millisecond target
zig build bench -Doptimize=ReleaseFast && ./zig-out/bin/praescientia-bench-state-chain
```

All Kalshi tools accept `--demo` (default) / `--live` / `--verbose` / `--help`.

| Surface | CLI | Backing library module |
|---------|-----|------------------------|
| Dashboard server | `zig build run-server -- --port=8080 [--kb-root=PATH]` | `server/{main,handlers}.zig` |
| Exchange | `zig build run-exchange -- status\|schedule\|announcements` | `src/kalshi/exchange.zig` |
| Markets | `zig build run-markets -- list\|get TICKER\|orderbook TICKER\|trades\|candlesticks\|orderbooks` | `src/kalshi/markets.zig` |
| Events | `zig build run-events -- list\|multivariate\|get\|metadata\|candlesticks\|forecast\|collection` | `src/kalshi/events.zig` |
| Historical | `zig build run-historical -- cutoff\|candlesticks\|fills\|orders\|trades\|markets\|market` | `src/kalshi/historical.zig` |
| Portfolio | `zig build run-portfolio -- balance\|positions\|settlements\|fills\|resting_value\|subaccounts_*` | `src/kalshi/portfolio.zig` |
| Orders | `zig build run-orders -- list\|create\|get\|cancel\|amend\|decrease\|queue_*` | `src/kalshi/orders.zig` |
| Order Groups | `zig build run-order-groups -- list\|create\|get\|delete\|reset\|trigger\|set_limit` | `src/kalshi/order_groups.zig` |
| Communications | `zig build run-communications -- comms_id\|list_rfqs\|create_rfq\|*_quote\|accept_quote` | `src/kalshi/communications.zig` |
| Account | `zig build run-account -- list_keys\|create_key\|generate_key\|delete_key\|limits\|incentives\|fcm_*` | `src/kalshi/account.zig` |
| Search | `zig build run-search -- tags\|sport_filters\|targets\|target\|series TICKER` | `src/kalshi/search.zig` |
| Live Data | `zig build run-live-data -- milestones\|milestone\|live\|live_legacy\|batch\|game_stats` | `src/kalshi/live_data.zig` |
| Knowledge base | `zig build run-kb -- inspect\|branches\|fork\|divergence\|init\|predict\|add-market\|add-thesis\|commentary` | `src/kb/*` |
| Tick lifecycle | `zig build run-ticks -- snapshot\|begin\|finish\|validate\|validate-loss-reflection\|classify-resolution\|status\|rollback` | `src/kb/ticks.zig` + `tools/ticks.zig` |
| Orchestrator (Opus) | `/praescientia-orchestrate --kb-root=PATH --interval=300s [--max-ticks=N] [--theses=...] [--dry-run] [--pause\|--resume]` | `.claude/skills/praescientia-orchestrate/{SKILL.md,tick.md}` |
| Thesis sub-agent (Haiku) | `Agent({subagent_type:"praescientia-thesis-analyst", prompt:<§2 JSON>})` | `.claude/agents/praescientia-thesis-analyst.md` |
| Loss-reflector sub-agent (Haiku) | `Agent({subagent_type:"praescientia-loss-reflector", prompt:<§8 JSON>})` | `.claude/agents/praescientia-loss-reflector.md` |
| Commentary indexer | `python tools/indexer/index_commentary.py --kb-root=PATH [--once\|--serve]` | `tools/indexer/index_commentary.py` |
| KB poller | `zig build run-poll-markets -- --kb-root=./kb` | `tools/poll_markets.zig` |
| Demo loop smoke | `./scripts/demo_loop_smoke.sh` | `scripts/demo_loop_smoke.sh` |
| Orchestrator smoke | `./scripts/orchestrator_smoke.sh` | `scripts/orchestrator_smoke.sh` (uses mock sub-agents) |
| Metrics | `GET /metrics` on the dashboard server | `src/kb/metrics.zig` |
| CoinGecko spot | `zig build run-poll -- prices` | `tools/poll_resolved_markets.zig` |
| Smoke harness | `./zig-out/bin/praescientia-test-conn [--env=demo\|live] [--capture-dir=PATH]` | exercises every above CLI |
| RSA-PSS sign/verify | `./zig-out/bin/praescientia-{signtest,verifytest}` | `src/kalshi/auth.zig` |

**Kalshi API Config:**
- Demo: `https://demo-api.kalshi.co/trade-api/v2`
- Live: `https://api.elections.kalshi.com/trade-api/v2`
- Auth: RSA-PSS (SHA-256, MGF1-SHA256, salt = digest length) via `src/kalshi/auth.zig` (vendored mbedTLS).
- Private key path: `.secret/kalshi_api_key_private.txt`
- Key ID path: `.secret/kalshi_api_key_id.txt`

**When to create a script:**
- Any task that fetches external data (prices, API calls)
- Any task that parses or evaluates portfolio positions
- Any repetitive analysis or reporting task

**When to extend a CLI vs. write a one-off script:**
- If the task hits Kalshi: add a subcommand to the matching `tools/*.zig` so the CLI surface stays canonical.
- If the task is shell-only (e.g. an interop check) or hits non-Kalshi APIs (CoinGecko, Polymarket): add a `scripts/*.sh` or a new `tools/*.zig` binary.

---

## Key Dates (Upcoming)

| Date | Event | Relevance |
|------|-------|-----------|
| Jun 17-18 | FOMC Meeting | Next rate decision |
| Jul 30 | Q2 2026 GDP | Two negative quarters = recession |
| Nov 3 | Midterm Elections | Political uncertainty |
| Dec 9 | Final FOMC 2026 | Last rate decision of the year |

---

## GitButler Workflow

GitButler (`but`) is the canonical version-control interface — never use `git` write commands. The full skill lives at `~/.claude/skills/gitbutler/`. Mandatory points:

- `but status -fv` before any mutation to gather fresh CLI IDs.
- After `but branch new <name>`, **immediately** run `but mark <name>` so the post-tool hook auto-stages to the intended branch instead of creating a parallel `cd-branch-N`. Without this, work gets scattered across two virtual branches that have to be consolidated by hand in the GUI.
- Use `--status-after` on every mutation so the IDs in the output match the workspace.
- File IDs from `but status -fv` / `but diff` / `but show`; never hardcode.
- `but commit <branch> -m "..." --changes <id1>,<id2> --status-after` is the standard commit shape.
- For irreversible operations (force push, branch delete with commits, etc.) — confirm with the user first.

---

## Notes

- Zig 0.16.0 is pinned via `build.zig.zon` `minimum_zig_version`. Upgrade to 0.17 is a dedicated PR.
- mbedTLS lives at `vendor/mbedtls` (3.6 LTS, submodule). Initialize with `git submodule update --init --recursive`.
- Grace Hopper is our hero.

---

*"The cost of incorrect information... I can go up to almost half a million dollars to get that file to a higher level of correctness, because that's what I stand to lose."* — Grace Hopper, 1982

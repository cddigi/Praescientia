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
│   │   ├── manifest.zig         # market.manifest + thesis.manifest parsers
│   │   ├── ingest.zig           # observeMarket/Resolution/Manual + recomputeThesisReality
│   │   ├── rollup.zig           # Compile-time registry of rollup fns (weighted_avg_v1)
│   │   └── divergence.zig       # temporalDivergence + outcomeDivergence
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
| `zig build run-kb -- inspect <chain-dir>` | `kb/` chains: `inspect`, `branches`, `fork`, `divergence` |
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
└── theses/<id>/
    ├── manifest.json            # {kind, market_set, rollup_fn, weights, trigger.confidence_delta_bp}
    ├── reality/                 # Reduced from market reality via rollup_fn
    └── prediction/              # Author's belief checkpoints
```

The `praescientia-kb` CLI inspects chains, lists branches, forks, and computes temporal divergence:

```bash
zig build run-kb -- inspect    <kb_root>/markets/KXBTC/reality
zig build run-kb -- branches   <kb_root>/markets/KXBTC/reality
zig build run-kb -- divergence <kb_root>/theses/T/prediction <kb_root>/theses/T/reality --threshold-bp=1000
```

When the dashboard server is started with `--kb-root=PATH`, three read-only routes become available:

| Route | Returns |
|---|---|
| `GET /api/kb/markets/{ticker}/head` | Active branch head + last 3 payloads |
| `GET /api/kb/theses/{id}/branches` | branches.json for the thesis reality chain |
| `GET /api/kb/theses/{id}/divergence?threshold_bp=N` | First divergence between prediction and reality |

The full design and rationale lives in `docs/plans/2026-05-17-state-chain-knowledge-base-design.md`.

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

*Grace Hopper is our hero.*

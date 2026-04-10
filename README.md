# Praescientia

**Latin:** *praescientia* (foreknowledge)

> "The hardware and software are, after all, only the tools with which we do the processing and should not occupied the primary position in our thinking. It's high time we began to turn our attention to the data and the information."
> — **Grace Hopper, 1982**

## Overview

Praescientia is a prediction market trading system built on [Kalshi](https://kalshi.com), the CFTC-regulated event contracts exchange. It features a state rollback architecture inspired by Grace Hopper's insights on the cost of incorrect information.

**Core Concept:** Discrete, hashed state checkpoints enable O(1) divergence identification instead of O(n) context reprocessing — narrowing the gap between human "obvious" pattern recognition and GenAI's brute-force approach.

## Architecture

### State Chains with Rollback

Instead of a monolithic conversation context, we use discrete, hashed state blocks:

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

When reality diverges from prediction, we identify the exact block and fork:

```julia
divergence = calculate_divergence_point(chain, reality; threshold=0.15)
new_chain = rollback_to_block(chain, divergence - 1)
# Fork from last valid state — no reprocessing needed
```

### Kalshi Integration

Kalshi is a CFTC-regulated exchange for event contracts. Authentication uses RSA-PSS signing via the `KalshiAuth` module.

| Environment | Base URL |
|-------------|----------|
| **Demo** | `https://demo-api.kalshi.co/trade-api/v2` |
| **Live** | `https://api.elections.kalshi.com/trade-api/v2` |

The trading dashboard (`kalshi_server.jl`) provides a web frontend powered by Oxygen.jl that proxies authenticated requests to the Kalshi API, supporting market browsing, portfolio management, and order placement.

## Project Structure

```
praescientia/
├── src/
│   ├── Praescientia.jl      # Core module (state chains, predictions)
│   ├── TxLog.jl             # JSONL transaction log (blockchain-style)
│   └── KalshiAuth.jl        # Kalshi API auth (RSA-PSS signing, live/demo)
├── scripts/
│   ├── kalshi_exchange.jl    # Exchange status, announcements, schedule
│   ├── kalshi_markets.jl     # Markets: list, get, trades, orderbook
│   ├── kalshi_events.jl      # Events: list, metadata, forecasts
│   ├── kalshi_orders.jl      # Orders: create, cancel, batch, amend
│   ├── kalshi_order_groups.jl# Order groups: create, reset, trigger
│   ├── kalshi_portfolio.jl   # Portfolio: balance, positions, settlements
│   ├── kalshi_historical.jl  # Historical: cutoff, candlesticks, fills
│   ├── kalshi_communications.jl # RFQ & quotes workflow
│   ├── kalshi_account.jl     # API keys, limits, incentives
│   ├── kalshi_search.jl      # Search: tags, filters, series
│   ├── kalshi_live_data.jl   # Milestones & live data
│   └── kalshi_test.jl        # API connectivity test
├── kalshi_server.jl          # Oxygen.jl trading dashboard server
├── kalshi_dashboard.html     # Trading dashboard frontend
├── test/
│   ├── runtests.jl           # Test suite runner
│   ├── test_txlog.jl         # Transaction log tests
│   └── test_server.jl        # Server tests
├── Project.toml
├── Manifest.toml
├── CLAUDE.md                 # Session context for Claude Code
├── README.md
└── UNLICENSE
```

## Requirements

- Julia 1.9+
- Packages: HTTP.jl, JSON3.jl, Oxygen.jl, SHA.jl, Dates, UUIDs
- Kalshi API key (RSA private key + key ID)

## Quick Start

```bash
# Install dependencies
julia --project=. -e 'using Pkg; Pkg.instantiate()'

# Start the trading dashboard
julia --project=. kalshi_server.jl [--port=8080] [--live] [--verbose]

# Run tests
julia --project=. test/runtests.jl
```

### Kalshi API Scripts

All scripts support `--demo` (default) and `--live` flags, plus `--verbose` for debug output.

```bash
# Check exchange status
julia --project=. scripts/kalshi_exchange.jl status

# Browse open markets
julia --project=. scripts/kalshi_markets.jl list --status=open

# Check portfolio balance
julia --project=. scripts/kalshi_portfolio.jl balance

# Place an order
julia --project=. scripts/kalshi_orders.jl create
```

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

# Praescientia — Session Context

> **Last Updated:** April 10, 2026
> **Platform:** Kalshi — CFTC-regulated event contracts exchange

---

## Project Overview

**Praescientia** (Latin: foreknowledge) is a prediction market trading system on Kalshi with state rollback architecture, inspired by Grace Hopper's insights on the cost of incorrect information.

**Core Concept:** Discrete, hashed state checkpoints enable O(1) divergence identification instead of O(n) context reprocessing — narrowing the gap between human "obvious" pattern recognition and GenAI's brute-force approach.

**GitHub:** https://github.com/cddigi/Praescientia

---

## Project Structure

```
praescientia/
├── src/
│   ├── Praescientia.jl      # Core module (state chains, predictions)
│   ├── TxLog.jl             # JSONL transaction log (blockchain-style)
│   └── KalshiAuth.jl        # Kalshi API auth (RSA-PSS signing, live/demo)
├── scripts/
│   ├── kalshi_exchange.jl    # Exchange status, announcements, schedule
│   ├── kalshi_historical.jl  # Historical: cutoff, candlesticks, fills, orders, trades
│   ├── kalshi_markets.jl     # Markets: list, get, trades, orderbook, candles
│   ├── kalshi_events.jl      # Events: list, multivariate, metadata, forecasts
│   ├── kalshi_orders.jl      # Orders: create, cancel, batch, amend, queue
│   ├── kalshi_order_groups.jl# Order groups: create, reset, trigger, limit
│   ├── kalshi_portfolio.jl   # Portfolio: balance, positions, settlements, fills
│   ├── kalshi_communications.jl # RFQ & quotes workflow
│   ├── kalshi_account.jl     # API keys, limits, incentives, FCM
│   ├── kalshi_search.jl      # Search: tags, filters, targets, series
│   ├── kalshi_live_data.jl   # Milestones & live data
│   └── kalshi_test.jl        # API connectivity test
├── test/
│   ├── runtests.jl           # Test suite runner
│   ├── test_txlog.jl         # Transaction log tests
│   └── test_server.jl        # Server tests
├── kalshi_server.jl          # Oxygen.jl Kalshi trading dashboard server
├── kalshi_dashboard.html     # Trading dashboard frontend
├── Project.toml
├── Manifest.toml
├── README.md
├── UNLICENSE
└── CLAUDE.md                 # This file (session context, tracked in git)
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

## Scripts for Quick Reproducibility

**Principle:** If asked to do something once, there is a high probability of having to do it again. Create scripts to avoid rethinking completed tasks.

### Kalshi API Scripts

All scripts support `--demo` (default) and `--live` flags, plus `--verbose` for debug output.
Shared auth module: `src/KalshiAuth.jl` (RSA-PSS signing, endpoint switching).

| Script | Section | Key Commands |
|--------|---------|--------------|
| `kalshi_server.jl` | Dashboard | `julia --project=. kalshi_server.jl [--port=8080] [--live] [--verbose]` |
| `scripts/kalshi_exchange.jl` | Exchange | `status`, `announcements`, `schedule` |
| `scripts/kalshi_historical.jl` | Historical | `cutoff`, `candlesticks TICKER`, `fills`, `orders`, `trades`, `markets` |
| `scripts/kalshi_markets.jl` | Markets | `list`, `get TICKER`, `trades`, `orderbook TICKER`, `orderbooks T1,T2` |
| `scripts/kalshi_events.jl` | Events | `list`, `get TICKER`, `metadata TICKER`, `candlesticks S E`, `forecast S E` |
| `scripts/kalshi_orders.jl` | Orders | `list`, `create`, `cancel ID`, `amend ID`, `batch`, `queue_positions` |
| `scripts/kalshi_order_groups.jl` | Order Groups | `list`, `create`, `delete ID`, `reset ID`, `trigger ID`, `set_limit ID` |
| `scripts/kalshi_portfolio.jl` | Portfolio | `balance`, `positions`, `settlements`, `fills`, `subaccounts_balances` |
| `scripts/kalshi_communications.jl` | RFQ/Quotes | `list_rfqs`, `create_rfq`, `list_quotes`, `accept_quote ID` |
| `scripts/kalshi_account.jl` | Account | `list_keys`, `generate_key`, `limits`, `incentives` |
| `scripts/kalshi_search.jl` | Search | `tags`, `sport_filters`, `targets`, `series TICKER` |
| `scripts/kalshi_live_data.jl` | Live Data | `milestones`, `live ID`, `batch ID1,ID2`, `game_stats ID` |
| `scripts/kalshi_test.jl` | Test | API connectivity verification |

**Kalshi API Config:**
- Demo: `https://demo-api.kalshi.co/trade-api/v2`
- Live: `https://api.elections.kalshi.com/trade-api/v2`
- Auth: RSA-PSS signing via `src/KalshiAuth.jl`
- Private key: `.secret/kalshi_api_key_private.txt`
- Key ID: Set via `KALSHI_API_KEY_ID` env var or `load_config(api_key_id="...")`

**Dashboard Server:**
- Run `julia --project=. kalshi_server.jl` to start the dashboard
- Open http://localhost:8080 in browser
- Proxies authenticated requests to Kalshi API via Oxygen.jl

**When to create a script:**
- Any task that fetches external data (prices, API calls)
- Any task that parses or evaluates portfolio positions
- Any repetitive analysis or reporting task

---

## Key Dates (Upcoming)

| Date | Event | Relevance |
|------|-------|-----------|
| Apr 30 | Q1 2026 GDP Advance | Major recession signal |
| May 6-7 | FOMC Meeting | Rate decision |
| Jun 17-18 | FOMC Meeting | Next rate decision |
| Jul 30 | Q2 2026 GDP | Two negative quarters = recession |
| Nov 3 | Midterm Elections | Political uncertainty |
| Dec 9 | Final FOMC 2026 | Last rate decision of the year |

---

## GitButler MCP Workflow Caveats

### The Problem: `gitbutler_update_branches` Doesn't Target Branches

**Root Cause:** The `gitbutler_update_branches` MCP tool has no parameter to specify which branch receives the commit. GitButler commits changes to whichever branch currently "owns" the modified files. Creating a new branch with `but branch new` doesn't automatically assign existing uncommitted changes to it.

### Correct Workflow

**Option A: Use existing active branch**
If changes are already associated with a branch, just use that branch. Don't create a new one.

**Option B: Assign files before committing**
1. `but branch new <name>`
2. Use GitButler UI to drag/assign changed files to the new branch
3. Then call `gitbutler_update_branches`

**Option C: Create branch first, then make changes**
1. `but branch new <name>` (while working directory is clean)
2. Make file changes
3. Changes will automatically associate with the new branch
4. Call `gitbutler_update_branches`

### Key Insight

GitButler's virtual branch model tracks file ownership at the hunk/change level, not at the "current branch" level like traditional git. The MCP tool commits based on which branch owns the changes, not which branch was most recently created or selected.

---

## Notes

- GitButler manages version control (don't use raw git commands for writes)
- Branch names should be short, use common abbreviations
- Grace Hopper is our hero

---

*"The cost of incorrect information... I can go up to almost half a million dollars to get that file to a higher level of correctness, because that's what I stand to lose."* — Grace Hopper, 1982

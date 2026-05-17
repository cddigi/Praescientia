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

**Stage 4 complete:** every Julia script in `scripts/kalshi_*.jl` now has a Zig
CLI equivalent under `zig-out/bin/praescientia-*`. Both produce byte-identical
JSON for the comparable subcommands (verified via `./scripts/parity_check.sh --tools`).

All tools support `--demo` (default) / `--live` / `--verbose` / `--help`.
Shared auth: Zig `src/kalshi/auth.zig` (mbedTLS RSA-PSS); Julia `src/KalshiAuth.jl` (OpenSSL libcrypto).

| Section | Zig CLI | Julia equivalent | Key subcommands |
|---------|---------|------------------|-----------------|
| Dashboard | (Stage 5) | `kalshi_server.jl` | `julia --project=. kalshi_server.jl [--port=8080] [--live]` |
| Exchange | `zig build run-exchange -- …` | `scripts/kalshi_exchange.jl` | `status`, `schedule`, `announcements` |
| Historical | `zig build run-historical -- …` | `scripts/kalshi_historical.jl` | `cutoff`, `candlesticks TICKER`, `fills`, `orders`, `trades`, `markets`, `market TICKER` |
| Markets | `zig build run-markets -- …` | `scripts/kalshi_markets.jl` | `list`, `get TICKER`, `trades`, `orderbook TICKER`, `orderbooks T1,T2`, `candlesticks S M` |
| Events | `zig build run-events -- …` | `scripts/kalshi_events.jl` | `list`, `multivariate`, `get TICKER`, `metadata TICKER`, `candlesticks S E`, `forecast S E`, `collection C` |
| Orders | `zig build run-orders -- …` | `scripts/kalshi_orders.jl` | `list`, `create`, `get`, `cancel ID`, `amend ID`, `decrease ID`, `queue_positions`, `queue_position ID` |
| Order Groups | `zig build run-order-groups -- …` | `scripts/kalshi_order_groups.jl` | `list`, `create`, `get ID`, `delete ID`, `reset ID`, `trigger ID`, `set_limit ID` |
| Portfolio | `zig build run-portfolio -- …` | `scripts/kalshi_portfolio.jl` | `balance`, `positions`, `settlements`, `fills`, `resting_value`, `subaccounts_balances`, `subaccount_transfers`, `netting`, `create_subaccount`, `transfer`, `set_netting` |
| Communications | `zig build run-communications -- …` | `scripts/kalshi_communications.jl` | `comms_id`, `list_rfqs`, `create_rfq`, `get_rfq`, `delete_rfq`, `list_quotes`, `create_quote`, `get_quote`, `delete_quote`, `accept_quote`, `confirm_quote` |
| Account | `zig build run-account -- …` | `scripts/kalshi_account.jl` | `list_keys`, `create_key`, `generate_key`, `delete_key`, `limits`, `incentives`, `fcm_orders`, `fcm_positions` |
| Search | `zig build run-search -- …` | `scripts/kalshi_search.jl` | `tags`, `sport_filters`, `targets`, `target ID`, `series TICKER` |
| Live Data | `zig build run-live-data -- …` | `scripts/kalshi_live_data.jl` | `milestones`, `milestone ID`, `live ID`, `live_legacy TYPE ID`, `batch CSV`, `game_stats ID` |
| Smoke check | `./zig-out/bin/praescientia-test-conn` | `scripts/kalshi_test.jl` | End-to-end demo API smoke check across all endpoints |
| Resolved markets poller | `zig build run-poll -- prices` | `scripts/poll_resolved_markets.jl` | `prices` (CoinGecko spot). **Full Polymarket harvester remains in Julia** |
| RSA-PSS sign (Stage 1) | `./zig-out/bin/praescientia-signtest` | — | One-shot RSA-PSS signer for cross-language interop checks |
| RSA-PSS verify | `./zig-out/bin/praescientia-verifytest` | — | Counterpart verifier |

**Zig build commands at a glance:**
- `zig build` — compile all binaries + library
- `zig build test --summary all` — 63 inline tests + `test-cli` --help smoke check (every CLI exits 0 on --help)
- `./scripts/parity_check.sh --tools` — Zig CLI ↔ Julia script JSON parity

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

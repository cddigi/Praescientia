# Praescientia — Session Context

> **Last Updated:** March 30, 2026
> **Status:** Active trading simulation — contrarian portfolio only

---

## Project Overview

**Praescientia** (Latin: foreknowledge) is a Polymarket prediction system with state rollback architecture, inspired by Grace Hopper's insights on the cost of incorrect information.

**Core Concept:** Discrete, hashed state checkpoints enable O(1) divergence identification instead of O(n) context reprocessing — narrowing the gap between human "obvious" pattern recognition and GenAI's brute-force approach.

**GitHub:** https://github.com/cddigi/Praescientia

---

## Portfolio Results Summary

### 1. Weekly Portfolio — Jan 6-12, 2026 (RESOLVED)
**File:** `portfolios/week1_jan6-12_2026.md` | **Data:** `data/january_2026_live_predictions.json`
**Budget:** $499.17 | **Status:** RESOLVED Jan 12, 2026

| Position | Market | Entry | Outcome | P&L |
|----------|--------|-------|---------|-----|
| NO | BTC hits $100k | $0.87 | WON | +$14.95 |
| NO | ETH dips to $3k | $0.84 | WON | +$15.20 |
| NO | BTC dips to $88k | $0.78 | SOLD | $0.00 |
| NO | ETH hits $3.4k (flipped) | $0.996 | WON | +$0.36 |
| NO | BTC hits $96k (flipped) | $0.996 | WON | +$0.32 |
| NO | SOL hits $150 | $0.71 | SOLD | $0.00 |

**Result:** 4/4 remaining positions WON at resolution (+$30.83). Jan 7 rebalance cost -$168.32. **Net: ~-$137**
**Lesson:** Rebalance was directionally correct but expensive. Cut losing YES positions earlier.

### 2. Daily Portfolio — Jan 9, 2026 (RESOLVED)
**File:** `portfolios/daily_jan9_2026.md`
**Budget:** $49.44 | **Status:** RESOLVED Jan 9, 2026

| Position | Market | Outcome | P&L |
|----------|--------|---------|-----|
| UP | BTC Up/Down Jan 9 | LOST (BTC DOWN) | -$14.75 |
| UP | ETH Up/Down Jan 9 | LOST (ETH DOWN) | -$15.08 |
| DOWN | SOL Up/Down Jan 9 | LOST (SOL UP) | -$14.88 |
| DOWN | SPX Up/Down Jan 9 | LOST (SPX UP +0.6%) | -$4.73 |

**Result:** 0/4. Total loss -$49.44. Mean reversion thesis failed; SPX hit new ATH.

### 3. Contrarian Portfolio — 2026 (ACTIVE)
**File:** `portfolios/contrarian_2026.md` | **Data:** `data/contrarian_2026_predictions.json`
**Budget:** $100.08 | **Status:** ACTIVE — all positions unrealized gains

| Position | Market | Entry | Current (Mar 30) | Unrealized P&L | Return |
|----------|--------|-------|-------------------|----------------|--------|
| YES | US Recession 2026 | $0.255 | $0.38 | +$29.37 | +49.0% |
| YES | Fed Rate Hike 2026 | $0.115 | $0.18 | +$11.37 | +56.5% |
| YES | Fed Emergency Cut | $0.130 | $0.19 | +$9.24 | +46.2% |

**Total Unrealized P&L: +$49.98 (+49.9% ROI)**

**Drivers:** Q4 GDP miss (1.4%), nonfarm payrolls -92k, unemployment 4.4%, US-Iran strikes, sticky CPI 2.4%, S&P 500 lowest close of 2026.

### Simulated Capital (as of March 30, 2026)
- Weekly: RESOLVED (~-$137 net)
- Daily Jan 7: +$1.46
- Daily Jan 9: -$49.44
- Contrarian: $100.08 invested, current value $150.06 (unrealized)
- **Net realized P&L: ~-$185** | **Unrealized: +$49.98** | **Combined: ~-$135**

---

## The Seneca Strategy — Vindicated

**File:** `portfolios/seneca_strategy.md`

The contrarian thesis is playing out. Every mispricing we identified in January is materializing:
- Wall Street unanimity on 2026 rally → S&P 500 hit lowest close of 2026 in March
- CAPE ratio bubble → Market under pressure from geopolitics and employment weakness
- Inflation "solved" narrative → CPI sticky at 2.4%, Fed raised inflation projections
- Soft landing consensus → Q4 GDP 1.4% (vs 2.8% expected), nonfarm -92k jobs

**Key developments since January:**
- US strikes Iran (Feb 28) — oil prices spike, geopolitical risk premium returns
- Khamenei confirmed dead (late March) — unprecedented Middle East instability
- Kevin Warsh nominated as Fed Chair (Jan 30) — monetary policy uncertainty
- BTC crashed from ~$91k to ~$68k (-25%) — risk-off sentiment spreading

---

## Trading Principles

**You can sell shares before resolution.** This is critical for risk management:

### When to Sell (Take Profits)
- Odds shift unexpectedly in your favor → possible manipulation, lock in gains
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
Unrealized P&L = (Current Odds × Shares) - Cost
```

**Red Flags for Manipulation:**
- Sudden large odds movements without news
- Unusual volume spikes
- Odds moving opposite to underlying asset direction

---

## Key Dates (Upcoming)

| Date | Event | Portfolio Impact |
|------|-------|------------------|
| Apr 30 | Q1 2026 GDP Advance | Major recession signal. If negative, recession odds spike. |
| May 6-7 | FOMC Meeting | Rate decision — watch for emergency cut signals |
| Jun 17-18 | FOMC Meeting | Next rate decision |
| Jul 30 | Q2 2026 GDP | Second quarter — two negatives = recession |
| Nov 3 | Midterm Elections | Political uncertainty |
| Dec 9 | Final FOMC 2026 | Rate hike market resolves |
| Dec 31 | Emergency Cut deadline | Fed emergency cut market resolves |
| Jan 31, 2027 | Recession resolution | US Recession 2026 market resolves |

## Key Dates (Past — Resolved)

| Date | Event | Result |
|------|-------|--------|
| Jan 9 | Daily markets resolved | 0/4 — total loss |
| Jan 12 | Weekly markets resolved | 4/4 won, but rebalance loss dominated |
| Jan 28 | FOMC Meeting | No change (held 3.50-3.75%) |
| Jan 30 | Kevin Warsh nominated | Fed Chair transition announced |
| Jan 31 | Govt shutdown | Partial shutdown began (4 days) |
| Feb 13 | DHS funding lapsed | Extended partial shutdown |
| Feb 20 | Q4 2025 GDP | 1.4% (well below 2.8% forecast) |
| Feb 28 | US strikes Iran | $529M traded on Polymarket |
| Mar 6 | Feb nonfarm payrolls | -92,000 jobs (huge miss) |
| Mar 18 | FOMC Meeting | No change (11-1 vote, Miran dissented) |
| Late Mar | Khamenei death confirmed | $45M Polymarket volume |

---

## Project Structure

```
praescientia/
├── src/
│   ├── Praescientia.jl      # Core module (state chains, predictions)
│   ├── TxLog.jl             # JSONL transaction log (blockchain-style)
│   └── PolymarketAuth.jl    # API authentication
├── data/
│   ├── october_2025_resolved.json
│   ├── november_2025_resolved.json
│   ├── december_2025_resolved.json
│   ├── january_2026_resolved.json     # NEW: Jan 2026 resolved markets
│   ├── february_2026_resolved.json    # NEW: Feb 2026 resolved markets
│   ├── march_2026_resolved.json       # NEW: Mar 2026 resolved/active markets
│   ├── january_2026_live_predictions.json  # Updated: outcomes resolved
│   └── contrarian_2026_predictions.json    # Updated: current odds + tracking
├── portfolios/
│   ├── weekly.jsonl         # RESOLVED: 4 RESOLVE txs added
│   ├── daily.jsonl          # RESOLVED: 4 RESOLVE txs added
│   ├── contrarian.jsonl     # ACTIVE: 3 ADJUST txs added (Mar 30 odds)
│   ├── archive/             # Archived logs (>1MB rotated)
│   ├── week1_jan6-12_2026.md
│   ├── daily_jan7_2026.md
│   ├── daily_jan9_2026.md
│   ├── contrarian_2026.md
│   └── seneca_strategy.md
├── scripts/
│   ├── poll_resolved_markets.jl  # NEW: Fetch resolved market data
│   ├── but-cleanup.sh       # GitButler workspace cleanup
│   └── but-delete-branch.sh # GitButler branch deletion helper
├── server.jl                # Julia HTTP server (replaces Node.js)
├── demo.jl                  # Demonstration script
├── backtest.jl              # Backtesting (oct/nov/dec 2025)
├── check_portfolios.jl      # Portfolio status checker with live odds
├── dashboard.html           # D3.js portfolio visualization (AJAX to Julia)
├── Project.toml
├── README.md
├── UNLICENSE
└── CLAUDE.md                # Session context (tracked in git)
```

---

## Backtest Results (Historical)

| Month | Accuracy | Stake | P&L | ROI |
|-------|----------|-------|-----|-----|
| October 2025 | 9/9 (100%) | $4,300 | +$790 | 18.4% |
| November 2025 | 4/6 (66.7%) | $2,000 | +$240 | 12.0% |
| December 2025 | 6/7 (85.7%) | $3,000 | +$540 | 18.0% |
| **Combined** | **19/22 (86.4%)** | **$9,300** | **+$1,570** | **16.9%** |

---

## User Context

- User has ~$500 in Schwab checking for real wagers (simulating first)
- Goal: Steady passive income from prediction markets
- Prefers high-confidence plays and Seneca-style contrarian bets
- Interested in short-term (daily) and long-term (yearly) markets

---

## Scripts for Quick Reproducibility

**Principle:** If asked to do something once, there is a high probability of having to do it again. Create scripts to avoid rethinking completed tasks.

| Script | Purpose | Usage |
|--------|---------|-------|
| `server.jl` | HTTP API server for dashboard | `julia --project=. server.jl [--port=3000]` |
| `check_portfolios.jl` | Check wager status & outcomes | `julia --project=. check_portfolios.jl [daily\|weekly\|contrarian]` |
| `scripts/poll_resolved_markets.jl` | Poll resolved market data + prices | `julia --project=. scripts/poll_resolved_markets.jl [month year\|--all]` |
| `backtest.jl` | Backtest against historical data | `julia --project=. backtest.jl [month]` |
| `demo.jl` | Demonstrate core functionality | `julia --project=. demo.jl` |
| `scripts/but-cleanup.sh` | GitButler workspace cleanup | `./scripts/but-cleanup.sh [--all]` |
| `scripts/but-delete-branch.sh` | Delete GitButler branches | `./scripts/but-delete-branch.sh <name>` |

**Dashboard Server:**
- Run `julia --project=. server.jl` to start the API server
- Open http://localhost:3000 in browser for dashboard
- AJAX calls go to Julia endpoints (no Node.js dependency)

**When to create a script:**
- Any task that fetches external data (prices, API calls)
- Any task that parses or evaluates portfolio positions
- Any repetitive analysis or reporting task
- Any GitButler/version control maintenance task

---

## Next Actions

1. **Consider taking profits on contrarian:** All 3 positions up 46-57%. Recession position approaching 50% sell threshold.
2. **Monitor Q1 2026 GDP (Apr 30):** If negative, recession odds could spike to 50%+ — potential exit point.
3. **Watch FOMC May meeting:** If language shifts hawkish, rate hike odds could jump.
4. **Run `julia --project=. scripts/poll_resolved_markets.jl --all`** periodically to keep data current.
5. **Run `julia --project=. check_portfolios.jl contrarian`** to check live contrarian odds.
6. **Consider new daily/weekly portfolios** if opportunity arises.

---

## GitButler MCP Workflow Caveats

### The Problem: `gitbutler_update_branches` Doesn't Target Branches

**Incident (Jan 7, 2026):** Created branch `dash-update` via `but branch new dash-update`, then called `gitbutler_update_branches` MCP tool. The commit landed on `cd-branch-1` instead of the new branch.

**Root Cause:** The `gitbutler_update_branches` MCP tool has no parameter to specify which branch receives the commit. GitButler commits changes to whichever branch currently "owns" the modified files. Creating a new branch with `but branch new` doesn't automatically assign existing uncommitted changes to it.

### Why Standard Fixes Don't Work

| Approach | Why It Failed |
|----------|---------------|
| **Move commit** (`but rub <commit> <target>`) | Target branch was empty; GitButler throws "anonymous segment" error when source branch becomes empty |
| **Rename branch** | GitButler CLI has no `but branch rename` command |
| **Delete empty + rename** | Still no rename; would require: create new branch → move commit → delete old branch (3+ steps with potential errors) |

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

- GitButler manages version control (don't use raw git commands)
- Polymarket APIs sometimes return stale data — use WebSearch/WebFetch on event pages
- Branch names should be short, use common abbreviations (e.g., `gb-scripts`, `pm-api`)
- Grace Hopper is our hero

---

*"The cost of incorrect information... I can go up to almost half a million dollars to get that file to a higher level of correctness, because that's what I stand to lose."* — Grace Hopper, 1982

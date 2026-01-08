# Praescientia — Session Context

> **Last Updated:** January 7, 2026
> **Status:** Active trading simulation

---

## Project Overview

**Praescientia** (Latin: foreknowledge) is a Polymarket prediction system with state rollback architecture, inspired by Grace Hopper's insights on the cost of incorrect information.

**Core Concept:** Discrete, hashed state checkpoints enable O(1) divergence identification instead of O(n) context reprocessing — narrowing the gap between human "obvious" pattern recognition and GenAI's brute-force approach.

**GitHub:** https://github.com/cddigi/Praescientia

---

## Active Portfolios (Simulated)

### 1. Weekly Portfolio — Jan 6-12, 2026
**File:** `portfolios/week1_jan6-12_2026.md`
**Budget:** $499.17
**Resolution:** January 12, 2026

| Position | Market | Entry | Cost |
|----------|--------|-------|------|
| NO | BTC hits $100k | $0.87 | $100.05 |
| NO | ETH dips to $3k | $0.84 | $79.80 |
| NO | BTC dips to $88k | $0.78 | $70.20 |
| YES | ETH hits $3,400 | $0.56 | $89.60 |
| YES | BTC hits $96k | $0.50 | $80.00 |
| NO | SOL hits $150 | $0.71 | $79.52 |

### 2. Daily Portfolio — Jan 7, 2026
**File:** `portfolios/daily_jan7_2026.md`
**Budget:** $49.59
**Resolution:** January 7, 2026 @ 5 PM ET

| Position | Market | Entry | Cost |
|----------|--------|-------|------|
| UP | BTC Up/Down Jan 7 | $0.575 | $14.95 |
| UP | ETH Up/Down Jan 7 | $0.62 | $14.88 |
| DOWN | SOL Up/Down Jan 7 | $0.38 | $9.88 |
| DOWN | SPX Up/Down Jan 7 | $0.395 | $9.88 |

### 3. Contrarian Portfolio — 2026
**File:** `portfolios/contrarian_2026.md`
**Budget:** $100.08
**Resolution:** Throughout 2026

| Position | Market | Entry | Cost |
|----------|--------|-------|------|
| YES | US Recession 2026 | $0.255 | $59.93 |
| YES | Fed Rate Hike 2026 | $0.115 | $20.13 |
| YES | Fed Emergency Cut 2026 | $0.130 | $20.02 |

**Total Simulated Capital:** $648.84

---

## The Seneca Strategy

**File:** `portfolios/seneca_strategy.md`

Core philosophy for contrarian betting:
- Bet against unanimous consensus
- Use "Grandmother Test" — if common sense sees the risk, bet on it
- Prepare for tail risks the crowd ignores (premeditatio malorum)
- Asymmetric payouts: risk $1 to make $4-10

**Current Mispricings Identified:**
- Wall Street unanimity on 2026 rally (0/21 predict decline)
- CAPE ratio at 40 (only second time ever, first was dot-com)
- Inflation "solved" narrative (1970s had 3 waves)
- Soft landing consensus despite Sahm Rule triggering

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

## Key Dates

| Date | Event | Portfolio Impact |
|------|-------|------------------|
| **Jan 7, 5 PM ET** | Daily markets resolve | Check daily_jan7 results |
| **Jan 12** | Weekly markets resolve | Check week1 results |
| Jan 28-29 | FOMC Meeting | Fed decision |
| Jan 30 | Q4 2025 GDP | Recession signal |
| Jan 31 | Gov't funding deadline | Shutdown risk |
| Feb 12 | January CPI | Inflation signal |

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
│   ├── january_2026_live_predictions.json
│   └── contrarian_2026_predictions.json
├── portfolios/
│   ├── *.jsonl              # Active transaction logs (per portfolio)
│   ├── archive/             # Archived logs (>1MB rotated)
│   ├── week1_jan6-12_2026.md
│   ├── daily_jan7_2026.md
│   ├── contrarian_2026.md
│   └── seneca_strategy.md
├── scripts/
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

1. **Jan 7 evening:** Run `julia --project=. check_portfolios.jl` to check daily results
2. **Jan 12:** Run portfolio check for weekly results
3. **Ongoing:** Monitor contrarian positions for entry/exit opportunities
4. **If profitable:** Consider transitioning from simulation to real wagers

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

# Autonomous Prediction Agent — Design

> A long-running Claude Code session — Opus as overlord, Haiku as workers — polls Kalshi each tick, fans out one sub-agent per thesis, and turns each sub-agent's structured decision into chain writes and demo-API orders. The sub-agents decide; the orchestrator persists. Every tick is idempotent and rollback-anchored. Losses trigger mandatory post-mortems written back into the knowledge base; wins are recorded silently.

## Context

The KB substrate, commentary chain, and `/api/kb/commentary/similar` retrieval surface all exist. Prediction recording exists as a human-driven CLI (`praescientia-kb predict`). What's missing is the autonomous loop that turns observed reality into recorded belief and placed orders. The Hopper principle says the cost of incorrect information is what we minimize — that requires recording beliefs at every tick so divergences are discoverable in O(1), not reconstructed forensically.

The orchestrator is not a separate daemon. It is a Claude Code session held open by `ScheduleWakeup`, with the tick body expressed as a slash command. Inter-tick state lives entirely on disk under `kb/.ticks/`; the session itself memorizes nothing across ticks, so kill-and-resume is safe by construction.

## Goals

- **Autonomy on demo, end to end.** Each tick: poll, snapshot, settle, fan out to thesis sub-agents, validate, write predictions + commentary, place orders. No human in the inner loop.
- **Sub-agents decide; orchestrator persists.** Sub-agents never write chain entries or place orders directly. Their only product is constrained JSON. The orchestrator validates, clamps, and executes. Bad output is rejected, never trusted.
- **Every tick is idempotent and rollback-anchored.** A `tick_id` ULID, pre/post chain-head snapshots in `kb/.ticks/`, and deterministic `client_order_id`s on Kalshi make replay safe and rollback addressable.
- **Losses compound the knowledge base; wins do not.** Asymmetric resolution handling: wins log one event line, losses dispatch a post-mortem sub-agent whose output lands in the commentary chain so future ticks encounter it via similarity search.

## Decision summary

| Area | Choice |
|---|---|
| Orchestrator | Claude Code session, `/praescientia-orchestrate` skill, self-rescheduled via `ScheduleWakeup` |
| Orchestrator model | Opus (cross-tick reasoning, audit-quality summaries) |
| Sub-agent model | Haiku by default; promotable to Sonnet/Opus per-tick via env var |
| Unit of analysis | Per-thesis (not per-market) — confidence lives at thesis level |
| Sub-agent contract | Constrained JSON: `confidence_bp`, `rationale`, `commentary_body`, `commentary_tags`, `orders[]` |
| Order authority | Sub-agents propose; orchestrator validates, clamps, executes |
| Idempotency key | `client_order_id = "tick-{tick_id}-{thesis}-{ticker}-{side}-{action}"` |
| Tick state | Files under `kb/.ticks/{tick_id}.{pre,post,events,rejected}.json` |
| Concurrency safety | `flock(2)` advisory lock on `kb/.ticks/.lock` |
| Resolution handling | Wins → events log only; losses → mandatory post-mortem sub-agent + commentary write |
| Kill switches | `kb/.ticks/KILL` (abort), `kb/.ticks/PAUSED` (analyze but skip execute), daily order-count breaker |
| Default tick interval | 5 minutes |

---

## §1. Roles and process hierarchy

Three tiers, in strict order on each tick.

**Orchestrator** — the long-running Claude Code session. Owns the tick clock. On each tick: generates `tick_id`, snapshots chain heads, calls `praescientia-poll-markets`, settles, fans out, collects, validates, persists, snapshots heads again, writes a global commentary entry summarizing the tick, schedules the next tick. The orchestrator never trusts sub-agent output without validation and never bypasses CLIs to write the chain or place orders — it composes the same CLIs an operator would use.

**Per-thesis sub-agent** — one `Agent` invocation per thesis, in parallel within a single fan-out tool block. Inputs are pre-loaded by the orchestrator from chain state. The sub-agent's only product is a structured JSON decision. It has read tools (`Bash` for state-fetch CLIs, `Read` for chain JSONL) but no write tools, so even a malicious or hallucinating sub-agent cannot corrupt the chain or send orders directly.

**Orchestrator-side executor** — runs after fan-out completes. Walks each validated decision in serial: writes commentary, writes prediction, executes order intents. Serialization eliminates race conditions when two sub-agents touch overlapping markets (they shouldn't via manifest hygiene, but the orchestrator enforces it regardless).

The split — sub-agents decide, orchestrator persists — is the system's safety wedge and its rollback wedge. Every artifact a tick produces carries the same `tick_id`, so reversal is a chain operation, not a forensic excavation.

## §2. Sub-agent contract

**Input** (orchestrator builds from disk + similarity API):

- `thesis_id`, full manifest (`description`, `weights`, `rollup_fn`, `confidence_delta_bp`, optional `bankroll_cap_bp`)
- `reality_head`: latest `aggregate_yes_cents`, `ts`
- `prediction_history`: last 5 entries with `confidence_bp` and `ts` — belief-drift trace
- Per constituent market: `yes_bid_cents`, `yes_ask_cents`, `last_trade_cents`, `volume`, our current position, our open orders
- `commentary_neighbors`: top-8 from `/api/kb/commentary/similar` anchored on the thesis's latest commentary head, bodies inlined
- `bankroll`: demo account balance, per-thesis cap in cents
- `tick_id`: the ULID, echoed back in output for audit correlation

**Output** (constrained JSON, schema-validated by orchestrator):

```json
{
  "tick_id": "01KRZ...",
  "confidence_bp": 1800,
  "rationale": "≤500 chars — becomes predict --rationale",
  "commentary_body": "free-form analysis, ≤4 KB — becomes a commentary entry",
  "commentary_tags": ["..."],
  "orders": [
    {
      "ticker": "KXNBASPREAD-26MAY20SASOKC-SAS4",
      "side": "yes",
      "action": "buy",
      "size": 5,
      "limit_cents": 22,
      "reason": "≤200 chars"
    }
  ]
}
```

**Tools available to the sub-agent** (enforced via agent frontmatter):

- `Bash` — for `praescientia-markets get`, `praescientia-historical candlesticks`, `praescientia-portfolio positions`, `praescientia-kb commentary show <hash>`
- `Read` — kb chain files only
- No `Write`, `Edit`, `Agent`, `WebFetch`

## §3. Tick lifecycle and idempotency

Each tick is a single state transition with a deterministic ID. Replay never duplicates work.

1. **Generate `tick_id`** — ULID, monotonic, becomes the audit anchor.
2. **Acquire lock** — `flock(2)` on `kb/.ticks/.lock`. Second concurrent orchestrator on the same kb_root blocks and exits with a clear error.
3. **Snapshot pre-state** — write `kb/.ticks/{tick_id}.pre.json` listing the active head hash of every reality / prediction / commentary chain.
4. **Poll reality** — `praescientia-poll-markets --kb-root=./kb --demo`. Idempotent on its own.
5. **Settle and reflect** (see §8) — process new resolutions; wins log, losses dispatch post-mortem sub-agents.
6. **Build prompts** — for each thesis, assemble Section 2 inputs.
7. **Fan out** — `Agent` calls in a single tool block. 60s timeout, 3 retries with exponential backoff on transient failure.
8. **Collect and validate** — schema-check, range-check `confidence_bp ∈ [0, 10000]`, whitelist-check `orders[].ticker ∈ thesis.weights.keys()`, cap-check sizes against per-thesis bankroll. Rejected payloads land in `kb/.ticks/{tick_id}.rejected.json` with reasons.
9. **Execute writes** (serialized per thesis, in this order):
   - `praescientia-kb commentary write --thesis=<id> --body=<commentary_body> --tags=<commentary_tags>`
   - `praescientia-kb predict <id> --confidence-bp=<confidence_bp> --rationale=<rationale>`
   - For each `orders[]` entry: translate to `praescientia-orders create|cancel|amend` with the deterministic `client_order_id`
10. **Snapshot post-state** → `kb/.ticks/{tick_id}.post.json`.
11. **Global tick summary** — orchestrator writes one commentary entry to `commentary/global/` tagged `tick-summary` with the `tick_id`, theses processed, orders placed and rejected counts, settlements observed.
12. **Release lock**, **schedule next tick** via `ScheduleWakeup`.

**Replay safety.** If step 9 crashes halfway, the next session detects `pre.json` without `post.json` and resumes the same `tick_id`. Predictions already written are identified by hash and skipped. Orders reuse the same `client_order_id` — Kalshi rejects duplicates server-side.

## §4. Sub-agent runtime

Agent definition at `.claude/agents/praescientia-thesis-analyst.md`.

**System prompt** (baked into agent frontmatter):

- Role: "You analyze a single Kalshi prediction-market thesis and emit a structured decision."
- Constraints: respond with **exactly one JSON object** matching the §2 schema; no prose outside it; cap `commentary_body` at 4 KB; cap `rationale` at 500 chars; never call write tools (you do not have them).
- Decision framework: explicit weighting of (a) chain-recorded prior beliefs vs current market mid, (b) commentary-neighbor signals — especially `post-mortem` tagged entries, (c) per-market liquidity sanity (reject orders against markets with `volume == 0` and `spread > 50¢`).

**User prompt**: orchestrator-built §2 inputs as labeled JSON blocks. No prose framing — fewer surprises than free-text.

**Model selection:**

- Default: `claude-haiku-4-5-20251001`
- Escalation: env var `PRAESCIENTIA_THESIS_MODEL=sonnet|opus` overrides per-tick. The orchestrator escalates when `|confidence_bp - reality_bp| > thesis.confidence_delta_bp * 2` on the prior tick — the thesis is in a high-volatility regime that warrants a stronger model.

**Runtime guards:**

- Per-call timeout: 60s
- Retry budget: 3 attempts with exponential backoff (1s, 4s, 16s)
- Output cap: 8 KB; larger responses are structurally suspect and rejected without parsing
- Persistent failure: thesis is skipped and logged to `kb/.ticks/{tick_id}.rejected.json`

**Parallelism:** all theses dispatch in a single tool-block. With 10-20 theses and Haiku latency ~3-8s per call, fan-out completes in well under a minute.

## §5. Trigger mechanism and orchestrator session

The orchestrator is a Claude Code session, not a separate process. The user launches it manually; the session keeps itself alive via `ScheduleWakeup`.

**Launch:**

```fish
claude
# inside:
/praescientia-orchestrate --interval=300s --max-ticks=unbounded
```

The skill lives at `.claude/skills/praescientia-orchestrate/SKILL.md`. On invocation:

1. Read prior tick state from `kb/.ticks/`. Highest `tick_id` with a `pre.json` but no `post.json` → resume that tick; otherwise start a new one.
2. Execute §3 lifecycle.
3. After step 11, call `ScheduleWakeup` with `delaySeconds=<interval>` and the same `/praescientia-orchestrate --interval=...` prompt so the next firing repeats the task with identical config.

**Inter-tick state lives entirely on disk.** The Opus session does not memorize anything between ticks; every re-entry reads disk state. Kill the session any time, start a new one, it resumes mid-tick if needed. No warm-start drift.

**Operator control:**

- `Ctrl-C` in the session → orchestrator stops scheduling; current in-flight tick still completes
- `/praescientia-orchestrate --pause` → write `kb/.ticks/PAUSED` sentinel; subsequent ticks skip step 9 (execute) but still poll + analyze + log
- `/praescientia-orchestrate --resume` → delete sentinel
- File `kb/.ticks/KILL` → next tick aborts entirely on entry, no analysis, no writes
- `--theses=foo,bar` → partial fanout for debugging; only the named theses dispatch sub-agents this tick

## §6. Safety rails for the demo run

Even on demo, fixed harness so a hallucinating sub-agent cannot grind through the demo balance or hammer the API.

**Per-tick caps:**

- Max theses processed per tick: 50
- Max order operations per tick (create + cancel + amend combined): 25
- Max **new** open orders per tick: 10
- Tick wall-clock budget: 80% of the interval; if execution exceeds, defer remaining writes to next tick and log

**Per-thesis bankroll caps:**

- Default: 5% of demo balance, configurable in thesis manifest as `bankroll_cap_bp`
- Orchestrator clamps oversize orders down to fit and records the clamp reason; the clamped order still executes

**Per-market caps:**

- Max open orders per (market, side): 1 — if a sub-agent emits `create` against a market with an open order on the same side, orchestrator translates to `amend` (or `cancel + create` if new `limit_cents` differs from resting by more than 5% of the resting price)
- Max contracts per market position: 100 (configurable)

**Sub-agent output validation** — rejection → log → skip, never crash the tick:

- `confidence_bp ∈ [0, 10000]`
- `orders[].ticker ∈ thesis.weights.keys()`
- `orders[].side ∈ {yes, no}`, `action ∈ {buy, sell, cancel, amend}`
- `orders[].limit_cents ∈ [1, 99]`
- `orders[].size > 0` and `≤ per_market_cap`

**Kill switches**, checked at every step boundary:

- `kb/.ticks/KILL` → tick aborts, no writes, orchestrator stops scheduling
- `kb/.ticks/PAUSED` → analyze + log, skip execute
- Daily order-count breaker: `kb/.ticks/.daily_orders.json` — cumulative orders today ≥ 500 → auto-pause

**Audit.** Every clamp, rejection, kill, pause is one line in `kb/.ticks/{tick_id}.events.jsonl`. The global tick-summary commentary references this file by hash.

## §7. Deliverables and file layout

```
.claude/
  agents/
    praescientia-thesis-analyst.md           NEW — §4 sub-agent
    praescientia-loss-reflector.md           NEW — §8 post-mortem agent
  skills/
    praescientia-orchestrate/
      SKILL.md                               NEW — §5 tick procedure
      tick.md                                NEW — embedded lifecycle checklist
docs/plans/
  2026-05-19-autonomous-prediction-agent-design.md             (this file)
  2026-05-19-autonomous-prediction-agent-implementation.md     companion plan
src/kb/
  ticks.zig                                  NEW — snapshotHeads, validateOrderIntent,
                                                  ClampReason, OrderIntent schema
tools/
  ticks.zig                                  NEW — praescientia-ticks CLI
                                                  (snapshot | begin | finish |
                                                   validate | status | rollback)
scripts/
  orchestrator_smoke.sh                      NEW — synthetic-tick end-to-end smoke
```

**Why a `tools/ticks.zig` binary** instead of pure shell glue in the orchestrator skill: snapshotting chain heads, validating sub-agent output schemas, computing the post-tick global commentary body — all benefit from being typed, tested, and deterministic. The orchestrator calls `praescientia-ticks` for those, same pattern as `praescientia-kb` and `praescientia-poll-markets`. Claude Code's job stays high-level: dispatch sub-agents, run CLIs, write summaries.

## §8. Resolution handling — silent wins, mandatory loss reflection

The asymmetry is doctrine, not just code. Wins teach little (the prediction was correct, the system worked). Losses are the highest-signal moments the chain ever sees, because they reveal *why* a belief was wrong. A loss without a recorded lesson is information thrown away — the exact failure mode Hopper's principle warns against.

**Slot in the tick lifecycle**, between §3 step 4 (poll reality) and step 6 (build prompts) — step 5:

1. `praescientia-portfolio settlements --since-cursor=kb/.ticks/.last_settlement`
2. For each settled position, classify as **win** or **loss** by comparing held side to `market_resolution.yes`.
3. **Wins** — append one line to `kb/.ticks/{tick_id}.events.jsonl` (`win`, ticker, contracts, realized P&L). No chain writes. No commentary. Cursor advances.
4. **Losses** — dispatch a `praescientia-loss-reflector` sub-agent per loss.

**Loss-reflector contract** at `.claude/agents/praescientia-loss-reflector.md`:

- **Inputs:** full prediction chain history for the responsible thesis, related commentary neighbors (top-8) via the similarity API, the market's reality chain (every tick of price movement we observed), the eventual resolution.
- **Output** (constrained JSON):

```json
{
  "what_we_believed":              "≤200 chars",
  "what_actually_happened":        "≤200 chars",
  "why_we_were_wrong":             "≤500 chars — the actual lesson",
  "decision_pattern_to_avoid":     "≤200 chars",
  "tags":                          ["..."]
}
```

- The orchestrator writes this as a commentary entry under **both**:
  - `theses/<id>/commentary/` — so the responsible thesis encounters this lesson on every future tick via similarity search
  - `markets/<TICKER>/commentary/` — so ticker-specific lessons survive even if the thesis is retired

Tagged `post-mortem`, `loss`, plus the sub-agent's emitted tags. The cursor advances only after the commentary is durably written. A failed reflection retries on the next tick.

**The compounding effect.** Because loss commentary lives in the scope the thesis-analyst pulls neighbors from, every loss becomes a permanent priors-adjustment that future predictions cannot avoid encountering. The system gets smarter at exactly the moments it has the most to learn.

---

## Non-goals / out of scope for v1

- **Live-API order placement.** The agent only places orders on demo. Live requires the §6 caps revisited, an out-of-band human approval flow, and a separate compliance/accounting story.
- **Market discovery.** Markets are admitted manually via `praescientia-kb add-market`. The agent does not search Kalshi for new markets to follow.
- **Thesis evolution.** Theses are defined manually via `praescientia-kb add-thesis`. The agent does not propose new theses or retire stale ones. (A natural Stage 2.)
- **Order-fill backfill.** Order-fill chains exist on the Kalshi side; the agent does not yet mirror fills into kb_root reality chains beyond `aggregate_yes_cents` updates from `poll-markets`.
- **Cross-thesis arbitrage.** Sub-agents see only their own thesis. Cross-thesis pattern recognition happens only through commentary similarity — there is no explicit hand-off.

## Open questions, deferred

- **Bankroll allocation when many theses compete for the same demo balance.** Current rule is a flat 5% per thesis with no inter-thesis arbitration. A future tick could pre-allocate from a portfolio-level budget.
- **Settlement cursor placement** when a market resolves between polls but before the next tick fires. Today the cursor advances at most once per tick; large lag windows might lose ordering. Probably fine until proven otherwise.
- **What stops the orchestrator session from drifting** after weeks of continuous runtime? Token-budget pressure on the Opus context. Mitigation: ScheduleWakeup re-entries are short (read disk → execute tick → schedule next), so per-tick context is bounded. Multi-week runs may still warrant a forced restart cadence.

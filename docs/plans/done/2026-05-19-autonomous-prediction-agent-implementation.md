# Autonomous Prediction Agent Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Ship the orchestrator-and-sub-agent stack described in `docs/plans/done/2026-05-19-autonomous-prediction-agent-design.md`. Each tick: poll, settle, fan out to per-thesis Haiku sub-agents under an Opus orchestrator session, validate, persist, place demo orders, snapshot. Losses trigger post-mortem sub-agents whose output flows back into commentary.

**Architecture:** New Zig module `src/kb/ticks.zig` (tick primitives, validation, clamps). New `tools/ticks.zig` CLI (`praescientia-ticks snapshot|begin|finish|validate|status|rollback`). Two new Claude Code sub-agents at `.claude/agents/`. One new slash-command skill at `.claude/skills/praescientia-orchestrate/`. End-to-end smoke at `scripts/orchestrator_smoke.sh` using a mock sub-agent.

**Tech Stack:** Zig 0.16.0 (existing). Python 3.11+ (existing indexer venv, no new deps). Claude Code agent + skill definitions (markdown frontmatter). GitButler MCP for all commits.

---

## Conventions

### Zig 0.16 reminders (carried from prior plans)

- `Dir.createDir` takes a `Permissions` enum — use `.default_dir`, not `.{}`.
- `Dir.createDirPath` is the recursive variant.
- `chain.openRead` / `openForWrite` are 4-arg: `(allocator, io, dir, branch)`.
- `std.array_list.Managed(u8).writer()` does not compose with `*std.Io.Writer`; use `std.Io.Writer.Allocating` and pass `aw.written()` as bytes.
- For enum cardinality, use `@typeInfo(E).@"enum".fields.len`.
- Module-level `StringHashMapUnmanaged` must be reset to `.empty` at the start of every test that touches it; `deinit` leaves it `undefined`.

### Test command

`zig build test --summary all`. Start-of-plan baseline is whatever the merge-of-PR-46 tip reports (≈ 175/175 + the serve-mode fix). Python tests run via `cd tools/indexer && uv run pytest -q` and are not part of `zig build test`.

### TDD cycle per Zig task

1. Write the failing test.
2. Run; expect compile error or runtime fail.
3. Implement minimal code.
4. Re-run; expect green.
5. Commit via GitButler.

### Commit via GitButler — never `git commit`

```
Call mcp__gitbutler__gitbutler_update_branches with:
  fullPrompt:             <copy of the task title>
  changesSummary:         <2-4 bullets: what changed and why>
  currentWorkingDirectory: /Users/lawls/Development/TuesdayCrowd/Praescientia
```

After the first commit on a fresh branch, **run `but branch new <name> && but mark <name>` in one Bash call** so the post-tool hook can't spawn a parallel `cd-branch-N` stub.

### Editing rules

- Inline Zig tests only; reuse `std.testing.allocator`.
- Canonical-JSON payloads have alphabetically-sorted keys; no floats in hashed fields.
- Claude Code agent definitions use the standard frontmatter at `.claude/agents/<name>.md`:
  ```
  ---
  name: <kebab-name>
  description: <one-line; ranked against task by Skill discovery>
  model: <haiku|sonnet|opus|inherit>
  tools: Bash, Read
  ---
  ```
- Skills use `.claude/skills/<slug>/SKILL.md` with the same frontmatter shape; sub-files (e.g. `tick.md`) are referenced from `SKILL.md`.
- Shell scripts under `scripts/` are bash, `set -euo pipefail`, with exit-code conventions matching `scripts/commentary_smoke.sh`.

---

## Stage 1 — Tick primitives in Zig

**Deliverable:** `src/kb/ticks.zig` exports `Tick`, `SnapshotEntry`, `OrderIntent`, `ClampReason`, `snapshotHeads()`, `validateOrderIntent()`, `clientOrderId()`. All payloads use canonical JSON. Inline tests cover happy paths and the five rejection cases.

### Task 1.1 — `Tick` ULID + filesystem layout

**Files:**
- Create: `src/kb/ticks.zig`
- Modify: `src/root.zig` (add `pub const ticks = @import("kb/ticks.zig");` + `_ = kb.ticks;` in root test block)

**Step 1: Failing test** in `src/kb/ticks.zig`:

```zig
test "Tick.init generates a monotonic ULID and computes filesystem paths" {
    var buf: [128]u8 = undefined;
    const t = try Tick.init(std.crypto.random);
    const pre = try t.path(&buf, "./kb", .pre);
    try std.testing.expect(std.mem.endsWith(u8, pre, ".pre.json"));
    try std.testing.expect(std.mem.indexOf(u8, pre, t.id) != null);
}
```

**Step 2: Implement** `Tick { id: [26]u8 }`, `Tick.init(rng)` ULID, `Tick.path(buf, kb_root, kind: enum { pre, post, events, rejected })`.

### Task 1.2 — `SnapshotEntry` schema + `snapshotHeads(allocator, io, kb_root) ![]SnapshotEntry`

Walks `kb/markets/*/reality/`, `kb/markets/*/commentary/`, `kb/theses/*/reality/`, `kb/theses/*/prediction/`, `kb/theses/*/commentary/`, `kb/commentary/global/`. For each: read the active branch head from `branches.json` and emit `{ scope_path, branch, head_hash, length }`.

**Failing test:** init a tmp `kb/` with two markets and a thesis, write a commentary entry, call `snapshotHeads`, assert the entries match disk state and have alphabetical `scope_path` ordering.

### Task 1.3 — `OrderIntent` schema + `validateOrderIntent(intent, thesis_manifest, position_state) !void`

`OrderIntent { ticker, side: enum {yes, no}, action: enum {buy, sell, cancel, amend}, size: u32, limit_cents: u8, reason: []const u8 }`.

`validateOrderIntent` enforces §6 rules and returns `ValidationError` with a tagged reason: `TickerNotInManifest`, `SizeOverPerMarketCap`, `LimitOutOfRange`, `SizeNonPositive`, `BankrollCapExceeded`.

**Failing test:** one happy-path + one for each rejection reason. Use `std.testing.expectError`.

### Task 1.4 — `clientOrderId(tick_id, thesis, ticker, side, action) ![]u8`

Deterministic string: `"tick-{tick_id}-{thesis}-{ticker}-{side}-{action}"`. Cap length at 64 bytes (Kalshi's `client_order_id` limit); error if any input forces overrun.

**Failing test:** standard case + length-overrun case.

### Task 1.5 — `ClampReason` enum + `clampOrderSize(intent, bankroll_cents, balance_cents) struct { size: u32, reason: ?ClampReason }`

Returns the clamped size and the reason (`null` if unchanged). Reasons: `BankrollCap`, `PerMarketCap`, `InsufficientBalance`.

**Failing test:** order at cap, order over cap, order over balance, order under everything.

---

## Stage 2 — `praescientia-ticks` CLI

**Deliverable:** `tools/ticks.zig` binary with subcommands `snapshot`, `begin`, `finish`, `validate`, `status`, `rollback`. The orchestrator skill calls these instead of doing serialization in shell.

### Task 2.1 — Wire the binary into `build.zig` and `tools/common.zig` dispatch

Mirror `tools/poll_markets.zig`. Single-subcommand binaries auto-default to their only subcommand (the `common.zig` machinery already supports this).

### Task 2.2 — `snapshot <kb_root> <out_path>` subcommand

Calls `kb.ticks.snapshotHeads`, writes the array as canonical JSON to `out_path`. Used for both `pre` and `post` snapshots.

**Test:** `tests/orchestrator_smoke.sh` calls this on a synthetic kb and asserts the JSON parses + has the expected scope paths.

### Task 2.3 — `begin --kb-root=PATH` subcommand

Generates a `tick_id`, takes `flock(2)` on `kb/.ticks/.lock`, snapshots pre-state, writes `kb/.ticks/{tick_id}.pre.json`, prints `tick_id` to stdout. Holds the lock until the process exits — the orchestrator keeps it alive across the tick by leaving the binary running in a long-lived sub-process, or by passing `--lock-fd` to subsequent calls. (Decision recorded in the skill: orchestrator uses `flock(1)` in bash for the duration of the tick, calling `praescientia-ticks` subcommands within the locked region.)

**Failing test:** two concurrent invocations against the same kb_root; second should error with `LockHeld`.

### Task 2.4 — `finish --kb-root=PATH --tick-id=ID` subcommand

Snapshots post-state to `kb/.ticks/{tick_id}.post.json`. No-ops idempotently if the post-snapshot already exists with the same content.

### Task 2.5 — `validate --tick-id=ID --thesis-manifest=PATH --decision=PATH` subcommand

Reads a sub-agent's JSON decision from `--decision=PATH`, applies the §2 schema check + `validateOrderIntent` per order, prints either `OK` (exit 0) or a structured rejection JSON to stderr (exit 1). Used by the orchestrator between fan-out and execute.

**Test:** golden-file pair `tests/fixtures/decisions/{ok,bad_ticker,bad_size}.json` and assert exit codes.

### Task 2.6 — `status --kb-root=PATH` subcommand

Prints recent ticks (last 10) with summary line: `tick_id`, started_at, finished_at-or-IN-PROGRESS, theses_processed, orders_placed, rejected_count. Reads `*.pre.json` / `*.post.json` / `*.events.jsonl`.

### Task 2.7 — `rollback --tick-id=ID --kb-root=PATH` subcommand (best-effort)

For each chain in the tick's `pre.json`, fork the chain at the pre-tick head_hash into a new branch named `pre-{tick_id}`. **Does not delete entries.** Operator switches the active branch via `praescientia-kb` if they want to roll back; this subcommand only prepares the rollback anchor.

**Test:** synthetic two-tick scenario; rollback after tick 2; assert the forked branches exist and point at tick 1's heads.

---

## Stage 3 — Thesis-analyst sub-agent

**Deliverable:** `.claude/agents/praescientia-thesis-analyst.md` with frontmatter + system prompt covering §2 contract and §4 decision framework.

### Task 3.1 — Agent definition

**File:** `.claude/agents/praescientia-thesis-analyst.md`

**Frontmatter:**

```yaml
---
name: praescientia-thesis-analyst
description: Analyzes a single Kalshi prediction-market thesis and returns a structured JSON decision (confidence_bp, rationale, commentary_body, orders[]). Read-only; the orchestrator persists. Default Haiku.
model: haiku
tools: Bash, Read
---
```

**Body** covers (in this order):

1. **Role + scope** — exactly one thesis per invocation; never writes chain entries or places orders.
2. **Input shape** — the §2 input structure the orchestrator builds.
3. **Output schema** — verbatim JSON, with example.
4. **Decision framework** — weighting of (a) prior beliefs vs current mid, (b) commentary neighbors (especially `post-mortem` tagged), (c) liquidity sanity.
5. **Hard refusal cases** — reject any request to write to the chain, place orders directly, or call write tools. Respond with a rejection JSON: `{"error": "...", "tick_id": "..."}`.
6. **Constraint reminders** — JSON-only output, no prose framing, body ≤ 4 KB, rationale ≤ 500 chars.

### Task 3.2 — Hand-validated dry run

Manual: from a fresh Claude Code session with the agent loaded, invoke it with a canned input matching one of our existing theses. Assert (by eye) the output JSON is well-formed and the rationale references the input's commentary neighbors meaningfully. Document the dry-run output as a fixture at `tests/fixtures/agent_outputs/thesis_dry_run.json`.

---

## Stage 4 — Loss-reflector sub-agent

**Deliverable:** `.claude/agents/praescientia-loss-reflector.md` — post-mortem agent dispatched on each loss observed during the tick's settle step.

### Task 4.1 — Agent definition

**File:** `.claude/agents/praescientia-loss-reflector.md`

**Frontmatter:** same shape as thesis-analyst, with `description` matching §8's purpose.

**Body** covers:

1. **Role + scope** — one resolved-and-lost market per invocation. Inputs include the full prediction chain for the responsible thesis, the market's reality chain, similarity-search neighbors, and the resolution outcome.
2. **Output schema** — the §8 four-field JSON (`what_we_believed`, `what_actually_happened`, `why_we_were_wrong`, `decision_pattern_to_avoid`, `tags`).
3. **Stylistic norm** — `why_we_were_wrong` must be specific and actionable; "the market moved against us" is rejected by the orchestrator's content check. "We over-weighted the SAS+1.5 quote because we mistook liquidity-cap pricing for a probability signal" is good.
4. **Refusal case** — same as thesis-analyst.

### Task 4.2 — Orchestrator-side content check for `why_we_were_wrong`

The orchestrator rejects post-mortems whose `why_we_were_wrong` matches a stoplist of generic phrases. List lives in `src/kb/ticks.zig` as `loss_reflection_stoplist` and is enforced in a new `validateLossReflection()` helper.

**Failing test:** stoplist phrase → rejection; specific phrase → accepted.

### Task 4.3 — Dry-run fixture

Use a synthetic prior-loss scenario; record the agent's output at `tests/fixtures/agent_outputs/loss_dry_run.json`.

---

## Stage 5 — Orchestrate skill

**Deliverable:** `.claude/skills/praescientia-orchestrate/SKILL.md` + `tick.md` checklist. Owns the §3 lifecycle, the §5 trigger loop, and the §6 kill-switch checks.

### Task 5.1 — `SKILL.md` frontmatter + top-level dispatch

**File:** `.claude/skills/praescientia-orchestrate/SKILL.md`

```yaml
---
name: praescientia-orchestrate
description: Drive one tick (or many) of the autonomous prediction agent. Polls Kalshi, fans out per-thesis Haiku sub-agents under Opus orchestration, validates, persists, places demo orders, snapshots. Re-enters via ScheduleWakeup for the next tick.
model: opus
---
```

Body: short description, then sections for each CLI flag (`--interval=`, `--max-ticks=`, `--theses=`, `--pause`, `--resume`, `--dry-run`), then "**See `tick.md` for the full per-tick checklist.**"

### Task 5.2 — `tick.md` lifecycle checklist

The detailed §3 lifecycle as a numbered checklist. Each step references the exact CLI to run and the success/failure handling. Pasted in canonical form so an operator can debug a tick by reading down the file.

### Task 5.3 — Kill-switch and pause logic

Pre-step-1 check on every tick:
- `kb/.ticks/KILL` exists → abort, no scheduling
- `kb/.ticks/PAUSED` exists → skip step 9 (execute), but run steps 1-8 + 10-12 normally

Documented in `tick.md`; no code change beyond what step 0 already does.

### Task 5.4 — Daily breaker

Maintain `kb/.ticks/.daily_orders.json` — `{"date": "YYYY-MM-DD", "count": N}`. Before step 9, increment by planned operation count; if total ≥ 500, write `PAUSED` and abort the execute phase. Reset at midnight UTC.

### Task 5.5 — ScheduleWakeup self-reentry

After step 11, the skill calls `ScheduleWakeup(delaySeconds=interval, prompt=same /praescientia-orchestrate ... args)`. The skill body documents the exact prompt template so re-entries are stable.

---

## Stage 6 — Orchestrator smoke script

**Deliverable:** `scripts/orchestrator_smoke.sh` exercises the full lifecycle without a real Anthropic API call, using a mock sub-agent (a bash script that returns canned JSON).

### Task 6.1 — Mock sub-agent fixture

Create `tests/fixtures/mock_thesis_analyst.sh`. Reads a `tick_id` and `thesis_id` from argv, writes a fixed valid decision JSON to stdout. Used as a stand-in for `Agent` calls during smoke.

### Task 6.2 — Smoke harness

`scripts/orchestrator_smoke.sh`:

```bash
# Setup: temp kb_root with one market + one thesis + one commentary entry
# Step 1: begin tick → assert tick_id printed, .pre.json exists
# Step 2: run mock sub-agent against thesis → write decision JSON
# Step 3: praescientia-ticks validate → exit 0
# Step 4: praescientia-kb commentary write + predict + (dry-run) order create
# Step 5: praescientia-ticks finish → .post.json exists
# Step 6: assert tick events.jsonl has expected lines
# Step 7: praescientia-ticks status → most-recent tick is the one we just ran
# Step 8: praescientia-ticks rollback → pre-{tick_id} branches exist
```

Cleanup in `trap`. Exit codes match `scripts/commentary_smoke.sh` conventions (0 = pass, 1 = step failed, 2 = prereq missing).

### Task 6.3 — CI hook

Add `scripts/orchestrator_smoke.sh` to whatever currently runs the demo-loop smoke (manual today; document in README).

---

## Stage 7 — Demo-API integration polish

**Deliverable:** thread the orchestrator's `--demo` / `--live` flag through every CLI call it makes, and add a `--dry-run` path that skips real order execution.

### Task 7.1 — `--dry-run` mode in the skill

When `--dry-run` is set: all `praescientia-orders create|cancel|amend` calls are logged to `kb/.ticks/{tick_id}.events.jsonl` as `dry_run_order` events but never executed. Predictions and commentary still write normally.

### Task 7.2 — End-to-end demo tick with real `Agent` calls

Manual: launch a Claude Code session against `./kb`, invoke `/praescientia-orchestrate --interval=600s --max-ticks=1 --dry-run`. Verify:

- A tick_id is produced
- Both real theses (sas-okc-spread-ladder, cross-category-pick) receive sub-agent dispatch
- Both return valid decision JSON
- Predictions + commentary write to the chains
- Dry-run order events are logged

Document the run in a one-paragraph followup in `docs/plans/done/` once the plan retires.

### Task 7.3 — Live order execution dry-run lift

Re-run Task 7.2 without `--dry-run`. Verify orders appear in `praescientia-portfolio positions` against the demo API. Document expected balance + position deltas.

---

## Stage 8 — Resolution handling

**Deliverable:** the §8 settle-and-reflect step wired into the tick lifecycle.

### Task 8.1 — Settlement cursor file format

`kb/.ticks/.last_settlement.json`: `{"cursor": "<kalshi-cursor-string>", "as_of_ts": <unix-ms>}`. Read at step 5, written after settlements are processed.

### Task 8.2 — Settlement classification helper

`src/kb/ticks.zig` adds `classifyResolution(settlement, held_side) enum { Win, Loss }`. Inline test covers both branches plus the no-position-held edge case (skip silently).

### Task 8.3 — Loss-reflector dispatch in the tick lifecycle

Update `tick.md` to spell out: for each loss, build the loss-reflector input prompt (full prediction history, similarity neighbors, market reality chain, resolution), invoke the agent, validate response (`validateLossReflection`), write commentary entries to both `theses/<id>/commentary/` and `markets/<TICKER>/commentary/`, advance the cursor only after both writes succeed.

### Task 8.4 — Win-path event log

Wins write one line to `kb/.ticks/{tick_id}.events.jsonl`: `{"kind":"win","ticker":"...","contracts":N,"realized_pnl_cents":M,"ts":...}`. No chain writes. Cursor advances unconditionally.

### Task 8.5 — Idempotency on settlement processing

If the loss-reflector fails or the commentary write fails, the cursor does **not** advance for that settlement, and the next tick re-attempts. Settled-and-already-reflected entries are detected by checking the thesis commentary chain for an entry whose `references` include the resolution hash; those skip silently.

**Test in `tests/orchestrator_smoke.sh`:** synthetic settlement → mock loss-reflector → assert two commentary entries written → re-run → assert no duplicates.

---

## Stage 9 — Documentation + CLAUDE.md updates

**Deliverable:** README + CLAUDE.md know about the new surface so a fresh session can pick it up.

### Task 9.1 — README section

New `## Autonomous prediction agent` section in `README.md` covering: how to launch (`/praescientia-orchestrate`), the kill-switch files, how to pause/resume, where ticks land on disk, how to inspect a tick.

### Task 9.2 — CLAUDE.md project structure tree

Add the new files (agents, skill, `src/kb/ticks.zig`, `tools/ticks.zig`, `scripts/orchestrator_smoke.sh`) to the project-structure ASCII tree at the top of `CLAUDE.md`.

### Task 9.3 — CLAUDE.md surface table

Add rows to the surface table at the bottom of the build/run section:
- `/praescientia-orchestrate` skill
- `praescientia-ticks` CLI

### Task 9.4 — Move retired plans

After this plan is complete, move both `docs/plans/2026-05-19-autonomous-prediction-agent-{design,implementation}.md` into `docs/plans/done/` and update any backlinks.

---

## Open items resolved during implementation (none yet)

This section gets filled in as the plan executes — anything the design left open that needed pinning down lands here.

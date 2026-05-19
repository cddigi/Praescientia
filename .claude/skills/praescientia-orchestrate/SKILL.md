---
name: praescientia-orchestrate
description: "Drive one tick (or many) of the autonomous prediction agent. Polls Kalshi, fans out per-thesis Haiku sub-agents under Opus orchestration, validates, persists, places demo orders, snapshots. Re-enters via ScheduleWakeup for the next tick. Use when the user asks to start, drive, pause, or resume the autonomous prediction loop."
model: opus
---

# praescientia-orchestrate

The Opus-overlord skill that runs one tick (or schedules many) of the
autonomous prediction agent against the Kalshi demo API. Per tick:
acquire the kb-root lock, snapshot chain heads, poll markets, settle
resolutions (dispatch loss-reflector sub-agents on losses), fan out one
`praescientia-thesis-analyst` Haiku sub-agent per thesis, validate
their JSON, persist commentary + predictions, place demo orders, and
snapshot heads again. Then re-enter via `ScheduleWakeup` for the next
tick.

**See [`tick.md`](./tick.md) for the full per-tick checklist.** That
file is the canonical reference for what happens between steps 1–12 of
a single tick. The body of `SKILL.md` below covers argument dispatch,
resume logic, and inter-tick scheduling. The two files are read
together: `SKILL.md` says *when* to run a tick; `tick.md` says *how*.

---

## Hard rules — read before doing anything

1. **Never trust sub-agent output.** Every JSON reply gets parsed
   through the prose-stripping wrapper in `tick.md §step-8`, then
   validated by `praescientia-ticks validate` before any write. The
   sub-agents emit prose prefixes and code fences in practice; the
   parser must handle this. Both the thesis-analyst and loss-reflector
   dry runs violated their no-prose-before-JSON protocol — assume this
   is the norm, not the exception. See
   `tests/fixtures/agent_outputs/{thesis,loss_reflector}_dry_run.json`
   for the failure modes.
2. **Never write to the chain directly.** Always go through
   `praescientia-kb commentary write` / `praescientia-kb predict`. The
   orchestrator composes the same CLIs an operator would use.
3. **Never place orders without the deterministic `client_order_id`.**
   `tools/ticks.zig::clientOrderId()` produces it; Kalshi rejects
   duplicates server-side, which is our idempotency floor.
4. **Never bypass the kill switches.** The pre-step-0 check (see
   `tick.md`) reads `kb/.ticks/KILL` and `kb/.ticks/PAUSED` on every
   entry. If `KILL` exists, abort without scheduling. If `PAUSED`
   exists, run steps 1–8 + 10–12 but skip the execute phase (step 9).

---

## Arguments

Parse the user's invocation as `/praescientia-orchestrate <flags>`. Flags:

### `--kb-root=PATH` (default `./kb`)

Root of the knowledge-base. All `praescientia-*` CLI calls receive
this flag verbatim. Resolve relative to the working directory at first
invocation; subsequent re-entries via `ScheduleWakeup` pass the
already-resolved absolute path so cwd drift cannot break the loop.

### `--interval=DURATION` (default `300s`)

Wall-clock interval between tick starts. Accepted forms: `60s`,
`5m`, `1h`. Converted to integer seconds for `ScheduleWakeup`. The
runtime clamps to `[60, 3600]`; pick an interval inside that window or
the wake-up will be retargeted.

### `--max-ticks=N` (default `unbounded`)

Bounded-run mode. After completing the Nth tick, do **not** call
`ScheduleWakeup`. Used for smoke tests (`--max-ticks=1`) and for
debugging a small batch. The orchestrator decrements a counter file at
`kb/.ticks/.ticks_remaining` between ticks; if the file exists, the
value is `max(0, current - 1)`. When the file reaches 0 the loop
terminates after the current tick's step 12.

### `--theses=foo,bar` (default = all theses in the manifest)

Partial fan-out. Only the named theses are dispatched this tick;
others are silently skipped. Useful for debugging a single
underperforming thesis without disrupting the rest.

### `--pause`

Write `kb/.ticks/PAUSED` and exit. Subsequent ticks (whether driven by
`ScheduleWakeup` or a fresh `/praescientia-orchestrate` invocation) will
analyze + log but skip step 9 (execute). Used to freeze new orders
without losing the belief signal.

### `--resume`

Delete `kb/.ticks/PAUSED` and exit. Inverse of `--pause`.

### `--dry-run`

Step 9 still runs, but every `praescientia-orders create|cancel|amend`
invocation is replaced by appending a `{"kind":"dry_run_order",...}`
line to `kb/.ticks/{tick_id}.events.jsonl`. Predictions and commentary
still write normally. The flag is documented in `tick.md §step-9`.

### `--once`

Equivalent to `--max-ticks=1`. Convenience for smoke tests.

---

## Lifecycle gates

Before doing anything, in this order:

1. **Parse arguments.** Refuse unknown flags with a one-line error and
   exit; do not partially apply.
2. **Pause / resume short-circuits.** If `--pause` or `--resume` is
   set, perform the sentinel mutation and exit. No tick runs, no
   scheduling.
3. **Bounded-run check.** If `--max-ticks` is set, read
   `kb/.ticks/.ticks_remaining` (creating it with the supplied N on
   first invocation). If the value is 0, exit without running a tick.
4. **Kill switch.** If `kb/.ticks/KILL` exists, log
   `{"kind":"abort_kill_switch","ts":<unix-ms>}` to
   `kb/.ticks/.global_events.jsonl` and exit. Do not call
   `ScheduleWakeup`.
5. **Resume vs new tick.** Scan `kb/.ticks/*.pre.json`. If any
   `tick_id` has a `pre.json` but no `post.json`, that's an
   interrupted tick — resume it (use that `tick_id` for the rest of
   this run). Otherwise start a new tick.
6. **Hand off to the per-tick checklist** (`tick.md`).

---

## Resume semantics

A tick is durably identified by its `pre.json` file. Once that file
exists, the `tick_id` is committed and must be reused on resume — never
generate a fresh ULID for an interrupted tick.

Steps that have already produced a permanent artifact are detected
on-disk and skipped on resume:

- **Step 3 (pre snapshot)** — `pre.json` already exists; reuse it.
- **Step 9 commentary write** — scan the thesis commentary chain for
  the most-recent entry tagged `tick:{tick_id}`; skip if present.
- **Step 9 prediction write** — scan the thesis prediction chain for
  the most-recent entry whose rationale starts with `[tick:{tick_id}]`;
  skip if present.
- **Step 9 order placement** — Kalshi rejects duplicate
  `client_order_id`; treat the rejection as success.
- **Step 11 global tick summary** — scan `commentary/global/` for a
  `tick-summary` entry referencing this `tick_id`; skip if present.

If `post.json` already exists, the tick is fully complete — log
`{"kind":"resume_no_op","tick_id":"..."}` and proceed to the
scheduling step.

---

## ScheduleWakeup re-entry

After `tick.md` step 12 completes successfully (lock released,
post-snapshot written), the skill calls `ScheduleWakeup` with:

- `delaySeconds`: parsed `--interval` in integer seconds, clamped to
  `[60, 3600]` (the runtime enforces this anyway).
- `prompt`: the **exact same** invocation that triggered this run,
  with one substitution: if `--max-ticks=N` is set and N > 1, replace
  with `--max-ticks=<N-1>`. If N == 1, do not call `ScheduleWakeup`
  (terminal tick).
- `reason`: `"praescientia tick {tick_id} complete; next in {interval}s"`.

The prompt template (preserve flag order):

```
/praescientia-orchestrate --kb-root=<abs path> --interval=<duration> [--theses=...] [--dry-run] [--max-ticks=<N-1>]
```

The Opus session memorizes nothing across the wakeup boundary — every
re-entry re-reads disk state. This is by design (long-runtime drift
mitigation). Do not optimize the wakeup by passing state through the
prompt; the disk is the source of truth.

### When NOT to schedule the next tick

- `KILL` sentinel appeared during the tick (re-check at step 12).
- `--max-ticks` counter reached 0.
- `tick.md` returned a non-zero exit (the tick failed; the next
  invocation will pick up the interrupted state via the resume path).
- The `praescientia-ticks finish` call at step 10 failed (post-snapshot
  did not write; the tick is partial and re-running will recover).

---

## Operator workflow

```fish
# launch (typical)
claude
> /praescientia-orchestrate --kb-root=./kb --interval=300s

# bounded smoke
> /praescientia-orchestrate --kb-root=./kb --interval=60s --max-ticks=3 --dry-run

# pause new orders, keep analyzing
> /praescientia-orchestrate --pause

# resume after a fix
> /praescientia-orchestrate --resume

# emergency stop (file-only, no session needed)
touch kb/.ticks/KILL
```

---

## Debugging a tick by reading down `tick.md`

If a tick is misbehaving:

1. Run `praescientia-ticks status --kb-root=./kb` to find the
   `tick_id`.
2. Open `kb/.ticks/{tick_id}.events.jsonl` and read top-to-bottom; the
   step numbers in event payloads correspond to the numbered steps in
   `tick.md`.
3. Open `tick.md` to the step that failed — every step lists the exact
   CLI invocation, the expected success state, and the documented
   failure handling.
4. If the failure is in a sub-agent response, the rejected payload is
   at `kb/.ticks/{tick_id}.rejected.json` with the validator's reason
   field.

The skill's contract is that `tick.md` reads as a checklist an
operator can run by hand if the skill itself is unavailable. Keep it
that way.

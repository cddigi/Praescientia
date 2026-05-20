# Per-tick lifecycle checklist

> Canonical operator-readable checklist for one tick of
> `/praescientia-orchestrate`. Each numbered step lists: **CLI**,
> **success state**, **failure handling**. Steps 1–12 follow the §3
> lifecycle from `docs/plans/done/2026-05-19-autonomous-prediction-agent-design.md`.
> The pre-step section runs before step 1; the post-step section runs
> after step 12.
>
> If the skill harness is unavailable, an operator can execute this
> file by hand — every command is concrete and the failure paths are
> spelled out. The pre-loaded `${vars}` are explicit: `${KB}`,
> `${TICK_ID}`, `${INTERVAL}`, etc.

---

## Pre-step 0 — gates and sentinels

Run on every tick entry, **before** step 1.

### 0.a KILL sentinel

```bash
if [[ -f "${KB}/.ticks/KILL" ]]; then
  echo '{"kind":"abort_kill_switch","ts":'$(date +%s%3N)'}' \
    >> "${KB}/.ticks/.global_events.jsonl"
  exit 0  # do NOT schedule next tick
fi
```

**Success**: file absent. Continue.
**Failure**: file present. Abort silently — the operator placed it there
deliberately. No `ScheduleWakeup`.

### 0.b PAUSED sentinel

```bash
PAUSED=0
[[ -f "${KB}/.ticks/PAUSED" ]] && PAUSED=1
```

**Success (PAUSED=0)**: normal run. Step 9 executes.
**Success (PAUSED=1)**: degraded run. Step 9 is **skipped** entirely;
steps 1–8 + 10–12 still run so the belief signal and reality chain
keep advancing.

### 0.c Daily-order breaker

```bash
TODAY="$(date -u +%Y-%m-%d)"
BREAKER="${KB}/.ticks/.daily_orders.json"
if [[ -f "${BREAKER}" ]]; then
  read DATE COUNT < <(python3 -c "import json,sys; d=json.load(open('${BREAKER}')); print(d.get('date',''), d.get('count',0))")
  if [[ "${DATE}" != "${TODAY}" ]]; then
    # midnight UTC rollover
    echo "{\"date\":\"${TODAY}\",\"count\":0}" > "${BREAKER}"
    COUNT=0
  fi
else
  echo "{\"date\":\"${TODAY}\",\"count\":0}" > "${BREAKER}"
  COUNT=0
fi
if (( COUNT >= 500 )); then
  touch "${KB}/.ticks/PAUSED"
  PAUSED=1
  echo '{"kind":"auto_pause_daily_breaker","count":'${COUNT}',"ts":'$(date +%s%3N)'}' \
    >> "${KB}/.ticks/.global_events.jsonl"
fi
```

**Success**: `COUNT < 500`. Continue.
**Auto-pause**: `COUNT >= 500`. The breaker writes the `PAUSED`
sentinel itself; subsequent ticks degrade until midnight UTC rolls the
counter. An operator can manually `rm kb/.ticks/PAUSED` to override,
but the breaker will re-engage on the next tick if count stays high.

### 0.d Resume detection

```bash
RESUME_TICK=""
for f in "${KB}"/.ticks/*.pre.json; do
  [[ -e "$f" ]] || continue
  tid=$(basename "$f" .pre.json)
  if [[ ! -f "${KB}/.ticks/${tid}.post.json" ]]; then
    RESUME_TICK="${tid}"
    break  # only one interrupted tick should exist; first wins
  fi
done
```

**Success (RESUME_TICK empty)**: start a new tick at step 1.
**Resume path (RESUME_TICK set)**: skip step 1 (no new ULID); reuse
`RESUME_TICK` as `${TICK_ID}` and skip every sub-step whose artifact
already exists (see `SKILL.md § Resume semantics`).

---

## Step 1 — generate `tick_id` (or reuse on resume)

### CLI

```bash
if [[ -z "${RESUME_TICK}" ]]; then
  TICK_ID="$(praescientia-ticks begin --kb-root="${KB}")"
else
  TICK_ID="${RESUME_TICK}"
fi
```

`praescientia-ticks begin` does three things atomically:

1. Generates a fresh ULID.
2. Acquires `flock(2)` on `${KB}/.ticks/.lock` (blocking; second
   orchestrator on the same kb_root will queue).
3. Writes `${KB}/.ticks/${TICK_ID}.pre.json` with the canonical
   snapshot of every active chain head.

The lock is held by the `begin` process until step 12. Subsequent CLI
calls within this tick run **outside** the locked process — they don't
need the lock because only one orchestrator owns the kb_root at a
time (enforced by the lock on `begin`).

### Success

`${TICK_ID}` is a 26-char ULID, `pre.json` exists, lock held.

### Failure

- **`LockHeld`**: another orchestrator has the lock. The current
  invocation waits via `flock`. If the wait exceeds the tick interval,
  abort and let the next wakeup retry.
- **Disk error writing `pre.json`**: `begin` returns non-zero. Abort
  the tick — do not call `ScheduleWakeup` from this run, since the
  next invocation will see no `pre.json` and start fresh.

### Event log

```bash
echo '{"kind":"tick_begin","step":1,"tick_id":"'"${TICK_ID}"'","ts":'$(date +%s%3N)'}' \
  >> "${KB}/.ticks/${TICK_ID}.events.jsonl"
```

---

## Step 2 — lock acquired

(Folded into step 1.) No-op as a separate step in code; preserved as a
numbered slot so the design doc's §3 numbering matches this checklist
1:1.

---

## Step 3 — pre-state snapshot

(Folded into step 1.) `pre.json` is written by `begin`. On resume, the
file already exists; do not re-snapshot — the pre-state is whatever
the chain heads were **at the start of the interrupted tick**, not
right now.

---

## Step 4 — poll reality

### CLI

```bash
praescientia-poll-markets --kb-root="${KB}" --demo \
  || POLL_EXIT=$?
```

Idempotent on its own — polls Kalshi and appends new market reality
entries. Safe to re-run on resume.

### Success

Exit 0. New reality entries appended to `${KB}/markets/*/reality/`
chains (or none, if Kalshi reported no changes since last poll).

### Failure

- **Network error**: log
  `{"kind":"poll_failure","step":4,"exit":"${POLL_EXIT}",...}` to the
  events file and **continue to step 5** — the tick can still produce
  belief signal from stale market data. Sub-agents will see whatever
  reality is on disk.
- **Auth error (RSA-PSS signing)**: same logging, but additionally
  write `${KB}/.ticks/KILL` so subsequent ticks abort until a human
  re-checks `.secret/`. This is a hard failure; do not proceed.

---

## Step 5 — settle and reflect

The §8 asymmetry lives here: wins log one line, losses dispatch a
post-mortem sub-agent whose output writes commentary into **two**
scopes (the responsible thesis + the resolved market). A failed
reflection leaves the cursor unchanged so the next tick retries.

### 5.a Fetch new settlements

```bash
praescientia-portfolio settlements --demo \
  --since-cursor-file="${KB}/.ticks/.last_settlement.json" \
  > "/tmp/settlements_${TICK_ID}.json"
```

Output shape (the `--since-cursor-file` flag switches to the orchestrator
format — one entry per non-zero held side, voided markets skipped):

```json
{
  "next_cursor": "<kalshi-cursor-string>",
  "settlements": [
    {
      "ticker": "...",
      "resolved_yes": true,
      "resolution_ts_ms": 1779200100000,
      "our_held_side": "yes",
      "our_contracts": 5,
      "realized_pnl_cents": 350
    }
  ]
}
```

The cursor file shape (read at step 5.a, written at the end of step 5):

```json
{"cursor": "<kalshi-cursor-string>", "as_of_ts_ms": 1779300000000}
```

If the file is missing (first-ever tick) or unparseable, the CLI starts
with an empty cursor — Kalshi returns the latest settlements page. If
the CLI exits non-zero (HTTP error, auth missing, etc.), log
`{"kind":"step_5_fetch_failed","exit":<code>,"ts":...}` and proceed to
step 6. Pure transform helpers are available for testing without
network I/O — see `tests/fixtures/settlements/*.json` and
`src/kb/settlements.zig`.

### 5.b Classify each settlement

For each `settlement` JSON object in the fetched array, write it to a
temp file and call:

```bash
VERDICT=$(praescientia-ticks classify-resolution \
  --settlement="/tmp/settlement_${TICK_ID}_${IDX}.json")
```

The CLI prints `win` or `loss` on stdout. It rejects with exit 1 if
the held side isn't `"yes"` or `"no"` (treat as a data error and skip
that settlement).

**Skip silently** if `our_contracts == 0` — we had no position; the
classifier output is meaningless. The orchestrator filters these
before invoking the CLI.

### 5.c Win path (asymmetric — log only)

```bash
echo "{\"kind\":\"win\",\"ticker\":\"${TICKER}\",\"contracts\":${N},\"realized_pnl_cents\":${PNL},\"ts\":$(date +%s%3N)}" \
  >> "${KB}/.ticks/${TICK_ID}.events.jsonl"
```

No chain writes. Cursor advances unconditionally for wins.

### 5.d Loss path — mandatory reflection

For each loss, build the loss-reflector input prompt by assembling
(from chain reads):

- `tick_id`, `thesis` manifest, `market_resolution` (the settlement
  shape from 5.b)
- `prediction_history` — full thesis prediction chain
- `market_reality_chain` — every reality entry on the resolved ticker
- `commentary_neighbors` — top-8 from similarity search anchored on
  the thesis's latest commentary head

Write the assembled input to `/tmp/loss_input_${TICK_ID}_${TICKER}.json`,
then dispatch:

```
Agent({
  subagent_type: "praescientia-loss-reflector",
  prompt: <contents of /tmp/loss_input_${TICK_ID}_${TICKER}.json>,
  description: "post-mortem for ${TICKER}",
  model: "opus"  // see step 7 note on the Agent-tool model parameter
})
```

Parse the response through the **same** prose-stripping pipeline as
step 8.a (greedy outer-`{}` extractor). Validate via:

```bash
praescientia-ticks validate-loss-reflection \
  --decision="/tmp/loss_out_${TICKER}.json"
```

Exit 0 = accepted. Exit 1 = a JSON `{"ok":false,"reason":"..."}`
envelope on stderr. Rejection reasons map directly to
`LossReflectionError` variants in `src/kb/ticks.zig`:
`EmptyField`, `WhatWeBelievedTooLong`, `WhatActuallyHappenedTooLong`,
`WhyWeWereWrongTooLong`, `DecisionPatternTooLong`, `GenericPhrase`.

On rejection: log `{"kind":"loss_reflection_rejected","ticker":"...","reason":"...","ts":...}`
and **do not advance the cursor**. The settlement queues for the next
tick.

### 5.e Idempotency — skip already-reflected settlements

Before dispatching the loss-reflector, check whether a commentary
entry already exists in the responsible thesis's chain whose
`references` list contains the resolution hash:

```bash
RESOLUTION_HASH=$(jq -r '.resolution_hash' "/tmp/settlement_${TICK_ID}_${IDX}.json")
ALREADY=$(praescientia-kb commentary list \
  --thesis="${THESIS_ID}" \
  --kb-root="${KB}" \
  --references-include="${RESOLUTION_HASH}" 2>/dev/null | wc -l)
if [ "${ALREADY}" -gt 0 ]; then
  echo "{\"kind\":\"loss_reflection_skipped\",\"reason\":\"already_reflected\",\"ts\":$(date +%s%3N)}" \
    >> "${KB}/.ticks/${TICK_ID}.events.jsonl"
  continue
fi
```

(The `--references-include` filter is a Stage 9 follow-up if not yet
wired. Until then, the cursor advancement after a successful write
provides the dedup floor — re-running a settlement that already
advanced the cursor is a no-op.)

### 5.f Write commentary into both scopes

On accepted reflection, write to **both** the responsible thesis and
the resolved market. Failure to write either rolls back: the cursor
stays put and the next tick retries.

```bash
jq -r '.why_we_were_wrong + "\n\n" + .decision_pattern_to_avoid' \
  "/tmp/loss_out_${TICKER}.json" > "/tmp/loss_commentary_${TICKER}.md"

TAGS_FROM_AGENT="$(jq -r '.tags | join(",")' "/tmp/loss_out_${TICKER}.json")"
FULL_TAGS="post-mortem,loss,${TAGS_FROM_AGENT},tick:${TICK_ID}"

praescientia-kb commentary write \
  --kb-root="${KB}" \
  --thesis="${THESIS_ID}" \
  --agent-model=loss-reflector \
  --body-file="/tmp/loss_commentary_${TICKER}.md" \
  --tags="${FULL_TAGS}" || {
    echo "{\"kind\":\"loss_commentary_write_failed\",\"scope\":\"thesis\",\"ts\":...}" \
      >> "${KB}/.ticks/${TICK_ID}.events.jsonl"
    continue
}

praescientia-kb commentary write \
  --kb-root="${KB}" \
  --market="${TICKER}" \
  --agent-model=loss-reflector \
  --body-file="/tmp/loss_commentary_${TICKER}.md" \
  --tags="${FULL_TAGS}" || {
    echo "{\"kind\":\"loss_commentary_write_failed\",\"scope\":\"market\",\"ts\":...}" \
      >> "${KB}/.ticks/${TICK_ID}.events.jsonl"
    continue
}
```

The orchestrator stamps `post-mortem` and `loss` tags automatically;
the agent contributes the specific failure-mode tags.

### 5.g Advance cursor

Only after **every** settlement in the batch has been classified and —
for losses — successfully reflected and written to both scopes:

```bash
NEW_CURSOR=$(jq -r '.next_cursor' "/tmp/settlements_${TICK_ID}.json")
echo "{\"cursor\":\"${NEW_CURSOR}\",\"as_of_ts_ms\":$(date +%s%3N)}" \
  > "${KB}/.ticks/.last_settlement.json"
```

Partial-batch failure leaves the cursor at the prior value so the
unfinished settlements re-enter the pipeline on the next tick. The
classifier and validator are pure; re-running is cheap.

---

## Step 6 — build per-thesis prompts

For each thesis in `${KB}/theses/` (or filtered by `--theses=...`):

```bash
praescientia-ticks build-thesis-input \
  --kb-root="${KB}" \
  --thesis="${THESIS_ID}" \
  --tick-id="${TICK_ID}" \
  > "/tmp/thesis_input_${TICK_ID}_${THESIS_ID}.json"
```

The subcommand (Stage 7 follow-up; for now the orchestrator assembles
the JSON inline via `praescientia-kb` + `praescientia-markets get` +
similarity-API calls) produces the §2 input shape:

- `tick_id`
- `thesis` (manifest)
- `reality_head`
- `prediction_history` (last 5)
- `markets` (one entry per market in `market_set`)
- `commentary_neighbors` (top-8 from `/api/kb/commentary/similar`)
- `bankroll` (`account_balance_cents`, `thesis_cap_cents`, `used_cents`)

### Success

One input JSON file per thesis. Each parses as a single JSON object.

### Failure

- **Missing manifest**: log
  `{"kind":"thesis_skipped","thesis":"...","reason":"manifest_missing"}`
  and omit from the fan-out array. Other theses proceed normally.
- **Similarity API down**: log
  `{"kind":"thesis_skipped","thesis":"...","reason":"similarity_api_down"}`
  and omit. The agent rejects empty / <2 neighbor inputs (see § 6.b),
  so dispatching without neighbors is wasted effort.

### 6.b Pre-dispatch precondition — `commentary_neighbors.length >= 2`

**Before** adding a thesis to the fan-out array, verify the input
includes at least 2 commentary neighbors. The agent prompt enforces
this on the other end (treats <2 neighbors as malformed input, emits
error envelope), but the orchestrator checks upfront so the dispatch
isn't wasted.

```bash
NEIGHBORS=$(jq '.commentary_neighbors | length' "/tmp/thesis_input_${TICK_ID}_${THESIS_ID}.json")
if (( NEIGHBORS < 2 )); then
  echo "{\"kind\":\"thesis_skipped\",\"thesis\":\"${THESIS_ID}\",\"reason\":\"step_7_research_required\",\"neighbors\":${NEIGHBORS},\"required\":2,\"ts\":$(now_ms)}" \
    >> "${KB}/.ticks/${TICK_ID}.events.jsonl"
  # Operator instruction: seed at least 2 commentary entries on
  # theses/${THESIS_ID}/commentary/ before the next tick.
  continue
fi
```

**Why this is hard-required.** The agent's analysis block has a
mandatory `commentary_review` field (≤300 chars) that must cite at
least one neighbor by hash. Empty `commentary_neighbors` makes
populating that field impossible — the agent has nothing to cite.
More fundamentally, the system's value compounds through commentary
similarity search: a thesis with no prior research is a thesis we
haven't thought about yet, and capital shouldn't flow into something
we haven't thought about. (See § decision: research-first capital
allocation.)

**Operator workflow on first thesis registration:**

```bash
praescientia-kb add-market <TICKER> --kb-root=./kb
praescientia-kb add-thesis <ID> --description='...' --weights='{...}' --kb-root=./kb

# Seed at least 2 commentary entries with actual research:
praescientia-kb commentary write --thesis=<ID> --agent-model=human \
  --body="Thesis framing: <why we think this market is mispriced>" \
  --tags=thesis-framing --kb-root=./kb
praescientia-kb commentary write --thesis=<ID> --agent-model=human \
  --body="Domain notes: <base rate, ladder analysis, recent events>" \
  --tags=domain-notes --kb-root=./kb

# Index so similarity search returns them:
python tools/indexer/index_commentary.py --kb-root=./kb --once
```

Only after that 4-command setup is the thesis ready for dispatch.

---

## Step 7 — fan out

Launch one `praescientia-thesis-analyst` sub-agent per thesis input,
**all in a single tool block** for genuine parallelism.

```
for each /tmp/thesis_input_${TICK_ID}_*.json:
  Agent({
    subagent_type: "praescientia-thesis-analyst",
    prompt: <file contents — the full JSON>,
    description: "thesis analysis for <thesis_id>",
    model: "opus",                // see model-selection note below
    run_in_background: false      // synchronous return needed for step 8
  })
```

### Model selection — pass `model: "opus"` explicitly

Both sub-agents have `model: inherit` in their frontmatter, which means
"use whatever model the parent session is running on." That works at
session start but **the agent definition is cached** — frontmatter
changes made mid-session do not take effect until the next session
restart.

The Agent tool's `model:` parameter takes precedence over the cached
frontmatter on every call. Pass `"opus"` (or `"sonnet"` for cost
control, or `"inherit"` to use the parent session's model) on every
dispatch. This is also the orchestrator's lever for per-tick
escalation when a thesis is in a high-volatility regime.

**Why this matters in practice.** Haiku reliably refuses to analyze
zero-quote / cold-data inputs (see
`feedback_haiku_no_signal_hard_floor` in memory). Three rounds of
prompt-engineering didn't break that floor. Opus handles the same
inputs correctly — six-clause rationale, proper §6 liquidity-gate
citation, no error envelope. The reliability gain is large; the cost
delta is bounded (~20k tokens vs ~15k per dispatch, ~3-9s vs ~2s).

The same advice applies to the loss-reflector dispatch in §5.d.

### Success

Every Agent call returns within 60s. Capture each raw response string
for step 8.

### Success

Every Agent call returns within 60s. Capture each raw response string
for step 8.

### Failure

- **Timeout (>60s)**: agent definition's runtime cap. Retry budget 3
  with exponential backoff (1s, 4s, 16s). After 3 failures, treat as
  rejected: write the failure reason to
  `${KB}/.ticks/${TICK_ID}.rejected.json` (one entry per failed
  thesis) and continue. Other theses' outputs proceed normally.
- **Persistent network errors**: log
  `{"kind":"fan_out_failure","step":7,...}` and continue with whatever
  responses did return.

---

## Step 8 — collect, prose-strip, and validate

This is the most failure-prone step in the entire lifecycle. Both
sub-agents (thesis-analyst and loss-reflector) emit prose prefixes and
code fences in practice — see
`tests/fixtures/agent_outputs/{thesis,loss_reflector}_dry_run.json` for
recorded examples.

### 8.a Prose / fence stripping

For each raw response:

```bash
python3 - <<'PY' > "/tmp/decision_${THESIS_ID}.json"
import sys, re, json
raw = sys.stdin.read()
# Greedy match — outermost {...}, including embedded newlines
m = re.search(r'\{.*\}', raw, re.DOTALL)
if not m:
    print(json.dumps({"error":"no_json_object_found","raw_first_200":raw[:200]}))
    sys.exit(0)
candidate = m.group(0)
try:
    parsed = json.loads(candidate)
    print(json.dumps(parsed))
except json.JSONDecodeError as e:
    print(json.dumps({"error":"json_parse_failed","detail":str(e),"candidate_first_200":candidate[:200]}))
PY
```

**Why greedy `\{.*\}`**: agents emit one outer JSON object (per the
schema) and may emit nested objects (e.g. `commentary_neighbors`
references). The outermost braces are the boundary; everything inside
is the agent's product. A non-greedy `\{.*?\}` would catch the first
nested object and miss the rest.

### 8.b Schema + range validation

```bash
praescientia-ticks validate \
  --tick-id="${TICK_ID}" \
  --thesis-manifest="${KB}/theses/${THESIS_ID}/thesis.manifest" \
  --decision="/tmp/decision_${THESIS_ID}.json" \
  || VALIDATE_EXIT=$?
```

### Success

Exit 0, valid decision JSON on disk.

### Failure

- **`error` key in stripped JSON** (no JSON object found, or parse
  failed): append to `${KB}/.ticks/${TICK_ID}.rejected.json`:
  ```json
  {"thesis":"...","reason":"json_extraction_failed","raw_first_200":"..."}
  ```
  Skip this thesis for step 9. Other theses continue.
- **Validate exit 1**: structured rejection JSON on stderr. Append to
  `rejected.json`. Skip this thesis for step 9.
- **`tick_id` mismatch**: validate catches this. Same handling.

---

## Step 9 — execute writes (skip if PAUSED)

```bash
if (( PAUSED == 1 )); then
  echo '{"kind":"step_9_skipped_paused","step":9,"ts":'$(date +%s%3N)'}' \
    >> "${KB}/.ticks/${TICK_ID}.events.jsonl"
  # jump to step 10
fi
```

For each thesis with a valid decision (from step 8):

### 9.a Commentary

```bash
if [[ "$(jq -r '.commentary_body // "null"' /tmp/decision_${THESIS_ID}.json)" != "null" ]]; then
  jq -r '.commentary_body' /tmp/decision_${THESIS_ID}.json > /tmp/commentary_${THESIS_ID}.md
  TAGS="$(jq -r '.commentary_tags | join(",")' /tmp/decision_${THESIS_ID}.json),tick:${TICK_ID}"
  praescientia-kb commentary write \
    --kb-root="${KB}" \
    --scope="theses/${THESIS_ID}/commentary" \
    --body-file="/tmp/commentary_${THESIS_ID}.md" \
    --tags="${TAGS}"
fi
```

On resume: check if a `tick:${TICK_ID}`-tagged entry already exists in
the thesis commentary; skip if so.

### 9.b Prediction

```bash
CONF="$(jq -r '.confidence_bp' /tmp/decision_${THESIS_ID}.json)"
RAT="[tick:${TICK_ID}] $(jq -r '.rationale' /tmp/decision_${THESIS_ID}.json)"
praescientia-kb predict "${THESIS_ID}" \
  --kb-root="${KB}" \
  --confidence-bp="${CONF}" \
  --rationale="${RAT}"
```

On resume: scan prediction chain for the most-recent entry whose
rationale starts with `[tick:${TICK_ID}]`; skip if found.

### 9.c Orders (or dry-run events if `--dry-run`)

For each order in `decision.orders`:

```bash
TICKER="$(echo "${ORDER}" | jq -r '.ticker')"
SIDE="$(echo "${ORDER}" | jq -r '.side')"
ACTION="$(echo "${ORDER}" | jq -r '.action')"
SIZE="$(echo "${ORDER}" | jq -r '.size')"
LIMIT="$(echo "${ORDER}" | jq -r '.limit_cents')"

# Deterministic client_order_id — see src/kb/ticks.zig::clientOrderId
COID="$(praescientia-ticks client-order-id \
  --tick-id="${TICK_ID}" --thesis="${THESIS_ID}" \
  --ticker="${TICKER}" --side="${SIDE}" --action="${ACTION}")"

# Clamp size against bankroll cap (records reason in events.jsonl)
CLAMPED="$(praescientia-ticks clamp-order \
  --kb-root="${KB}" --thesis="${THESIS_ID}" \
  --size="${SIZE}" --limit-cents="${LIMIT}")"

if [[ -n "${DRY_RUN:-}" ]]; then
  echo '{"kind":"dry_run_order","step":9,"thesis":"'"${THESIS_ID}"'","ticker":"'"${TICKER}"'","side":"'"${SIDE}"'","action":"'"${ACTION}"'","size":'"${CLAMPED}"',"limit_cents":'"${LIMIT}"',"client_order_id":"'"${COID}"'","ts":'$(date +%s%3N)'}' \
    >> "${KB}/.ticks/${TICK_ID}.events.jsonl"
else
  praescientia-orders create \
    --demo \
    --ticker="${TICKER}" \
    --side="${SIDE}" \
    --action="${ACTION}" \
    --size="${CLAMPED}" \
    --limit-cents="${LIMIT}" \
    --client-order-id="${COID}"
  # Increment daily breaker on real order
  python3 -c "
import json,sys
d = json.load(open('${KB}/.ticks/.daily_orders.json'))
d['count'] += 1
json.dump(d, open('${KB}/.ticks/.daily_orders.json','w'))
"
fi
```

### Order-translation rules (per §6 of the design)

- **Existing open order on same (market, side)** + `action == "buy"`:
  translate to `amend` if `|new_limit - resting_limit| / resting_limit
  > 0.05`, else skip (already-resting order satisfies intent).
- **`action == "cancel"`** with no matching open order: log
  `{"kind":"cancel_no_match",...}` and skip.

### Success

All orders placed (or logged as dry-run events) without server-side
rejection. Daily-order counter incremented per real order.

### Failure

- **Kalshi rejects duplicate `client_order_id`**: treat as success;
  this is the idempotency floor working as designed. Log
  `{"kind":"order_idempotent_replay","client_order_id":"...","ts":...}`
  and proceed.
- **Kalshi rejects for other reasons**: log
  `{"kind":"order_rejected","reason":"...","ts":...}` and proceed. Do
  not retry — the next tick will produce a fresh client_order_id and a
  fresh decision.

---

## Step 10 — post-state snapshot

### CLI

```bash
praescientia-ticks finish --kb-root="${KB}" --tick-id="${TICK_ID}"
```

Writes `${KB}/.ticks/${TICK_ID}.post.json` with chain heads after all
step-9 writes. Idempotent — if `post.json` already exists with the
same content, no-op.

### Success

`post.json` exists, content matches current chain heads.

### Failure

- **Disk error**: log `{"kind":"finish_failed","ts":...}` and **do
  not call `ScheduleWakeup`**. The next invocation will see `pre.json`
  without `post.json` and resume.
- **Chain head changed during write**: extremely unlikely (lock is
  held), but treat as resume case for next tick.

---

## Step 11 — global tick summary

```bash
THESES_PROCESSED=$(ls /tmp/decision_*.json 2>/dev/null | wc -l)
ORDERS_PLACED=$(grep -c '"kind":"order_placed"' "${KB}/.ticks/${TICK_ID}.events.jsonl" || echo 0)
REJECTED=$(jq -r 'length' "${KB}/.ticks/${TICK_ID}.rejected.json" 2>/dev/null || echo 0)
SETTLEMENTS=$(grep -c '"kind":"settlement_' "${KB}/.ticks/${TICK_ID}.events.jsonl" || echo 0)

cat > "/tmp/tick_summary_${TICK_ID}.md" <<EOF
Tick ${TICK_ID} complete.

Theses processed: ${THESES_PROCESSED}
Orders placed:    ${ORDERS_PLACED}
Rejected:         ${REJECTED}
Settlements:      ${SETTLEMENTS}
Paused:           ${PAUSED}
Dry-run:          ${DRY_RUN:-0}
Events file:      kb/.ticks/${TICK_ID}.events.jsonl
Pre/post:         kb/.ticks/${TICK_ID}.{pre,post}.json
EOF

praescientia-kb commentary write \
  --kb-root="${KB}" \
  --scope="commentary/global" \
  --body-file="/tmp/tick_summary_${TICK_ID}.md" \
  --tags="tick-summary,tick:${TICK_ID}"
```

On resume: scan `commentary/global/` for a `tick:${TICK_ID}` tag;
skip if present.

### Success

One global commentary entry tagged `tick-summary,tick:${TICK_ID}`.

### Failure

Log `{"kind":"global_summary_failed","ts":...}` and proceed. The tick
is functionally complete; the summary is a convenience for operators.

---

## Step 12 — release lock, schedule next tick

The lock is released when the `begin` process exits. If the
orchestrator skill held it across the tick via a long-lived
sub-process, terminate that sub-process now.

### Re-check kill switch

```bash
if [[ -f "${KB}/.ticks/KILL" ]]; then
  echo '{"kind":"abort_kill_switch_post","ts":'$(date +%s%3N)'}' \
    >> "${KB}/.ticks/.global_events.jsonl"
  exit 0  # do NOT schedule
fi
```

A `KILL` file placed during the tick must take effect before the next
`ScheduleWakeup` call.

### Decrement bounded counter (if applicable)

```bash
if [[ -f "${KB}/.ticks/.ticks_remaining" ]]; then
  N=$(cat "${KB}/.ticks/.ticks_remaining")
  echo $((N - 1)) > "${KB}/.ticks/.ticks_remaining"
  if (( N <= 1 )); then
    rm "${KB}/.ticks/.ticks_remaining"
    exit 0  # terminal tick — do NOT schedule
  fi
fi
```

### Schedule next tick

Call `ScheduleWakeup` (the harness tool) with the exact same
invocation that triggered this run:

```
ScheduleWakeup({
  delaySeconds: <parsed interval as integer>,
  prompt: "/praescientia-orchestrate --kb-root=<abs> --interval=<dur> [other flags]",
  reason: "praescientia tick ${TICK_ID} complete; next tick in ${INTERVAL}"
})
```

See `SKILL.md § ScheduleWakeup re-entry` for the exact prompt-template
rules (including the `--max-ticks` decrement, which is handled by the
sentinel file above so it survives session restarts).

### Success

`ScheduleWakeup` returns, the next firing is registered.

### Failure

- **`ScheduleWakeup` unavailable in this harness**: log
  `{"kind":"schedule_unavailable","ts":...}` and exit. The operator
  will need to restart the orchestrator manually.

---

## Cleanup

```bash
rm -f /tmp/decision_*.json /tmp/commentary_*.md /tmp/tick_summary_${TICK_ID}.md /tmp/thesis_input_${TICK_ID}_*.json /tmp/loss_inputs/*.json /tmp/loss_out.json /tmp/loss_commentary.md /tmp/settlements_${TICK_ID}.json
```

Temp files are scoped by `${TICK_ID}` so concurrent ticks (impossible
under the lock, but defensive) cannot collide.

---

## Quick-reference: artifact map for one tick

```
${KB}/.ticks/
  ${TICK_ID}.pre.json          ← step 1
  ${TICK_ID}.post.json         ← step 10
  ${TICK_ID}.events.jsonl      ← appended throughout (one line per event)
  ${TICK_ID}.rejected.json     ← step 7/8 failures (array)
  .lock                        ← held by `begin`; released at step 12
  .last_settlement.json        ← step 5 cursor
  .daily_orders.json           ← step 0.c / 9.c counter
  .ticks_remaining             ← step 12 bounded counter
  .global_events.jsonl         ← cross-tick events (kill, daily-pause, etc.)
  KILL                         ← operator-placed; aborts at 0.a or 12
  PAUSED                       ← skip-execute; placed by operator or breaker
```

Reading any one tick top-to-bottom = the same order as this checklist.

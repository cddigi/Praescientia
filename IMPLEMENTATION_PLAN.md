# Market Screener — IMPLEMENTATION_PLAN

Layer-1 market-selection agent. Decides *which markets become theses*,
upstream of `praescientia-thesis-analyst` (which decides *what to do
with an existing thesis*).

Three buckets — each is a distinct epistemic source of edge:

- **safe** — market-structure inefficiency (ladder arb, deep-ITM time
  decay, MM over-correction)
- **moderate** — fundamental research (Moneyball: roster/lineup/park
  factors the consensus underweights)
- **high_risk** — contrarian conviction (consensus narrative
  contradicted by a verifiable underlying fact)

## Stage 1: `praescientia-markets candidates`

**Goal**: New subcommand that emits a JSON list of layer-1-gate-passing
markets, deduped against existing theses.

**Success criteria**:
- `./zig-out/bin/praescientia-markets candidates --kb-root=./kb --demo`
  prints a single JSON object with `{scan_id, scan_ts_ms, candidates,
  gate_summary}`.
- Each `candidate` entry has `{ticker, event_ticker, status, title,
  yes_bid_cents, yes_ask_cents, last_price_cents, volume, open_interest,
  close_time}`.
- `gate_summary` reports counts: `{total_fetched, gate_active,
  gate_future_close, gate_bid_positive, gate_ask_sub_100,
  gate_volume_min, gate_spread_max, gate_dedup, passed}`.
- Dedup against every `kb/theses/*/manifest.json` `market_set` entry.

**Configurable flags**:
- `--kb-root=PATH` (default `./kb`)
- `--min-volume=N` (default `5`)
- `--max-spread-cents=N` (default `10`)
- `--max-candidates=N` (default `50`, caps output array)
- `--limit=N` (default `1000`, Kalshi `/markets` page size)

**Tests**: pure-helper tests in `tools/markets.zig` covering the gate
predicates against synthetic Market fixtures.

**Status**: Not Started

---

## Stage 2: `src/kb/screener.zig` — validator module

**Goal**: Typed schema + validation for the screener agent's output.
Mirrors the role `src/kb/ticks.zig` plays for the thesis-analyst.

**Success criteria**:
- `ScreenerOutput`, `BucketEntry`, `BucketKind` structs declared.
- `validate(allocator, json_bytes, existing_market_set) → ValidationResult`
  enforces hard rules:
  - All tickers in buckets MUST NOT appear in `existing_market_set`
    (dedup).
  - Each bucket entry has ≥2 `suggested_seed_commentary` entries
    (so §6.b will pass at apply-time).
  - `confidence_bp ∈ [0, 10000]`.
  - `proposed_thesis_id` matches `^[a-z][a-z0-9-]+$` (kebab slug).
  - `bucket` ∈ `{"safe", "moderate", "high_risk"}`.
  - `primary_signal` non-empty.
  - `our_estimate_yes_cents` and `implied_yes_cents` ∈ `[0, 100]`.
  - Bucket counts ≤ caps (default: safe=5, moderate=3, high_risk=2).
- Inline tests: positive case, dedup rejection, neighbor-count rejection,
  bucket-cap rejection, malformed JSON rejection.

**Status**: Not Started

---

## Stage 3: `tools/screener.zig` — `praescientia-screener` CLI

**Goal**: New binary with `validate` and `apply` subcommands.

**Success criteria**:
- `praescientia-screener validate --output=PATH --kb-root=PATH` exits
  0 on valid, 1 on invalid, with `{ok, reason}` on stderr.
- `praescientia-screener apply --output=PATH --kb-root=PATH [--bucket=safe|moderate|high_risk] [--dry-run]`
  - For each accepted entry: invokes the same Zig functions
    `add-market`, `add-thesis`, `commentary write` use internally.
  - `--dry-run` prints a JSON plan of writes without touching disk.
  - Filters by `--bucket` if provided; otherwise applies all three.
- `--help` smoke check passes (the Stage 4 build-step pattern).

**Tests**: inline tests on argv parsing + dry-run plan emission.

**Status**: Not Started

---

## Stage 4: Agent definition

**Goal**: `.claude/agents/praescientia-market-screener.md` — the
Opus-default sub-agent.

**Success criteria**:
- Matches the structural pattern of
  `.claude/agents/praescientia-thesis-analyst.md` (yaml frontmatter,
  Role, Output protocol, Input, Output schema, Hard rules, Decision
  framework, Examples, Hard refusals).
- Three bucket-specific decision frameworks with evidence requirements.
- Examples: positive empty-screen (no candidates qualify), positive
  multi-bucket (4 safe + 2 moderate + 1 high_risk), error envelope.
- Hard rules section restates the validator's invariants from Stage 2
  so the agent self-gates before the orchestrator rejects.

**Status**: Not Started

---

## Stage 5: Smoke script + documentation

**Goal**: End-to-end smoke harness + CLAUDE.md surface.

**Success criteria**:
- `scripts/screener_smoke.sh` exits 0 against demo:
  1. Runs `praescientia-markets candidates` on the demo API.
  2. Feeds the output to a deterministic mock that produces a
     valid `ScreenerOutput` (no real Agent call — keeps smoke
     deterministic).
  3. Runs `praescientia-screener validate` on the mock.
  4. Runs `praescientia-screener apply --dry-run` and verifies the
     emitted plan.
- CLAUDE.md tool table updated with the two new entries (`candidates`
  subcommand + `screener` binary).
- `tick.md` referenced (no rewrite — the screener is operator-triggered
  outside the per-tick lifecycle).

**Status**: Not Started

---

## Stage 6: All tests pass

**Goal**: `zig build test --summary all` shows all green; smoke script
exits 0.

**Success criteria**:
- Total tests pass count > current 251 (each new test adds to the total).
- `./scripts/screener_smoke.sh` exits 0.
- `./zig-out/bin/praescientia-screener --help` exits 0 with
  `Usage:` on stderr.
- `./zig-out/bin/praescientia-markets candidates --demo --kb-root=./kb`
  exits 0 with valid JSON on stdout.

**Status**: Not Started

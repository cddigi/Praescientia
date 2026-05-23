# Source-Curator — Implementation Plan

> **Status:** Scoping. No code yet.
> **Branch (intended):** `source-curator-mvp`
> **Tracking issue:** TBD
> **Motivation:** Ollama-vs-Sonnet bakeoff §3.5 — both models default to stock "no external reference identified" because cold-start theses have no upstream sources. A dedicated curator that fetches, summarises, and persists sources before the analyst runs would (a) collapse most of the Sonnet/Ollama analytical gap and (b) let the KB accrete into a local Library-of-Alexandria.

---

## Design constraints

1. **Do not migrate the chain payload schema.** `CommentaryPayload` in `src/kb/commentary.zig` is hash-stable. Source metadata rides on existing `tags`, `agent.model`, and `references` fields plus a structured first-line in `body`.
2. **Mirror the screener architecture.** The screener already has the shape we need: sub-agent emits JSON, `<feature> validate` enforces invariants, `<feature> apply` materialises persistence, daemon hook triggers via `--<feature>-cadence`. Reuse this pattern verbatim.
3. **Opt-in by default.** Daemon flag gates the curator off unless explicitly enabled. Existing trading flows must not change behaviour until the curator earns its place.
4. **Hard cost cap.** Curator dispatches must respect a per-tick fetch budget. No unbounded crawling.

---

## Stage 1: Source-tier + TTL conventions (docs + tests only)

**Goal:** Land the conventions that let source-backed commentary entries coexist with existing analyst/loss-reflector entries — no new agents, no new CLIs.

**Conventions to document in `src/kb/commentary.zig`:**

- **Source-tier tag.** Exactly one `source:<tier>` tag where `tier ∈ {primary, sportsbook, news_org, aggregator, forum, model_synthesis}`. Existing analyst entries get `source:model_synthesis` retroactively (default treatment in indexer when no `source:*` tag is present).
- **Body frontmatter.** When `source:<tier>` is non-`model_synthesis`, the body MUST begin with a single line of the form `--- src: <url> fetched: <iso8601> valid_until: <iso8601> ---`. Indexer chunker strips this line before embedding. Validator enforces presence.
- **Reference convention.** `references[]` for source-backed entries point at *other* source entries this one builds on (chains of source provenance), not at thesis entries.

**Tests:**
- `src/kb/commentary.zig` add unit tests covering tag-presence rules and frontmatter parse.
- `tools/indexer/test_indexer.py` add a test asserting the frontmatter is stripped pre-embed.

**Success criteria:**
- Existing entries (which lack `source:*` tags) still parse, hash, and embed identically.
- New entries with `source:primary` + frontmatter survive a write→read→indexer round trip.
- Validator rejects an entry tagged `source:news_org` whose body lacks the frontmatter line.

**Risk:** Minimal — additive convention, no chain-bytes change.

---

## Stage 2: `praescientia-source-curator` agent definition

**Goal:** Define the sub-agent's input/output contract. Hand-dispatchable; no orchestrator integration yet.

**File:** `.claude/agents/praescientia-source-curator.md`

**Model:** Sonnet (inherit). Curator needs WebSearch + WebFetch, which Ollama lacks.

**Tools:** `WebSearch, WebFetch, Bash, Read`

**Input schema** (orchestrator delivers as JSON):

```
{
  "tick_id":      "<ULID>",
  "thesis":       { id, description, market_set, ... } | null,
  "ticker":       "<KX...>" | null,
  "search_hints": ["string", ...],
  "neighbors":    [{ hash, scope_path, body, tags, ts_ms }, ...],
  "max_fetches":  <integer, default 5>,
  "tier_budget":  { primary: 3, sportsbook: 2, news_org: 3, aggregator: 2, forum: 1 }
}
```

Either `thesis` or `ticker` MUST be present (curator can be scoped to a tracked thesis OR a raw market candidate from the screener).

**Output schema:**

```
{
  "tick_id":    "<echo>",
  "entries": [
    {
      "scope":         "thesis" | "market" | "global",
      "scope_key":     "<thesis_id or ticker, omitted for global>",
      "source_url":    "https://...",
      "source_tier":   "primary" | "sportsbook" | ...,
      "fetch_ts_ms":   <int>,
      "valid_until_ms":<int>,
      "body":          "<≤16KB; frontmatter is prepended by the apply step, NOT the agent>",
      "tags":          ["topic:...", ...],
      "references":    ["<hex hash of related entry>", ...]
    }, ...
  ],
  "fetches_consumed":    <int>,
  "summary": "<≤512 chars: one paragraph on what was learned this dispatch>"
}
```

**Hard rules in the agent prompt:**

- `entries.length ≤ max_fetches` AND `entries.length ≥ 1` — no empty dispatches. If the agent has nothing to add, that itself is a finding worth recording with `source_tier: model_synthesis`.
- Per-tier counts respect `tier_budget`.
- Every entry's `source_url` must be reachable via WebFetch within the dispatch — curator MUST have actually fetched, not synthesised.
- `valid_until_ms - fetch_ts_ms` respects per-tier TTL bounds:
  - `primary`: up to event-close OR 30 days
  - `sportsbook`: ≤ 4 hours
  - `news_org`: ≤ 7 days
  - `aggregator`: ≤ 30 days
  - `forum`: ≤ 24 hours
  - `model_synthesis`: TTL ignored (no expiry)
- Body MUST cite source URL inline at least once, even though the frontmatter also carries it — defence-in-depth: prevents the body alone from being misattributed if frontmatter is ever stripped.

**Success criteria:**

- Hand-dispatching the curator with a single-market input produces a JSON envelope passing `jq -e .`.
- Dispatch shows non-zero `tool_uses` (proves the agent actually used WebSearch/WebFetch).
- Output `entries.length ∈ [1, max_fetches]`.

---

## Stage 3: Validator + applier — `praescientia-curator` CLI

**Goal:** Mirror `praescientia-screener {validate,apply}` for the curator's output. Read-only `validate` enforces invariants; `apply` writes via `kb commentary write`.

**New files:**
- `src/kb/curator.zig` — schema parser + `validate(input, output) !ValidationResult` mirroring `src/kb/screener.zig::validate`.
- `tools/curator.zig` — `validate`, `apply`, `tick` subcommands mirroring `tools/screener.zig` shape.

**Validator invariants:**

1. `tick_id` echoed correctly.
2. Per-tier TTL bounds enforced (rejection on violation).
3. `valid_until_ms > now_ms + 60_000` — no entries pre-expired or about-to-expire.
4. `source_url` non-empty, parses as a URL, scheme ∈ {`http`, `https`}.
5. Body length ≤ `body_max_bytes` (16 KB) AFTER frontmatter prepend.
6. `entries[].body` MUST contain `source_url` substring — the defence-in-depth check.
7. Within a single dispatch, no two entries share the same `source_url + scope + scope_key` triple — no dupes.
8. Across the KB (queried via `kb commentary list --tag source:*`), if a non-expired entry already exists with the same `source_url + scope_key`, the new entry is REPLACED, not appended — URL-keyed cache semantics.
9. `references[]` hashes must exist in the chain (rejection on dangling refs).

**Applier behaviour:**

- Prepend the frontmatter line to each entry's body.
- Add `source:<tier>` tag.
- Add `agent: { model: "praescientia-source-curator", run_id: "<tick_id>" }` to the payload.
- Call `kb commentary write` per entry; collect resulting hashes; print a JSON receipt.

**Success criteria:**

- `./scripts/curator_smoke.sh` — a deterministic stub agent (like `tests/fixtures/mock_thesis_analyst.sh`) feeds canned output through validate→apply; the resulting entries appear in `kb commentary list`.
- Validator rejects 8 known-bad inputs (one per invariant) with a stable error message.

---

## Stage 4: Daemon integration — `--sources-floor` flag

**Goal:** Wire the curator into the per-thesis daemon loop. Triggers only when a thesis's commentary-neighbour count is below a floor.

**Changes to `tools/orchestrate_daemon.zig`:**

- New flag: `--sources-floor=N` (default `0` = off; recommended starting value `3`).
- New flag: `--sources-curator-bin=PATH` (default `./zig-out/bin/praescientia-curator`).
- New flag: `--sources-cache-ttl=DUR` (default `6h`; how long to remember a `last_curator_run` per thesis before re-triggering).

**Pre-analyst hook (per thesis, per tick):**

1. Read `kb/.ticks/<thesis_id>.last_curator_run_ms`. If `now - last_run_ms < cache_ttl`, skip.
2. Count non-expired commentary neighbours for this thesis (similarity API). If `count ≥ floor`, skip.
3. Spawn `praescientia-curator tick --thesis=<id>`. The curator binary handles the agent dispatch internally (mirror `screener tick`'s `claude -p` pattern).
4. On success: persist `last_curator_run_ms` and proceed to thesis-analyst with the refreshed neighbour set.
5. On failure: do NOT advance `last_curator_run_ms` (retry next iteration). Skip thesis-analyst this tick — no analysis without grounding.

**Important:** The hook is BLOCKING. If the curator takes 60s and there are 10 cold theses, the first tick burns 10 minutes. This is intentional for MVP — once a thesis has been grounded, subsequent ticks skip the curator and run at normal cadence. The pain is amortised.

**Success criteria:**

- `./scripts/curator_daemon_smoke.sh` — boots a fresh kb_root with one thesis, runs the daemon for one tick with `--sources-floor=3`, verifies the curator ran, ≥3 entries landed, and the thesis-analyst saw them in its neighbour set.
- A second daemon iteration within `cache_ttl` skips the curator (confirmed via `--verbose` log).

---

## Stage 5: Guardrails + bakeoff regression test

**Goal:** Validate that the curator does close the Ollama-vs-Sonnet gap, and that the system fails safely under cost/load pressure.

**Guardrails to add:**

- Per-tick TOTAL fetch cap across all curator dispatches in one tick (daemon-level). Default `30`.
- Per-tick total wallclock cap on curator phase (default `5min`). Excess theses fall back to "skip analyst, no grounding" with a metrics counter.
- New Prometheus counters in `src/kb/metrics.zig`:
  - `curator_dispatches_total{result=ok|error|skipped}`
  - `curator_entries_written_total{tier}`
  - `curator_fetches_total{tier}`
  - `curator_cache_hits_total`

**Regression test:**

- `./scripts/ollama_vs_sonnet_smoke.sh` (proposed in the bakeoff report §7.7):
  1. Boot fresh kb_root.
  2. Run curator on the 3 bakeoff markets to populate sources.
  3. Re-run the bakeoff thesis-analyst dispatches under both Sonnet and Ollama.
  4. Assert: Ollama `commentary_body` write rate ≥ Sonnet's previous baseline, AND `external_cross_ref` no longer matches the stock template, AND analysis-field byte ratio ≥ 0.7.

**Success criterion (the load-bearing one):** Ollama's `external_cross_ref` stops returning the literal 33-byte stock template on at least 2 of 3 bakeoff markets when curator-sourced entries are present in the neighbour set.

---

## Open decisions (need user input before code lands)

### D1. Source-tier weighting in the indexer

**Question:** Should the indexer apply a tier weight when ranking similarity-search results, or leave tier as a metadata flag the thesis-analyst reads?

**Proposed default:** Tier is *metadata only* for MVP. Analyst sees tier in the neighbour list and reasons about it. Indexer-side weighting is a Stage 6 concern.

**Why this matters:** Indexer-side weighting is invisible to the analyst — convenient but opaque. Analyst-side reasoning is explicit but adds prompt load.

### D2. Curator scope — per-thesis vs cross-thesis caching

**Question:** When the EU-CPI curator fetches a Eurostat HICP page, is that entry written to `thesis/eu-cpi-may26-above-3pt1/commentary/` or to `commentary/global/` so future Euro-CPI theses can find it?

**Proposed default:** Write to `commentary/global/` whenever the source is non-thesis-specific (Eurostat releases, FOMC statements, base rates). Write to `thesis/<id>/` only when the source is thesis-event-specific (e.g., a specific game's injury report). The curator decides scope per-entry.

**Why this matters:** Global scope is the Library-of-Alexandria payoff. Thesis scope is safer (lower blast radius if a source turns out to be junk).

### D3. Default `--sources-floor` value

**Question:** What should the recommended floor be for a daemon operator to start with?

**Proposed default:** `3` — matches the conversation framing and gives the analyst ≥1 source beyond the 2-neighbour precondition. Operators can override.

**Alternative:** `2` — matches existing precondition; curator only runs when there are zero neighbours, minimising spawns. Tradeoff: lower coverage growth.

### D4. Curator model

**Question:** Sonnet for everything, or hybrid (Sonnet for fetch/summarise, then Ollama for in-KB re-summarisation passes)?

**Proposed default:** Sonnet-only for MVP. Hybrid is a Stage 6 cost optimisation.

**Why this matters:** Sonnet+WebSearch is the cost driver. If the daemon runs the curator for 10 cold theses on first boot, that's 10× Sonnet dispatches with 3-5 WebFetch calls each. Real money. Worth quantifying before committing to a default-on configuration.

---

## Out of scope for this branch

- Refactoring `praescientia-market-screener.suggested_seed_commentary` to call the curator. The screener can keep writing seed commentary directly; future branch can unify.
- Indexer changes beyond frontmatter stripping (no tier weighting, no expiry filtering yet — Stage 6 candidate).
- A standalone "fact-base query" interface separate from similarity search.
- Adversarial-source detection (flagging known-bad domains). MVP trusts curator's tier judgement.

---

## Status checklist

- [ ] Stage 1: Source-tier + TTL conventions documented in `src/kb/commentary.zig` + tests pass
- [ ] Stage 2: `.claude/agents/praescientia-source-curator.md` lands and hand-dispatch produces valid envelope
- [ ] Stage 3: `src/kb/curator.zig` + `tools/curator.zig` + `scripts/curator_smoke.sh` green
- [ ] Stage 4: Daemon hook lands + `scripts/curator_daemon_smoke.sh` green
- [ ] Stage 5: `scripts/ollama_vs_sonnet_smoke.sh` green; Ollama gap measurably closes

Remove this file when all five stages are complete and the smoke script is canonicalised.

---

## Pre-existing cleanup note

`IMPLEMENTATION_PLAN.md` at repo root still holds the per-thesis-cadence (game_state) plan, which the recent screener-cadence-daemon branch completed. Per project convention ("Remove file when all stages are done") it can be retired. Suggest doing that as a one-line cleanup before starting Stage 1 here, so `IMPLEMENTATION_PLAN.md` can move to `IMPLEMENTATION_PLAN_source_curator.md` → `IMPLEMENTATION_PLAN.md` for clarity.

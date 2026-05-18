# Knowledge-Base Follow-Ups — Design

> Companion to `2026-05-17-state-chain-knowledge-base-design.md` and `-implementation.md`. The KB substrate (Stages 1–4) is merged. This document scopes the four remaining items that the original plan deferred.

## Context

Stages 1–4 of the KB plan landed: chains, branches, ingest, rollups, divergence, the `praescientia-kb` CLI, and read-only `/api/kb/*` dashboard routes. The original plan parked five items at the bottom:

1. Manifest schema validation
2. Prometheus-style `/metrics` endpoint
3. `portfolios/` runtime data migration
4. `praescientia-kb init` bootstrap
5. Dashboard HTML KB tab

Of these, **(3) is dropped** — `portfolios/` is gitignored, has no producers in the current tree, and no documented schema. Starting fresh in `kb/` is the canonical path; an importer can be written ad hoc when concrete legacy data appears. The remaining four ship here.

## Goals

- **Fail loudly on bad manifests** rather than panicking inside `.?` unwraps. Operators should see a precise error name with file path, not a stack trace.
- **Make the substrate observable** without taking a Prometheus client library dependency. A single `/metrics` text endpoint is enough for the dashboard's existing scraping story.
- **Make `kb_root` first-class** — a one-liner that bootstraps a fresh tree with a sample market + thesis is the difference between "I have to RTFM" and "I run one command."
- **Surface the KB in the dashboard** so the read routes earn their keep visually.

## Decision Summary

| Area | Choice |
|---|---|
| Manifest validation | Hand-rolled per-field checks in `kb.manifest`; reject panics |
| Metrics format | Prometheus text exposition (no client library) |
| Metrics location | New `src/kb/metrics.zig` module + `/metrics` route in `server/handlers.zig` |
| Counter mechanism | `std.atomic.Value(u64)` at module scope; safe under `Io.Threaded` |
| `kb init` | Subcommand within existing `tools/kb.zig` |
| Init sample | Off by default; `--with-sample` opt-in |
| Dashboard tab | Inline HTML/JS in `server/dashboard.html` (existing convention) |
| Portfolios migration | **Dropped from scope** |

---

## 1. Manifest Schema Validation

### Problem

`kb.manifest.parseMarket` and `parseThesis` currently use `.?` to unwrap required fields. A manifest with a missing `ticker` panics the server. Weights aren't checked to sum to anything; price thresholds aren't range-checked; ticker characters aren't constrained. The validation gap is small but every failure mode is operator-visible at the worst possible moment.

### Approach

Two-pass: parse without panics, then validate semantically.

**Parse pass** — replace every `.?` with `orelse return error.MissingField`, returning a distinct error name per field (`error.MissingTicker`, `error.MissingMarketSet`, etc.). This alone eliminates the panic class.

**Validate pass** — add `validateMarket(*const MarketManifest) !void` and `validateThesis(*const ThesisManifest) !void`. Call site responsibility — callers that already parse can opt in. Existing callers (`observeMarket`, `recomputeThesisReality`) gain a validate call after parse.

### Rules

| Manifest | Rule | Error |
|---|---|---|
| Market | `ticker.len ∈ [1, 64]` | `error.TickerLengthOutOfRange` |
| Market | `ticker` matches `[A-Z0-9-]+` | `error.TickerHasInvalidChar` |
| Market | `price_delta_cents ∈ [1, 100]` | `error.PriceDeltaOutOfRange` |
| Thesis | `id.len ∈ [1, 64]`, matches `[a-z0-9-]+` | `error.ThesisIdInvalid` |
| Thesis | `description.len ∈ [1, 512]` | `error.DescriptionLengthOutOfRange` |
| Thesis | `market_set.len ≥ 1` | `error.EmptyMarketSet` |
| Thesis | `weights_bp.len == market_set.len` | `error.WeightSetMismatch` |
| Thesis | `sum(weights_bp) == 10000` | `error.WeightSumMismatch` |
| Thesis | `confidence_delta_bp ∈ [1, 10000]` | `error.ConfidenceDeltaOutOfRange` |
| Thesis | `rollup_fn.len ≥ 1` | `error.MissingRollupFn` |

`rollup_fn` is checked for non-empty, not registry-membership — validation must succeed at boot before `registerAll` runs.

### Trade-off considered

A vendored JSON Schema validator would handle the rules declaratively, but no such library exists in the Zig 0.16 ecosystem that's worth the maintenance debt for ~10 rules. Hand-rolled is ~80 lines and stays in-tree.

---

## 2. Prometheus `/metrics` Endpoint

### Problem

There's no way to observe whether `observeMarket` is appending vs. no-opping, whether torn-tail recovery ever triggers, or how often the dashboard routes are hit. Operating the system blind makes regressions invisible.

### Approach

A single `/metrics` GET route returns Prometheus text exposition. Counters live in `src/kb/metrics.zig` as `std.atomic.Value(u64)` instances. Call sites bump counters directly; the renderer iterates and writes lines.

### Counters

| Name | Labels | Bumped from |
|---|---|---|
| `praescientia_kb_chain_appends_total` | `kind` (e.g. `market.reality`, `thesis.reality`) | `chain.WriteHandle.append` after `sync` succeeds |
| `praescientia_kb_observe_skipped_total` | `reason` (`price_delta_below_threshold`, `aggregate_unchanged`) | `observeMarket`, `recomputeThesisReality` when returning `false` |
| `praescientia_kb_lock_contention_total` | — | `openForWrite` on `error.AlreadyLocked` |
| `praescientia_kb_torn_tail_recovered_total` | — | `recoverTornTail` when truncating |
| `praescientia_dashboard_requests_total` | `route`, `status` (`ok`, `client_error`, `server_error`) | `handleRequest` after the handler returns |
| `praescientia_kb_root_configured` | — | Gauge: 1 when server started with `--kb-root=`, else 0 |

The `kind` and `reason` labels are bounded enums — encoded as separate counters internally (no string-keyed map needed). `route` for dashboard requests is *also* a bounded enum: one counter per route slot in the route table, identified by `route.pattern`.

### Exposition format

```
# HELP praescientia_kb_chain_appends_total Successful chain appends.
# TYPE praescientia_kb_chain_appends_total counter
praescientia_kb_chain_appends_total{kind="market.reality"} 142
praescientia_kb_chain_appends_total{kind="thesis.reality"} 18
...
```

### Trade-off considered

A pull-based client (e.g. statsd / OpenTelemetry SDK) would be richer but is overkill: the dashboard already serves HTTP, Prometheus already supports scraping plain text, and counters compose naturally with the `std.atomic.Value` already in stdlib.

---

## 3. `praescientia-kb init`

### Problem

Bootstrapping a new `kb_root` today is a series of `mkdir` + hand-edit-JSON steps. New deployments and integration-test fixtures need this to be one command.

### Approach

Extend `tools/kb.zig` with an `init` subcommand:

```
praescientia-kb init <kb_root> [--with-sample]
```

Behavior:
- Creates `<kb_root>/markets/` and `<kb_root>/theses/` (does not fail if `<kb_root>` already exists, *does* fail if either subdir already exists).
- With `--with-sample`: also creates one market (`SAMPLE`) and one thesis (`sample`) populated with empty chains + `branches.json` + manifests showing the canonical shape. No data — just the file scaffolding.

The sample-mode manifests double as the in-repo reference for "what does a real manifest look like."

### Trade-off considered

A standalone `praescientia-kb-init` binary would mirror the per-tool pattern but doubles the build cost and the operator's mental load. A subcommand on the existing CLI is cheaper.

---

## 4. Dashboard HTML KB Tab

### Problem

Three `/api/kb/*` routes ship in Stage 4 but the dashboard never calls them. The dashboard tab is the user-facing payoff for the whole KB plan; without it, the routes are a `curl`-only feature.

### Approach

A new sidebar section "Knowledge Base" with two pages, both inline in `server/dashboard.html`:

- **KB Markets** — ticker input + "Inspect" button → renders `length`, `head_hex`, and the last 3 entries as syntax-highlighted JSON.
- **KB Theses** — id input + two buttons ("Branches", "Divergence"). Branches lists each branch with its `created_at_hash`. Divergence prints `first_drift_idx`, `drift_amount_bp`, `threshold_bp`. A `threshold_bp` input lets the operator override the default.

Both panels handle the `503` (kb_root unconfigured) and `404` (no chain at path) cases with a friendly inline error.

### Trade-off considered

A second SPA file would let the KB UI evolve independently, but it'd duplicate the navigation chrome and break the single-binary deployment story. Embedding stays consistent.

---

## Test Strategy

- **Manifest validation**: one positive test per manifest type, one negative test per rule. Reject panics — every existing parser test that constructs a "deliberately broken" manifest gets a corresponding `validate*` test.
- **Metrics**: snapshot the counter state before + after a known call sequence, assert the deltas. Render once and check for substring + count for each declared metric.
- **`kb init`**: tmpDir, run init, assert the tree shape via `std.Io.Dir.access`. Repeat with `--with-sample`, assert the sample manifests parse cleanly through the existing `parseMarket` / `parseThesis`.
- **Dashboard tab**: a Zig test that `std.mem.indexOf`s for the new nav-item markers in the `@embedFile`'d HTML — same lightweight smoke style as the existing route-match test. End-to-end browser testing is left for hand-verification.

---

## Open Questions (Resolved)

- **Should `portfolios/` get a migration?** No — dropped from scope; format undocumented, no producers exist, restart-in-kb is the canonical path.

## Deferred (Out of Scope)

- A second metrics exposition format (OpenTelemetry, statsd, etc.). Prometheus text is sufficient.
- Auth on `/metrics`. Same surface as the rest of `/api/*` — defer until/unless the dashboard sprouts an auth layer.
- A dashboard "fork" UI. The CLI handles forking; the dashboard stays read-only this iteration.
- Real-time chain updates over WebSocket. Polling is fine for now; WebSocket is its own design problem.

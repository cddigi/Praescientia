# Kalshi Demo Loop — Design

> Companion to the KB plan + follow-ups. Closes the gap between "the KB compiles and tests" and "we can actually run the prediction concept against the Kalshi demo API." Strategy for the post-MVP polish lives in `2026-05-18-kalshi-demo-loop-polish-strategy.md`.

## Context

The KB substrate is feature-complete locally: chains, branches, manifests with validation, rollup, divergence, metrics, `kb init`, dashboard read routes. What's missing is the wiring between the Kalshi client (which already speaks RSA-PSS to demo-api.kalshi.co) and the KB ingest path. `kbHookMarket` and `kbHookFill` exist as standalone functions; nothing in the production call path invokes them. There's also no way for an operator to record a prediction or register a new market/thesis short of editing JSON by hand.

This plan ships the minimum viable end-to-end loop: **register a thesis → poll Kalshi → record predictions → inspect divergence**. The five items map 1:1 onto the punch list from the prior conversation.

## Goals

- **One operator, three commands.** Add a thesis, predict over time, watch divergence — without touching JSON.
- **Polling is a single binary.** No daemons, no flag-juggling on existing CLIs. `praescientia-poll-markets --kb-root=PATH` does the right thing for every market in the tree.
- **The thesis chain stays current** without operator intervention. Polling triggers the reducer; manifest's `confidence_delta_bp` is honored.

## Decision Summary

| Area | Choice |
|---|---|
| Poll surface | New `praescientia-poll-markets` binary, one-shot per invocation |
| Predict target | Thesis-level only (`theses/<id>/prediction/main.jsonl`) |
| Manifest CLI | Two subcommands: `kb add-market` and `kb add-thesis` |
| Thesis-weights flag | JSON literal: `--weights='{"KXFED":7000,"KXRECESSION":3000}'` |
| Reducer trigger | Poller invokes `recomputeThesisReality` for every thesis after market ingest |
| Threshold | `recomputeThesisReality` reads `manifest.confidence_delta_bp`, converts to cents (`bp / 100`), replaces the hardcoded `1` |
| Daemon mode | Out of scope — `while sleep 60s` shell loop or cron is sufficient for v1 |

---

## §1. `praescientia-poll-markets`

### Behavior

```
praescientia-poll-markets --kb-root=PATH [--env=demo|live] [--verbose]
```

One iteration:

1. Open `kb_root/markets/` and iterate every subdirectory.
2. For each subdir name `TICKER`:
   a. Read `markets/TICKER/manifest.json`; parse + validate.
   b. Call `kalshi.markets.get(client, arena, ticker)` → `Market` struct.
   c. Map response fields to `MarketSnapshot` (yes_bid_cents, yes_ask_cents, volume, last_trade_cents, ts_ms from `Clock.real.now`).
   d. Call `kalshi.markets.kbHookMarket(allocator, io, kb_root_dir, ticker, snap)`. Errors bump the existing `lock_contention` / observation counters and are logged; the loop continues.
3. Open `kb_root/theses/` and iterate every subdirectory.
4. For each subdir name `THESIS_ID`:
   a. Call `kb.ingest.recomputeThesisReality(allocator, io, kb_root_dir, thesis_id)`.
   b. Errors are logged; the loop continues.
5. Print a one-line summary: `polled N markets, recomputed M theses, K skipped`.

### Why one-shot and not a daemon

The operator's outer loop varies — a cron entry, a `while sleep`, a tmux pane left running. Building those into the binary forces a design choice on every consumer. A one-shot binary composes cleanly with all three. The poller adds a `--loop=<duration>` flag in plan B if and only if shell wrapping turns out to be ergonomically wrong.

### Failure model

Each market and each thesis runs inside an independent allocator arena that's freed at the end of its iteration. One bad market doesn't poison the rest of the poll. Errors print to stderr with the ticker and the error tag. The process exits 0 if *any* iteration succeeded, exit 1 if every iteration failed (so cron can alert on full outage).

---

## §2. `praescientia-kb predict`

### Behavior

```
praescientia-kb predict <thesis-id> --confidence-bp=N [--rationale="..."]
```

1. Verify `kb_root/theses/<thesis-id>/manifest.json` exists and validates.
2. Build a canonical-JSON `thesis.prediction` payload with alphabetically-sorted keys:
   ```json
   {"confidence_bp":7200,"kind":"thesis.prediction","rationale":"...","trigger":{"type":"manual_decision"},"ts":1747630000000}
   ```
3. Call `kb.ingest.observeManual(allocator, io, prediction_dir, payload)` against `kb_root/theses/<thesis-id>/prediction`.
4. Print: `wrote prediction at <hash-prefix> (confidence=7200 bp, thesis=fed-cuts)`.

### Why thesis-level only

Per the decision in the previous turn. The prediction concept is "I think the *thesis* — aggregate of these markets — will resolve a certain way." Market-level predictions are a different feature (betting against an individual market) and would clutter the surface before the thesis-level loop is exercised.

### Source of `kb_root`

CLI inherits `--kb-root=PATH` from the `praescientia-kb` global flags (added in step 3 below; today the CLI hardcodes relative paths). Without `--kb-root`, default to `./kb`.

---

## §3. `kb add-market` and `kb add-thesis`

### Behavior

```
praescientia-kb add-market <ticker> [--price-delta-cents=N]    # default 1
praescientia-kb add-thesis <id> \
    --description="..." \
    --weights='{"KXFED":7000,"KXRECESSION":3000}' \
    [--rollup=weighted_avg_v1] \
    [--confidence-delta-bp=N]                                  # default 500
```

Each subcommand:

1. Refuses if the target directory already exists (operator must `--force` to overwrite).
2. Writes `manifest.json` with canonical-JSON encoding.
3. Creates `reality/main.jsonl` (empty) + `reality/branches.json` (genesis-only).
4. For theses: also creates `prediction/main.jsonl` + `prediction/branches.json`.
5. Runs `parseMarket`/`parseThesis` + `validateMarket`/`validateThesis` against the written file before returning success. Catches typos.
6. Prints: `created markets/KXBTC-26 (price_delta_cents=1)` / `created theses/fed-cuts (markets=[KXFED, KXRECESSION])`.

### Why JSON for weights

A k=v,k=v string parser is 20 lines of branching and a worse error message. `std.json.parseFromSlice` already exists, takes the same characters, and gives the operator a recognizable shape. The `market_set` field of the thesis manifest is derived from the weights-object keys — no separate `--markets` flag.

### `--kb-root` plumbing

Promote the existing per-subcommand `--kb-root` handling into `praescientia-kb`'s global flag list. All subcommands (`inspect`, `branches`, `fork`, `divergence`, `init`, `predict`, `add-market`, `add-thesis`) honor it. Defaults to `./kb`.

---

## §4. Reducer auto-trigger

The poller (§1) already calls `recomputeThesisReality` for every thesis after the market pass. That's the only trigger this plan ships. The library API stays the same; the CLI subcommand `praescientia-kb recompute <thesis-id>` is added as an explicit fallback for ad-hoc re-runs (debug, replay).

No hook is added inside `observeMarket` itself. Coupling `kb/ingest.zig` to all thesis chains in the world creates a circular dependency (theses reference markets; an `observeMarket` that recomputes theses would have to enumerate theses inside the ingest module). Keep the trigger at the poller boundary where the iteration is already in scope.

---

## §5. Honor `manifest.confidence_delta_bp`

Replace this in `recomputeThesisReality`:

```zig
if (prev_agg) |p| {
    const delta = if (p > result.aggregate_yes_cents) p - result.aggregate_yes_cents else result.aggregate_yes_cents - p;
    if (delta < 1) return false;
}
```

with:

```zig
if (prev_agg) |p| {
    const delta_cents = if (p > result.aggregate_yes_cents) p - result.aggregate_yes_cents else result.aggregate_yes_cents - p;
    const delta_bp = delta_cents * 100;
    if (delta_bp < manifest.confidence_delta_bp) {
        @import("metrics.zig").bumpObserveSkipped(.aggregate_unchanged);
        return false;
    }
}
```

The metrics bump already exists for the hardcoded path; the rule swap is mechanical.

### Trade-off considered

`confidence_delta_bp` is currently bp-of-aggregate-yes, not bp-of-thesis-confidence — the design's original intent was the latter. The two are equivalent when the thesis aggregate is interpreted as the implied yes-probability of the thesis. Documented in the design doc; no change to the manifest schema.

---

## Test Strategy

- **Poller**: tmpDir kb_root, mock Kalshi client (a stub `client.request` that returns a canned JSON response from a fixture), poll once, assert each market chain grew by one entry and every thesis chain grew by one entry.
- **`predict`**: tmpDir kb_root with a thesis manifest, run predict, assert the prediction chain has one entry with the right canonical-JSON payload.
- **`add-market` / `add-thesis`**: tmpDir, run command, parse+validate the produced manifest, assert the chain dirs exist with empty `main.jsonl`s.
- **Reducer auto-trigger**: covered by the poller test above.
- **`confidence_delta_bp`**: extend the existing reducer test — set the threshold to 500 bp, seed two prior reality entries that differ by 4 cents (= 400 bp); the second observation must return `false`.

---

## Deferred to `2026-05-18-kalshi-demo-loop-polish-strategy.md`

- Resolution auto-dispatch (`observeResolution` when Kalshi marks a market settled).
- Dashboard write UI (POST routes + Predict form).
- Daemon mode for the poller (or any built-in scheduler).

These all ride on top of this plan's surface; none of them are required to exercise the prediction loop end-to-end against the demo API.

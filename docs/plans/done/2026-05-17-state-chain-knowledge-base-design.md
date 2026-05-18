# State-Chain Knowledge Base — Design

**Date:** 2026-05-17
**Status:** Design validated; ready for implementation planning.
**Builds on:** `src/state_chain.zig`, `src/txlog.zig`, `src/canonical_json.zig` (all shipped).

---

## Context

The Zig port of every Kalshi endpoint group is complete. The state-chain primitives — Merkle-accumulator chain, JSONL persistence with ULID tx_ids, canonical JSON — are shipped and tested. This document specifies the framework that turns those primitives into a knowledge-base substrate for prediction-market reasoning.

## Goals

1. **Active reasoning substrate.** Live state that informs current trading decisions; hot-path reads must be O(1).
2. **Divergence learning loop.** Compare prediction chains against reality chains; identify the first point where our trajectory decoupled from the market's; feed lessons back into future theses.

Audit and external-consumer feed are not goals of this design. The append-only txlog already provides audit-grade durability; an external feed can layer on later if needed.

## Decision Summary

| Dimension | Decision |
|---|---|
| Chain scope | Per-thesis (hypothesis-level reasoning) |
| Rollup model | Two-layer: per-market chains as substrate, per-thesis chains as projections referencing market heads by hash |
| Write trigger | Event-driven on material change (threshold-based per chain) |
| Rollback model | Git-like branches with hash-addressed parents |
| Number encoding | Integers only (cents, basis points) — no floats in canonical JSON |
| Read API | Zero-copy slices, lifetime-bound to the in-memory `Chain` |
| Rollup dispatch | Compile-time string registry, no dynamic loading |
| Single-writer | `flock(2)` advisory lock per active branch file; fail-fast on contention |

---

## 1. Storage Layout & Branch Topology

The knowledge base lives under `kb/` at the project root, alongside the existing `portfolios/` directory.

```
kb/
  markets/
    KXBTC-26APR10-T100000/
      manifest.json
      prediction/
        main.jsonl
        branches.json
      reality/
        main.jsonl
        branches.json
  theses/
    fed-cuts-june-2026/
      manifest.json
      prediction/
        main.jsonl
        corrected-fed.jsonl
        ablation-no-cpi.jsonl
        branches.json
      reality/
        main.jsonl
        branches.json
```

Each branch is a self-contained JSONL chain in the existing `txlog` format. `branches.json` records `{name, head_hash, parent_hash, parent_branch, created_ts}` for every branch in the chain. A branch's first record carries `prev_hash = parent_hash`, so the global Merkle property holds across branch boundaries.

`main` is the conventional default branch, not a special one. Rollback is `fork(parent_branch, fork_at_hash, new_name)` — copy entries up to the fork point into a new file, then append forward.

Thesis prediction and reality checkpoints embed `sources: {ticker: market_chain_head_hash}`. This makes the two layers verifiable: any thesis checkpoint is replayable as long as the referenced market chains still exist.

## 2. Checkpoint Schema

All four chain types (market reality, market prediction, thesis reality, thesis prediction) share `ts` (Unix milliseconds) and `trigger` (the event that justified the append). All values that hash into the chain are integers — no floats. Confidence is stored as basis points (0–10000); prices as cents.

**Market reality** (substrate, observed):
```json
{"kind":"market.reality","ts":1747507800123,
 "trigger":{"type":"price_delta","prev_yes_bid":54,"prev_yes_ask":55},
 "yes_bid_cents":56,"yes_ask_cents":57,
 "volume":12340,"last_trade_cents":56}
```

**Market prediction** (substrate, belief):
```json
{"kind":"market.prediction","ts":1747507812456,
 "trigger":{"type":"confidence_shift","prev_bp":6000},
 "predicted_yes_cents":65,"confidence_bp":7200,
 "rationale":"3 consecutive prints above 55c; thesis fed-cuts still active"}
```

**Thesis reality** (projection, observed):
```json
{"kind":"thesis.reality","ts":1747507800999,
 "trigger":{"type":"source_delta","market":"KXFED-JUN-CUT"},
 "sources":{"KXFED-JUN-CUT":"0xab12..","KXRECESSION-Q2":"0xcd34.."},
 "rollup_fn":"weighted_avg_v1","aggregate_yes_cents":58}
```

**Thesis prediction** (projection, belief):
```json
{"kind":"thesis.prediction","ts":1747507812789,
 "trigger":{"type":"new_evidence","note":"CPI print"},
 "sources":{"KXFED-JUN-CUT":"0xab12..","KXRECESSION-Q2":"0xcd34.."},
 "rollup_fn":"weighted_avg_v1","confidence_bp":6800,
 "rationale":"CPI surprise weakens cut probability"}
```

### Trigger taxonomy

A closed enum on `trigger.type`:

- `price_delta` — market.reality, observed price moved past threshold
- `new_trade` — market.reality, fill or trade-tape print
- `resolution` — market.reality, terminal event
- `confidence_shift` — any prediction chain, model output crossed threshold
- `new_evidence` — any prediction chain, external information arrived
- `source_delta` — any thesis chain, a referenced market chain advanced
- `manual_decision` — prediction chains, human or agent override

### Why integers everywhere

`canonical_json.zig` hashes whatever `std.json` renders. Float rendering is deterministic within one Zig version but not durable across versions or external tools. Integers eliminate the entire class of "why didn't the hashes match" failure modes. Kalshi already quotes prices in cents; we lose nothing by adopting the same convention internally.

## 3. Read API & Divergence Detection

### Read primitives

```zig
pub fn open(allocator, path, branch: []const u8) !Chain;
pub fn head(self: *const Chain) ?Hash;
pub fn at(self: *const Chain, hash: Hash) ?*const Tx;
pub fn tail(self: *const Chain, n: usize) []const Tx;          // slice into in-memory log
pub fn rangeByHash(self: *const Chain, from: Hash, to: Hash) []const Tx;
pub fn rangeByTime(self: *const Chain, from_ms: u64, to_ms: u64) []const Tx;
pub fn branches(self: *const Chain) []const BranchInfo;
```

Returns are zero-copy slices, lifetime-bound to the `Chain`. Hot-path callers already hold the chain, so this avoids per-read allocations. `head` and `at` are O(1); the others are O(n) in entries returned.

### Divergence — two operators

Both build on the existing `state_chain.Chain.divergesAt` primitive.

```zig
// Live: "is belief still tracking observation?"
pub const TemporalDivergence = struct {
    first_drift_idx: ?usize,
    drift_amount_bp: u32,
    threshold_bp: u32,
};
pub fn temporalDivergence(
    prediction: *const Chain,
    reality: *const Chain,
    threshold_bp: u32,
) TemporalDivergence;

// Post-resolution: "where did we first get it wrong?"
pub const OutcomeDivergence = struct {
    first_wrong_idx: ?usize,
    resolved_yes: bool,
    prediction_at_wrong: u32,
};
pub fn outcomeDivergence(
    prediction: *const Chain,
    resolution_tx: *const Tx,
) OutcomeDivergence;
```

### Alignment under event-driven appends

Prediction and reality chains don't share indices — each has its own trigger conditions. Both operators walk the prediction chain. For each prediction checkpoint, the corresponding reality state is resolved via:

- **Thesis chains:** the embedded `sources` hashes (exact, by-hash anchor).
- **Market chains:** timestamp lookup (`reality.rangeByTime` near the prediction's `ts`).

`state_chain.divergesAt` runs as an O(1) short-circuit when both chains' head hashes match — the no-divergence case stays cheap.

### Why two operators rather than one

Temporal divergence answers a live trading question and runs continuously. Outcome divergence answers a learning question and runs once per resolved thesis. Same primitive underneath, different return shapes, different cadence.

## 4. Write Path & Rollback Operations

### Writer ownership

One writer per chain. Coordination via `flock(2)` on the active branch JSONL — kernel-mediated, multi-process safe, automatically released on process death.

`Chain.openForWrite` calls `flock(fd, LOCK_EX | LOCK_NB)`. Contention surfaces as `error.AlreadyLocked` and the caller fails fast. No queueing, no retry. For a single-operator system, "don't run the CLI against a chain the server is writing" is a workable rule.

### Market chain ingestion

```zig
pub fn observeMarket(allocator, kb_root, ticker, snapshot: MarketSnapshot) !void;
pub fn observeResolution(allocator, kb_root, ticker, resolution) !void;
pub fn observeManual(allocator, kb_root, chain_ref, payload) !void;
```

`observeMarket` is called by `src/kalshi/markets.zig` after orderbook polls or fill events. It loads the chain head, applies the trigger predicate from `kb/markets/<TICKER>/manifest.json` (e.g., `|price_delta| > 1c`), and appends only when the predicate fires. **No predicate firing → no I/O.** Polling stays cheap.

### Rollup registry

Compile-time only. No dynamic loading.

```zig
// src/kb/rollup.zig
pub const RollupFn = *const fn (sources: []const MarketSnapshot) RollupResult;

pub fn register(name: []const u8, f: RollupFn) void;
pub fn lookup(name: []const u8) ?RollupFn;

pub fn registerAll() void {
    register("weighted_avg_v1", &weightedAvgV1);
}
```

Manifests reference rollups by name. Each thesis checkpoint records the rollup name it used, so old checkpoints stay replayable when new rollup variants ship as `_v2`, `_capm_v1`, etc.

After each `observeMarket` write, an in-process reducer scans theses whose `market_set` includes the affected ticker, gathers current market heads, runs the named rollup, and appends to the thesis reality chain if the rollup output crossed its threshold.

### Rollback / fork

```zig
pub fn fork(
    allocator,
    chain_path,
    parent_branch: []const u8,
    fork_at_hash: Hash,
    new_branch_name: []const u8,
) !void;
pub fn switchActive(chain_path, branch_name: []const u8) !void;
```

`fork` copies entries `[0..fork_at_hash]` from the parent branch file into the new branch file, updates `branches.json`, and validates the `prev_hash` chain across the fork point. `switchActive` flips which branch reads default to — a one-line update to `branches.json`, no file moves.

## 5. Durability, Recovery & Codebase Integration

### Durability

Each chain append is three steps:

1. `pwrite` the canonical JSONL line at the file's current EOF.
2. `fdatasync(fd)` before returning.
3. On open-for-write, `TxLog.parseSlice` validates the hash chain from byte zero. A torn final write surfaces as a hash mismatch on the last line and is truncated automatically before the new write proceeds.

`branches.json` is updated via write-temp-then-`rename(2)` — atomic on POSIX. If `branches.json` is missing or corrupt, it regenerates by scanning the chain directory's `*.jsonl` files and reading their head hashes.

The hash chain itself is the recovery primitive. No separate journal.

### Module layout

```
src/kb/
  chain.zig         # Chain wraps txlog.TxLog + branch metadata
  branches.zig      # branches.json parser; fork, switchActive
  ingest.zig        # observeMarket, observeResolution, observeManual + trigger predicates
  rollup.zig        # string registry; weighted_avg_v1
  divergence.zig    # temporalDivergence, outcomeDivergence
  manifest.zig      # market + thesis manifest.json parsers
  testdata/         # canned chain fixtures for inline tests
```

Surface in `src/root.zig`:

```zig
pub const kb = struct {
    pub const chain      = @import("kb/chain.zig");
    pub const branches   = @import("kb/branches.zig");
    pub const ingest     = @import("kb/ingest.zig");
    pub const rollup     = @import("kb/rollup.zig");
    pub const divergence = @import("kb/divergence.zig");
    pub const manifest   = @import("kb/manifest.zig");
};
```

### Wiring into existing code

- `src/kalshi/markets.zig` and `src/kalshi/orders.zig` gain optional `kb.ingest.observeMarket(...)` calls after successful polls or fills. If `kb_root` is not configured, existing behavior is unchanged — no I/O, no chain writes.
- `server/handlers.zig` adds read-only routes: `GET /api/kb/markets/:ticker/head`, `GET /api/kb/theses/:id/divergence`, `GET /api/kb/theses/:id/branches`. The dashboard gains a `kb/` tab.
- New CLI `praescientia-kb` (`tools/kb.zig`): `inspect <chain-path>`, `branches <chain-path>`, `fork <chain> <branch> --at <hash> --to <name>`, `divergence <thesis>`.
- New build target in `build.zig`.

### Test strategy

- Inline tests per module, matching the existing pattern.
- One golden-fixture test under `kb/testdata/` that exercises the full lifecycle: ingest synthetic snapshots → rollup → fork → replay → divergence query. Assert resulting hashes byte-for-byte. This single test catches regressions in canonical JSON, rollup determinism, branch math, or recovery logic.
- Crash-injection test: write half a JSONL line, reopen, confirm clean truncation.

---

## Deferred Questions

These came up during design but were intentionally not resolved here. Revisit during implementation planning or once we have real data.

- **Manifest schema details.** Trigger predicate DSL vs hardcoded fields. Threshold defaults. Stale-market timeouts.
- **Rationale structure.** Currently free-text. May want evidence refs, model name, prompt hash once we have multiple model variants.
- **Observability.** Metrics on append rate, divergence frequency, fork count. Likely a Prometheus-style `/metrics` endpoint on the server.
- **Migration of `portfolios/` data.** Existing runtime data is in a separate format. Decide whether to backfill chains from it or start fresh.
- **Init-time bootstrap.** `praescientia-kb init <thesis-name> --markets=...` — convenience command vs hand-editing manifests.

## Next Steps

1. `superpowers:writing-plans` produces a staged implementation plan from this design.
2. Stage 1 should be the substrate alone: `kb/chain.zig`, `kb/branches.zig`, `kb/manifest.zig`, fork/switchActive, golden-fixture test. No Kalshi wiring yet.
3. Stage 2: `kb/ingest.zig` + market chain integration in `src/kalshi/markets.zig`.
4. Stage 3: `kb/rollup.zig` + thesis layer + in-process reducer.
5. Stage 4: `kb/divergence.zig` + CLI + dashboard routes.

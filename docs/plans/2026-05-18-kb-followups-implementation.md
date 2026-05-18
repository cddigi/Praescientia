# KB Follow-Ups Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Ship the four deferred items from the KB plan — manifest schema validation, `/metrics`, `praescientia-kb init`, and a dashboard KB tab. Companion design at `docs/plans/2026-05-18-kb-followups-design.md`.

**Architecture:** Two new modules (`src/kb/metrics.zig`, hand-rolled validators in `src/kb/manifest.zig`) plus call-site instrumentation in `src/kb/*` and `server/handlers.zig`. The CLI gains an `init` subcommand on `tools/kb.zig`. The dashboard grows two pages inline in `server/dashboard.html`. The `portfolios/` migration is explicitly out of scope per the design doc.

**Tech Stack:** Zig 0.16.0 (pinned). Existing dependencies only. GitButler MCP for commits. Prometheus text exposition format (no client library).

---

## Conventions

### Zig 0.16 reminders (from prior stages — apply mechanically)

| Old | New |
|---|---|
| `std.fs.Dir.makeDir` | `std.Io.Dir.createDir(io, name, .{})` |
| `std.fs.Dir.makePath` | `std.Io.Dir.createDirPath(io, name)` |
| `StringHashMapUnmanaged = .{}` | `StringHashMapUnmanaged = .empty` |
| `chain_mod.openRead(allocator, io, io, io, dir, branch)` | `chain_mod.openRead(allocator, io, dir, branch)` |
| `chain_mod.openForWrite(allocator, io, io, io, dir, branch)` | `chain_mod.openForWrite(allocator, io, dir, branch)` |

Module-level `StringHashMapUnmanaged` must be reset to `.empty` at the start of every test that touches it — `deinit` leaves it in `undefined` state and the next caller crashes.

### TDD cycle per task

1. Write the failing test in the relevant `.zig` file. Inline `test "..."` block referencing the API you're about to build.
2. Run `zig build test --summary all`. Expect a compile error or runtime fail — never a green run before implementation.
3. Implement.
4. Re-run. Expect `All N tests passed.` zero failures.
5. Commit via GitButler.

### Commit via GitButler — never `git commit`

```
Call mcp__gitbutler__gitbutler_update_branches with:
  fullPrompt:            <copy of the task title>
  changesSummary:        <2–4 bullet points: what changed and why>
  currentWorkingDirectory: /Users/lawls/Development/TuesdayCrowd/Praescientia
```

After the first commit on a fresh virtual branch, run `but mark <branch>` so subsequent task hooks land in that branch.

### Editing rules

- One inline test per behavior; reuse `std.testing.allocator`.
- Match existing module style (`//!` doc-comment, `const std = @import("std");`, inline tests at the bottom).
- No floats in any hashed payload field.

### Stage exit gate

At the end of every stage, `zig build test --summary all` must pass with zero failures.

---

## Stage 1 — Manifest Schema Validation

**Deliverable:** `kb.manifest` parsers no longer panic on missing fields. `validateMarket` and `validateThesis` enforce the rule table from §1 of the design.

### Task 1.1 — Replace panicking `.?` in `parseMarket` with `orelse error.MissingX`

**Files:**
- Modify: `src/kb/manifest.zig`

**Step 1: Write a failing test** at the bottom of `src/kb/manifest.zig`:

```zig
test "parseMarket returns MissingTicker when ticker is absent" {
    const json = "{\"kind\":\"market\",\"trigger\":{\"price_delta_cents\":1}}";
    try std.testing.expectError(error.MissingTicker, parseMarket(std.testing.allocator, json));
}

test "parseMarket returns MissingTrigger when trigger is absent" {
    const json = "{\"kind\":\"market\",\"ticker\":\"KXTEST\"}";
    try std.testing.expectError(error.MissingTrigger, parseMarket(std.testing.allocator, json));
}

test "parseMarket returns MissingPriceDelta when trigger.price_delta_cents is absent" {
    const json = "{\"kind\":\"market\",\"ticker\":\"KXTEST\",\"trigger\":{}}";
    try std.testing.expectError(error.MissingPriceDelta, parseMarket(std.testing.allocator, json));
}
```

**Step 2: Run** `zig build test --summary all`. Expect three failures — currently `.?` panics rather than returning a named error.

**Step 3: Implement.** Replace `parseMarket` body's `.?` accesses with `orelse return error.<Name>`:

```zig
pub fn parseMarket(allocator: Allocator, json: []const u8) !MarketManifest {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    const kind = (root.get("kind") orelse return error.MissingKind).string;
    if (!std.mem.eql(u8, kind, "market")) return error.WrongManifestKind;
    const ticker_v = root.get("ticker") orelse return error.MissingTicker;
    const trigger = (root.get("trigger") orelse return error.MissingTrigger).object;
    const pd = trigger.get("price_delta_cents") orelse return error.MissingPriceDelta;
    return .{
        .allocator = allocator,
        .ticker = try allocator.dupe(u8, ticker_v.string),
        .price_delta_cents = @intCast(pd.integer),
    };
}
```

**Step 4: Run** `zig build test --summary all`. Expect green.

**Step 5: Commit.** `fullPrompt`: "Stage 1 Task 1.1 — parseMarket replaces panics with named errors".

---

### Task 1.2 — Same treatment for `parseThesis`

**Files:**
- Modify: `src/kb/manifest.zig`

**Step 1: Add failing tests:**

```zig
test "parseThesis returns MissingId when id is absent" {
    const json =
        \\{"kind":"thesis","description":"x","market_set":["A"],"rollup_fn":"f",
        \\"weights":{"A":10000},"trigger":{"confidence_delta_bp":500}}
    ;
    try std.testing.expectError(error.MissingId, parseThesis(std.testing.allocator, json));
}

test "parseThesis returns MissingMarketSet when market_set is absent" {
    const json =
        \\{"kind":"thesis","id":"t","description":"x","rollup_fn":"f",
        \\"weights":{},"trigger":{"confidence_delta_bp":500}}
    ;
    try std.testing.expectError(error.MissingMarketSet, parseThesis(std.testing.allocator, json));
}

test "parseThesis returns MissingWeights when weights is absent" {
    const json =
        \\{"kind":"thesis","id":"t","description":"x","market_set":["A"],
        \\"rollup_fn":"f","trigger":{"confidence_delta_bp":500}}
    ;
    try std.testing.expectError(error.MissingWeights, parseThesis(std.testing.allocator, json));
}

test "parseThesis returns MissingConfidenceDelta when trigger.confidence_delta_bp is absent" {
    const json =
        \\{"kind":"thesis","id":"t","description":"x","market_set":["A"],
        \\"rollup_fn":"f","weights":{"A":10000},"trigger":{}}
    ;
    try std.testing.expectError(error.MissingConfidenceDelta, parseThesis(std.testing.allocator, json));
}
```

**Step 2: Run** — four new failures.

**Step 3: Implement.** Replace `parseThesis`'s body with the same `orelse return error.<Name>` pattern for every field — `id`, `description`, `market_set`, `rollup_fn`, `weights`, `trigger`, `confidence_delta_bp`. Also handle the per-ticker `weights_obj.get(item.string)` → `error.MissingTickerWeight`.

**Step 4: Run** — green.

**Step 5: Commit.** `fullPrompt`: "Stage 1 Task 1.2 — parseThesis replaces panics with named errors".

---

### Task 1.3 — `validateMarket`

**Files:**
- Modify: `src/kb/manifest.zig`

**Step 1: Failing tests:**

```zig
test "validateMarket accepts a well-formed manifest" {
    const json = "{\"kind\":\"market\",\"ticker\":\"KXBTC-26\",\"trigger\":{\"price_delta_cents\":1}}";
    var m = try parseMarket(std.testing.allocator, json);
    defer m.deinit();
    try validateMarket(&m);
}

test "validateMarket rejects an empty ticker" {
    const json = "{\"kind\":\"market\",\"ticker\":\"\",\"trigger\":{\"price_delta_cents\":1}}";
    var m = try parseMarket(std.testing.allocator, json);
    defer m.deinit();
    try std.testing.expectError(error.TickerLengthOutOfRange, validateMarket(&m));
}

test "validateMarket rejects a ticker with invalid characters" {
    const json = "{\"kind\":\"market\",\"ticker\":\"kx bad\",\"trigger\":{\"price_delta_cents\":1}}";
    var m = try parseMarket(std.testing.allocator, json);
    defer m.deinit();
    try std.testing.expectError(error.TickerHasInvalidChar, validateMarket(&m));
}

test "validateMarket rejects price_delta_cents = 0" {
    const json = "{\"kind\":\"market\",\"ticker\":\"KX\",\"trigger\":{\"price_delta_cents\":0}}";
    var m = try parseMarket(std.testing.allocator, json);
    defer m.deinit();
    try std.testing.expectError(error.PriceDeltaOutOfRange, validateMarket(&m));
}
```

**Step 2: Run** — four failures (function doesn't exist).

**Step 3: Implement** in `src/kb/manifest.zig`:

```zig
pub fn validateMarket(m: *const MarketManifest) !void {
    if (m.ticker.len == 0 or m.ticker.len > 64) return error.TickerLengthOutOfRange;
    for (m.ticker) |c| {
        const ok = (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '-';
        if (!ok) return error.TickerHasInvalidChar;
    }
    if (m.price_delta_cents == 0 or m.price_delta_cents > 100) return error.PriceDeltaOutOfRange;
}
```

**Step 4: Run** — green.

**Step 5: Commit.** `fullPrompt`: "Stage 1 Task 1.3 — validateMarket".

---

### Task 1.4 — `validateThesis`

**Files:**
- Modify: `src/kb/manifest.zig`

**Step 1: Failing tests:**

```zig
test "validateThesis accepts a well-formed manifest" {
    const json =
        \\{"kind":"thesis","id":"fed-cuts","description":"x","market_set":["A","B"],
        \\"rollup_fn":"weighted_avg_v1","weights":{"A":7000,"B":3000},
        \\"trigger":{"confidence_delta_bp":500}}
    ;
    var t = try parseThesis(std.testing.allocator, json);
    defer t.deinit();
    try validateThesis(&t);
}

test "validateThesis rejects weights that don't sum to 10000" {
    const json =
        \\{"kind":"thesis","id":"t","description":"x","market_set":["A","B"],
        \\"rollup_fn":"f","weights":{"A":7000,"B":2000},
        \\"trigger":{"confidence_delta_bp":500}}
    ;
    var t = try parseThesis(std.testing.allocator, json);
    defer t.deinit();
    try std.testing.expectError(error.WeightSumMismatch, validateThesis(&t));
}

test "validateThesis rejects an empty market_set" {
    // parseThesis allows this (length-0 array is valid JSON); validation should reject.
    const json =
        \\{"kind":"thesis","id":"t","description":"x","market_set":[],
        \\"rollup_fn":"f","weights":{},"trigger":{"confidence_delta_bp":500}}
    ;
    var t = try parseThesis(std.testing.allocator, json);
    defer t.deinit();
    try std.testing.expectError(error.EmptyMarketSet, validateThesis(&t));
}

test "validateThesis rejects id with uppercase" {
    const json =
        \\{"kind":"thesis","id":"FED","description":"x","market_set":["A"],
        \\"rollup_fn":"f","weights":{"A":10000},"trigger":{"confidence_delta_bp":500}}
    ;
    var t = try parseThesis(std.testing.allocator, json);
    defer t.deinit();
    try std.testing.expectError(error.ThesisIdInvalid, validateThesis(&t));
}

test "validateThesis rejects confidence_delta_bp = 0" {
    const json =
        \\{"kind":"thesis","id":"t","description":"x","market_set":["A"],
        \\"rollup_fn":"f","weights":{"A":10000},"trigger":{"confidence_delta_bp":0}}
    ;
    var t = try parseThesis(std.testing.allocator, json);
    defer t.deinit();
    try std.testing.expectError(error.ConfidenceDeltaOutOfRange, validateThesis(&t));
}
```

**Step 2: Run** — five failures.

**Step 3: Implement:**

```zig
pub fn validateThesis(t: *const ThesisManifest) !void {
    if (t.id.len == 0 or t.id.len > 64) return error.ThesisIdInvalid;
    for (t.id) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '-';
        if (!ok) return error.ThesisIdInvalid;
    }
    if (t.description.len == 0 or t.description.len > 512) return error.DescriptionLengthOutOfRange;
    if (t.market_set.len == 0) return error.EmptyMarketSet;
    if (t.market_set.len != t.weights_bp.len) return error.WeightSetMismatch;
    var sum: u64 = 0;
    for (t.weights_bp) |w| sum += w;
    if (sum != 10000) return error.WeightSumMismatch;
    if (t.confidence_delta_bp == 0 or t.confidence_delta_bp > 10000) return error.ConfidenceDeltaOutOfRange;
    if (t.rollup_fn.len == 0) return error.MissingRollupFn;
}
```

**Step 4: Run** — green.

**Step 5: Commit.** `fullPrompt`: "Stage 1 Task 1.4 — validateThesis".

---

### Task 1.5 — Wire validation into ingest paths

**Files:**
- Modify: `src/kb/ingest.zig` (both `observeMarket` and `recomputeThesisReality`)

**Step 1: Failing test** in `src/kb/ingest.zig`:

```zig
test "observeMarket rejects an invalid manifest" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.createDirPath(io, "reality");

    // price_delta_cents = 0 is invalid.
    try tmp.dir.writeFile(io, .{
        .sub_path = "manifest.json",
        .data = "{\"kind\":\"market\",\"ticker\":\"KXTEST\",\"trigger\":{\"price_delta_cents\":0}}",
    });
    var reality_dir = try tmp.dir.openDir(io, "reality", .{ .iterate = false });
    defer reality_dir.close(io);
    try reality_dir.writeFile(io, .{ .sub_path = "main.jsonl", .data = "" });
    try reality_dir.writeFile(io, .{
        .sub_path = "branches.json",
        .data =
        \\{"active":"main","branches":[{"name":"main","head_hash":"0000000000000000000000000000000000000000000000000000000000000000","parent_hash":"0000000000000000000000000000000000000000000000000000000000000000","parent_branch":"","created_ts_ms":0}]}
        ,
    });

    try std.testing.expectError(error.PriceDeltaOutOfRange, observeMarket(std.testing.allocator, io, tmp.dir, .{
        .ts_ms = 1, .yes_bid_cents = 50, .yes_ask_cents = 51, .volume = 1, .last_trade_cents = null,
    }));
}
```

**Step 2: Run** — currently `observeMarket` parses the manifest but doesn't validate, so the call should *succeed* and the test fails on the expected error.

**Step 3: Implement.** In `observeMarket`, immediately after `var manifest = try manifest_mod.parseMarket(allocator, manifest_buf);` add `try manifest_mod.validateMarket(&manifest);`. Same in `recomputeThesisReality`: after `parseThesis`, add `try manifest_mod.validateThesis(&manifest);`.

**Step 4: Run** — green.

**Step 5: Commit.** `fullPrompt`: "Stage 1 Task 1.5 — Validate manifests at ingest sites".

**Stage 1 exit gate:** `zig build test --summary all` is green. Every manifest field has a named error; every documented constraint has a test.

---

## Stage 2 — Prometheus `/metrics`

**Deliverable:** `src/kb/metrics.zig` exports atomic counters and a `render(*std.Io.Writer)` function. `GET /metrics` route returns Prometheus exposition. Call sites bump counters on every append, skip, lock contention, and recovery.

### Task 2.1 — `kb.metrics` skeleton with one counter + render

**Files:**
- Create: `src/kb/metrics.zig`
- Modify: `src/root.zig` (add `pub const metrics = @import("kb/metrics.zig");` + `_ = kb.metrics;`)

**Step 1: Write `src/kb/metrics.zig`:**

```zig
//! Prometheus-style counters for the KB substrate. All state is module-level
//! atomic; safe under Io.Threaded. No client library dependency — exposition
//! format is rendered as plain text on demand.

const std = @import("std");

pub const ChainKind = enum {
    market_reality,
    thesis_reality,
    other,

    pub fn label(self: ChainKind) []const u8 {
        return switch (self) {
            .market_reality => "market.reality",
            .thesis_reality => "thesis.reality",
            .other => "other",
        };
    }
};

const ChainKindCount = std.enums.directEnumArrayLen(ChainKind, 0);

pub var chain_appends: [ChainKindCount]std.atomic.Value(u64) = blk: {
    var arr: [ChainKindCount]std.atomic.Value(u64) = undefined;
    for (&arr) |*v| v.* = .{ .raw = 0 };
    break :blk arr;
};

pub fn bumpAppend(kind: ChainKind) void {
    _ = chain_appends[@intFromEnum(kind)].fetchAdd(1, .monotonic);
}

pub fn render(w: *std.Io.Writer) !void {
    try w.writeAll(
        \\# HELP praescientia_kb_chain_appends_total Successful chain appends.
        \\# TYPE praescientia_kb_chain_appends_total counter
        \\
    );
    for (std.enums.values(ChainKind)) |k| {
        const v = chain_appends[@intFromEnum(k)].load(.monotonic);
        try w.print("praescientia_kb_chain_appends_total{{kind=\"{s}\"}} {d}\n", .{ k.label(), v });
    }
}

test "bumpAppend + render produces a parseable line" {
    bumpAppend(.market_reality);
    bumpAppend(.market_reality);
    bumpAppend(.thesis_reality);

    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try render(&aw.writer);
    const out = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, out, "praescientia_kb_chain_appends_total{kind=\"market.reality\"} 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "praescientia_kb_chain_appends_total{kind=\"thesis.reality\"} 1") != null);
}
```

> **Test isolation gotcha:** the counters are module-level; tests across the metrics module share them. Order the test file so the bump+render test runs first, OR add a `resetAll()` helper that the test calls at entry. The plan uses the second approach below.

**Step 2: Run** — passes (this is a bootstrap; the test exercises the API we just wrote).

**Step 3: Add `resetAll()` for tests and call it at the top of every metrics test:**

```zig
pub fn resetAll() void {
    for (&chain_appends) |*v| v.store(0, .monotonic);
}
```

Prepend `resetAll();` to the test body.

**Step 4: Run** — still green.

**Step 5: Commit.** `fullPrompt`: "Stage 2 Task 2.1 — kb.metrics skeleton with chain_appends counter".

---

### Task 2.2 — Bump `chain_appends` from `chain.WriteHandle.append`

**Files:**
- Modify: `src/kb/chain.zig`

**Step 1: Failing test** at the bottom of `src/kb/chain.zig`:

```zig
test "WriteHandle.append bumps kb.metrics.chain_appends" {
    const metrics = @import("metrics.zig");
    metrics.resetAll();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.writeFile(io, .{ .sub_path = "main.jsonl", .data = "" });

    var h = try openForWrite(std.testing.allocator, io, tmp.dir, "main");
    defer h.deinit();
    _ = try h.append("{\"kind\":\"market.reality\",\"ts\":1,\"yes_bid_cents\":50}");

    const v = metrics.chain_appends[@intFromEnum(metrics.ChainKind.market_reality)].load(.monotonic);
    try std.testing.expectEqual(@as(u64, 1), v);
}
```

**Step 2: Run** — counter stays at 0.

**Step 3: Implement.** In `chain.WriteHandle.append`, after `try self.file.sync(self.io) catch …` succeeds (i.e. just before `return tx;`), bump based on the payload's `kind`:

```zig
const metrics = @import("metrics.zig");

// Just before `return tx;` in WriteHandle.append:
const kind = classifyKind(canonical_json);
metrics.bumpAppend(kind);

return tx;
```

And add a private helper at the bottom of the file:

```zig
fn classifyKind(payload: []const u8) @import("metrics.zig").ChainKind {
    const M = @import("metrics.zig");
    // Cheap substring sniff — payloads are canonical JSON, "kind" appears alphabetized.
    if (std.mem.indexOf(u8, payload, "\"kind\":\"market.reality\"") != null) return .market_reality;
    if (std.mem.indexOf(u8, payload, "\"kind\":\"thesis.reality\"") != null) return .thesis_reality;
    return .other;
}
```

**Step 4: Run** — green.

**Step 5: Commit.** `fullPrompt`: "Stage 2 Task 2.2 — Bump chain_appends counter from WriteHandle.append".

---

### Task 2.3 — Add `lock_contention`, `torn_tail`, `observe_skipped` counters

**Files:**
- Modify: `src/kb/metrics.zig`
- Modify: `src/kb/chain.zig` (bump from `openForWrite` on `error.AlreadyLocked` and from `recoverTornTail` on truncate)
- Modify: `src/kb/ingest.zig` (bump `observe_skipped` when `observeMarket` returns false)

**Step 1: Failing test** in `src/kb/metrics.zig`:

```zig
test "render exposes lock_contention and torn_tail" {
    resetAll();
    bumpLockContention();
    bumpLockContention();
    bumpTornTail();
    bumpObserveSkipped(.price_delta_below_threshold);

    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try render(&aw.writer);
    const out = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, out, "praescientia_kb_lock_contention_total 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "praescientia_kb_torn_tail_recovered_total 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "praescientia_kb_observe_skipped_total{reason=\"price_delta_below_threshold\"} 1") != null);
}
```

**Step 2: Run** — `bumpLockContention`, etc. are undefined; compile error.

**Step 3: Extend `src/kb/metrics.zig`:**

```zig
pub const SkipReason = enum {
    price_delta_below_threshold,
    aggregate_unchanged,

    pub fn label(self: SkipReason) []const u8 {
        return switch (self) {
            .price_delta_below_threshold => "price_delta_below_threshold",
            .aggregate_unchanged => "aggregate_unchanged",
        };
    }
};

pub var lock_contention: std.atomic.Value(u64) = .{ .raw = 0 };
pub var torn_tail_recovered: std.atomic.Value(u64) = .{ .raw = 0 };
pub var observe_skipped: [std.enums.directEnumArrayLen(SkipReason, 0)]std.atomic.Value(u64) = blk: {
    var arr: [std.enums.directEnumArrayLen(SkipReason, 0)]std.atomic.Value(u64) = undefined;
    for (&arr) |*v| v.* = .{ .raw = 0 };
    break :blk arr;
};

pub fn bumpLockContention() void { _ = lock_contention.fetchAdd(1, .monotonic); }
pub fn bumpTornTail() void { _ = torn_tail_recovered.fetchAdd(1, .monotonic); }
pub fn bumpObserveSkipped(r: SkipReason) void { _ = observe_skipped[@intFromEnum(r)].fetchAdd(1, .monotonic); }
```

Extend `resetAll` to zero them. Extend `render` to emit them as additional lines.

**Step 4: Run** — passes the metrics test.

**Step 5: Wire bumps in `src/kb/chain.zig`:**

In `openForWrite`, where `error.AlreadyLocked` is returned, add a bump before the return:

```zig
if (!try file.tryLock(io, .exclusive)) {
    @import("metrics.zig").bumpLockContention();
    return error.AlreadyLocked;
}
```

In `recoverTornTail`, bump in both truncation branches (the "no newline → truncate to 0" path and the "valid_len < data.len" path):

```zig
if (last_nl == null) {
    try file.setLength(io, 0);
    @import("metrics.zig").bumpTornTail();
    return;
}
const valid_len = last_nl.? + 1;
if (valid_len < data.len) {
    try file.setLength(io, valid_len);
    @import("metrics.zig").bumpTornTail();
}
```

And in the deeper hash-broken peel branch.

**Step 6: Wire bump in `src/kb/ingest.zig`:**

In `observeMarket`, where it returns `false` because the predicate didn't fire:

```zig
if (!fires) {
    @import("metrics.zig").bumpObserveSkipped(.price_delta_below_threshold);
    return false;
}
```

In `recomputeThesisReality`, where it returns `false` because delta is below 1:

```zig
if (delta < 1) {
    @import("metrics.zig").bumpObserveSkipped(.aggregate_unchanged);
    return false;
}
```

**Step 7: Run** — green.

**Step 8: Commit.** `fullPrompt`: "Stage 2 Task 2.3 — lock_contention + torn_tail + observe_skipped counters".

---

### Task 2.4 — `/metrics` HTTP route + dashboard request counter

**Files:**
- Modify: `server/handlers.zig` (add `/metrics` route + handler, add request counter bump in `handleRequest`-equivalent — but that lives in main.zig)
- Modify: `server/main.zig` (bump `dashboard_requests` per handled route)
- Modify: `src/kb/metrics.zig` (add `dashboard_requests` counter + `kb_root_configured` gauge)

**Step 1: Failing test** in `server/handlers.zig`:

```zig
test "match: /metrics route is wired" {
    var params: [max_path_params][]const u8 = undefined;
    const hit = match(.GET, "/metrics", &params).?;
    try std.testing.expectEqualStrings("/metrics", hit.route.pattern);
}
```

**Step 2: Run** — match returns null, `.?` crashes.

**Step 3: Extend `src/kb/metrics.zig`:**

```zig
/// Bounded route enum so labels are not unbounded strings.
pub const Route = enum {
    dashboard_root,
    kalshi,
    kb,
    metrics,
    unknown,

    pub fn label(self: Route) []const u8 {
        return @tagName(self);
    }
};

pub var dashboard_requests: [std.enums.directEnumArrayLen(Route, 0)]std.atomic.Value(u64) = blk: {
    var arr: [std.enums.directEnumArrayLen(Route, 0)]std.atomic.Value(u64) = undefined;
    for (&arr) |*v| v.* = .{ .raw = 0 };
    break :blk arr;
};

pub var kb_root_configured: std.atomic.Value(u64) = .{ .raw = 0 };

pub fn bumpRequest(r: Route) void { _ = dashboard_requests[@intFromEnum(r)].fetchAdd(1, .monotonic); }
pub fn setKbRootConfigured(yes: bool) void { kb_root_configured.store(if (yes) 1 else 0, .monotonic); }

pub fn classifyPath(path: []const u8) Route {
    if (std.mem.eql(u8, path, "/")) return .dashboard_root;
    if (std.mem.eql(u8, path, "/metrics")) return .metrics;
    if (std.mem.startsWith(u8, path, "/api/kb/")) return .kb;
    if (std.mem.startsWith(u8, path, "/api/kalshi/")) return .kalshi;
    return .unknown;
}
```

Extend `resetAll` and `render` to cover them.

**Step 4: Add `/metrics` route + handler in `server/handlers.zig`:**

Add to the `routes` table (anywhere — it's literal):

```zig
.{ .method = .GET, .pattern = "/metrics", .handler = metricsHandler },
```

Handler:

```zig
fn metricsHandler(ctx: *RequestCtx) !void {
    var body: std.array_list.Managed(u8) = .init(ctx.arena);
    var w = body.writer();
    try kb.metrics.render(&w);
    try ctx.request.respond(body.items, .{
        .status = .ok,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "text/plain; version=0.0.4" },
            .{ .name = "access-control-allow-origin", .value = "*" },
        },
        .keep_alive = true,
    });
}
```

> **Writer gotcha:** `std.array_list.Managed(u8).writer()` returns a writer interface compatible with `*std.Io.Writer`. If the signature mismatches, render's output can also be assembled in `std.Io.Writer.Allocating` and the bytes copied into `body`.

**Step 5: Bump request counter in `server/main.zig`'s `handleRequest`:**

At the top of `handleRequest`, right after extracting `path`:

```zig
@import("praescientia").kb.metrics.bumpRequest(@import("praescientia").kb.metrics.classifyPath(path));
```

**Step 6: Set `kb_root_configured` gauge once in `main`:**

```zig
@import("praescientia").kb.metrics.setKbRootConfigured(kb_root_path != null);
```

**Step 7: Run** `zig build test --summary all` — green.

**Step 8: Hand-smoke:** `./zig-out/bin/praescientia-server --port=18081` in one shell, `curl -s http://localhost:18081/metrics | head -20` in another. Expect the four counter blocks. Send `curl /api/kb/markets/X/head` a few times; `praescientia_dashboard_requests_total{route="kb"}` increments.

**Step 9: Commit.** `fullPrompt`: "Stage 2 Task 2.4 — /metrics endpoint + dashboard request counter".

**Stage 2 exit gate:** `zig build test --summary all` green. `curl /metrics` returns valid Prometheus exposition with all six metric families.

---

## Stage 3 — `praescientia-kb init`

**Deliverable:** `praescientia-kb init <kb_root>` creates a fresh tree. `--with-sample` populates one market + one thesis.

### Task 3.1 — `init` subcommand creates empty `markets/` and `theses/`

**Files:**
- Modify: `tools/kb.zig`

**Step 1: Failing test** — the CLI has no inline tests, so this is an end-to-end shell harness instead. Add a Zig test inside `tools/kb.zig` that exercises the helper directly. First refactor: extract the body of the subcommand into a `initTree(io, root_dir, with_sample) !void` function that the test can call.

```zig
test "initTree creates markets/ and theses/" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try initTree(io, tmp.dir, false);

    try tmp.dir.access(io, "markets", .{});
    try tmp.dir.access(io, "theses", .{});
}
```

> **Note:** `tools/kb.zig` is part of a Stage-4 CLI module; its tests don't run by default with `zig build test`. To wire them in, either (a) add `_ = @import("tools/kb.zig");` to a root test block somewhere reachable, or (b) accept that this test runs only with `zig build test-cli` augmented. The simpler option: move `initTree` into `src/kb/init.zig` as a library function and have the CLI thinly wrap it. **Do this.**

**Step 2: Move the helper.** Create `src/kb/init.zig`:

```zig
//! Bootstrap a fresh kb_root directory tree.

const std = @import("std");

pub fn initTree(io: std.Io, root: std.Io.Dir, with_sample: bool) !void {
    try root.createDir(io, "markets", .{});
    try root.createDir(io, "theses", .{});
    if (with_sample) try writeSamples(io, root);
}

fn writeSamples(io: std.Io, root: std.Io.Dir) !void {
    // SAMPLE market
    try root.createDirPath(io, "markets/SAMPLE/reality");
    try root.writeFile(io, .{
        .sub_path = "markets/SAMPLE/manifest.json",
        .data = "{\"kind\":\"market\",\"ticker\":\"SAMPLE\",\"trigger\":{\"price_delta_cents\":1}}",
    });
    try root.writeFile(io, .{ .sub_path = "markets/SAMPLE/reality/main.jsonl", .data = "" });
    try root.writeFile(io, .{
        .sub_path = "markets/SAMPLE/reality/branches.json",
        .data = "{\"active\":\"main\",\"branches\":[{\"name\":\"main\",\"head_hash\":\"0000000000000000000000000000000000000000000000000000000000000000\",\"parent_hash\":\"0000000000000000000000000000000000000000000000000000000000000000\",\"parent_branch\":\"\",\"created_ts_ms\":0}]}",
    });

    // sample thesis with one source = SAMPLE
    try root.createDirPath(io, "theses/sample/reality");
    try root.createDirPath(io, "theses/sample/prediction");
    try root.writeFile(io, .{
        .sub_path = "theses/sample/manifest.json",
        .data = "{\"kind\":\"thesis\",\"id\":\"sample\",\"description\":\"sample thesis\",\"market_set\":[\"SAMPLE\"],\"rollup_fn\":\"weighted_avg_v1\",\"weights\":{\"SAMPLE\":10000},\"trigger\":{\"confidence_delta_bp\":500}}",
    });
    inline for (.{ "reality", "prediction" }) |sub| {
        try root.writeFile(io, .{ .sub_path = "theses/sample/" ++ sub ++ "/main.jsonl", .data = "" });
        try root.writeFile(io, .{
            .sub_path = "theses/sample/" ++ sub ++ "/branches.json",
            .data = "{\"active\":\"main\",\"branches\":[{\"name\":\"main\",\"head_hash\":\"0000000000000000000000000000000000000000000000000000000000000000\",\"parent_hash\":\"0000000000000000000000000000000000000000000000000000000000000000\",\"parent_branch\":\"\",\"created_ts_ms\":0}]}",
        });
    }
}

test "initTree creates the bare tree" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try initTree(io, tmp.dir, false);
    try tmp.dir.access(io, "markets", .{});
    try tmp.dir.access(io, "theses", .{});
}

test "initTree --with-sample produces parseable manifests" {
    const manifest_mod = @import("manifest.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try initTree(io, tmp.dir, true);

    const market_buf = try tmp.dir.readFileAlloc(io, "markets/SAMPLE/manifest.json", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(market_buf);
    var m = try manifest_mod.parseMarket(std.testing.allocator, market_buf);
    defer m.deinit();
    try manifest_mod.validateMarket(&m);

    const thesis_buf = try tmp.dir.readFileAlloc(io, "theses/sample/manifest.json", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(thesis_buf);
    var t = try manifest_mod.parseThesis(std.testing.allocator, thesis_buf);
    defer t.deinit();
    try manifest_mod.validateThesis(&t);
}
```

**Step 3: Wire** `src/root.zig`: `pub const init = @import("kb/init.zig");` + `_ = kb.init;`.

**Step 4: Run** — green.

**Step 5: Commit.** `fullPrompt`: "Stage 3 Task 3.1 — kb.init.initTree + sample manifests".

---

### Task 3.2 — `praescientia-kb init` subcommand wraps `initTree`

**Files:**
- Modify: `tools/kb.zig`

**Step 1: Manual smoke test** (no inline test here — the smoke step exercises `--help`, which already exits 0 for any registered subcommand).

Add to the subcommand list in `tools/kb.zig`:

```zig
.{ .name = "init", .description = "Bootstrap a fresh kb_root directory tree", .run = cmdInit },
```

And the handler:

```zig
const init_mod = praescientia.kb.init;

fn cmdInit(ctx: *common.Context) !u8 {
    const root_path = ctx.positional(0) orelse {
        try ctx.stderr.print("usage: praescientia-kb init <kb_root> [--with-sample]\n", .{});
        return 2;
    };
    const with_sample = blk: {
        for (ctx.args[1..]) |a| {
            if (std.mem.eql(u8, a, "--with-sample")) break :blk true;
        }
        break :blk false;
    };
    // Make sure kb_root exists before opening it.
    std.Io.Dir.cwd().createDirPath(ctx.io, root_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => {
            try ctx.stderr.print("create {s}: {t}\n", .{ root_path, err });
            return 1;
        },
    };
    var root = try std.Io.Dir.cwd().openDir(ctx.io, root_path, .{ .iterate = false });
    defer root.close(ctx.io);
    init_mod.initTree(ctx.io, root, with_sample) catch |err| {
        try ctx.stderr.print("init failed: {t}\n", .{err});
        return 1;
    };
    try ctx.stdout.print("initialized kb_root at {s}{s}\n", .{ root_path, if (with_sample) " (with sample)" else "" });
    return 0;
}
```

**Step 2: Build** `zig build` — smoke step still passes (`--help` enumerates the new subcommand).

**Step 3: Hand-smoke:**

```bash
tmpkb=$(mktemp -d)/kb
./zig-out/bin/praescientia-kb init "$tmpkb" --with-sample
find "$tmpkb" -type f | sort
# Expect:
# .../kb/markets/SAMPLE/manifest.json
# .../kb/markets/SAMPLE/reality/branches.json
# .../kb/markets/SAMPLE/reality/main.jsonl
# .../kb/theses/sample/manifest.json
# .../kb/theses/sample/prediction/branches.json
# .../kb/theses/sample/prediction/main.jsonl
# .../kb/theses/sample/reality/branches.json
# .../kb/theses/sample/reality/main.jsonl
```

**Step 4: Commit.** `fullPrompt`: "Stage 3 Task 3.2 — praescientia-kb init subcommand".

**Stage 3 exit gate:** `praescientia-kb init` creates a fresh tree; `--with-sample` populates parseable manifests. Test count grew by 2.

---

## Stage 4 — Dashboard KB Tab

**Deliverable:** Two new pages in `server/dashboard.html` ("KB Markets", "KB Theses") that call the existing `/api/kb/*` routes and render the responses inline. One Zig test asserts the markers are present in the embedded HTML.

### Task 4.1 — Add a sidebar section + two empty pages

**Files:**
- Modify: `server/dashboard.html`

**Step 1: Failing test** in `server/handlers.zig`:

```zig
test "dashboard.html exposes the Knowledge Base sidebar markers" {
    try std.testing.expect(std.mem.indexOf(u8, dashboard_html, "data-page=\"kb-markets\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, dashboard_html, "data-page=\"kb-theses\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, dashboard_html, "Knowledge Base") != null);
}
```

**Step 2: Run** — fails (markers absent).

**Step 3: Edit `server/dashboard.html`.** Locate the existing `<nav>` block (look for `<div class="nav-section">Account</div>` or similar) and append a new section above the closing `</nav>`:

```html
<div class="nav-section">Knowledge Base</div>
<a class="nav-item" data-page="kb-markets">
    <span class="nav-icon">&#9650;</span> KB Markets
</a>
<a class="nav-item" data-page="kb-theses">
    <span class="nav-icon">&#9700;</span> KB Theses
</a>
```

Find the existing pattern for page panels (probably `<div class="page" id="page-…">…</div>`) and add two new ones with `id="page-kb-markets"` and `id="page-kb-theses"`, each with a placeholder `<h2>` so the next task has something to flesh out.

**Step 4: Run** — green.

**Step 5: Commit.** `fullPrompt`: "Stage 4 Task 4.1 — Add KB nav section + empty panels".

---

### Task 4.2 — KB Markets panel calls `/api/kb/markets/{ticker}/head`

**Files:**
- Modify: `server/dashboard.html`

**Step 1: Test** — extend the embed test to require a marker that proves the JS calls the endpoint:

```zig
test "dashboard.html has KB markets fetch wired" {
    try std.testing.expect(std.mem.indexOf(u8, dashboard_html, "/api/kb/markets/") != null);
}
```

**Step 2: Run** — fails.

**Step 3: Implement** the panel body inside `<div id="page-kb-markets">`:

```html
<div class="page" id="page-kb-markets">
    <h2>KB Markets</h2>
    <div class="card">
        <label>Ticker
            <input type="text" id="kb-market-ticker" placeholder="KXBTC-26APR10-T100000">
        </label>
        <button id="kb-market-inspect">Inspect</button>
        <pre id="kb-market-out" class="output"></pre>
    </div>
</div>
<script>
document.getElementById('kb-market-inspect').addEventListener('click', async () => {
    const t = document.getElementById('kb-market-ticker').value.trim();
    const out = document.getElementById('kb-market-out');
    if (!t) { out.textContent = 'enter a ticker'; return; }
    try {
        const resp = await fetch(`/api/kb/markets/${encodeURIComponent(t)}/head`);
        out.textContent = JSON.stringify(await resp.json(), null, 2);
    } catch (e) {
        out.textContent = `error: ${e.message}`;
    }
});
</script>
```

> If the existing dashboard has a router for `data-page` clicks, hook the new pages into it. Search for a `showPage(...)` or similar function and add the two new IDs to its registry.

**Step 4: Run** — green.

**Step 5: Hand-smoke:** start the server with `--kb-root=...`, click "KB Markets", enter a known ticker, click Inspect. Expect the same JSON payload that `curl /api/kb/markets/.../head` returns.

**Step 6: Commit.** `fullPrompt`: "Stage 4 Task 4.2 — KB Markets panel inspects head".

---

### Task 4.3 — KB Theses panel: Branches + Divergence

**Files:**
- Modify: `server/dashboard.html`

**Step 1: Test:**

```zig
test "dashboard.html has KB theses fetch wired" {
    try std.testing.expect(std.mem.indexOf(u8, dashboard_html, "/api/kb/theses/") != null);
    try std.testing.expect(std.mem.indexOf(u8, dashboard_html, "/branches") != null);
    try std.testing.expect(std.mem.indexOf(u8, dashboard_html, "/divergence") != null);
}
```

**Step 2: Run** — fails on the new substrings.

**Step 3: Implement** the panel body inside `<div id="page-kb-theses">` mirroring the markets panel: a thesis-id input, two buttons (`Branches`, `Divergence`), an optional `threshold_bp` input for divergence, and an output `<pre>`. Both buttons set `out.textContent` to the pretty-printed JSON response.

**Step 4: Run** — green.

**Step 5: Hand-smoke.**

**Step 6: Commit.** `fullPrompt`: "Stage 4 Task 4.3 — KB Theses panel: Branches + Divergence".

**Stage 4 exit gate:** Dashboard UI exercises every Stage-4 read route. `zig build test --summary all` green.

---

## Stage 5 — Documentation

### Task 5.1 — Document the new surfaces

**Files:**
- Modify: `README.md` — under the existing Knowledge Base section, add `/metrics` to the route table and document `praescientia-kb init [--with-sample]` under CLI Tools.
- Modify: `CLAUDE.md` — add `src/kb/metrics.zig` and `src/kb/init.zig` to the project structure tree; add a row for `/metrics` under server CLI behavior.

**Step 1:** Edit both files. Keep changes terse — one paragraph for /metrics, one CLI usage example for init.

**Step 2: Commit.** `fullPrompt`: "Stage 5 Task 5.1 — Document /metrics + kb init".

**Stage 5 exit gate:** `zig build test --summary all` green. README and CLAUDE.md describe every new surface.

---

## Cross-stage invariants

1. **No floats in hashable payloads.** Counters use `u64`; weights remain basis points.
2. **Single static binary.** Prometheus exposition is rendered in-process; no new dependencies.
3. **Existing tests stay green.** Every `zig build test --summary all` between commits passes.
4. **GitButler-only commits.** Never `git commit`. Always the MCP tool. Run `but mark <branch>` after the first commit on a new virtual branch.
5. **Inline tests only.** No separate `test/` directory.

---

## Deferred (out of scope for this plan)

- `portfolios/` runtime data migration — see design doc §"Decision Summary" (intentionally dropped).
- A second metrics exposition format.
- Auth on `/metrics`.
- A dashboard "fork" UI.
- Real-time chain updates over WebSocket.

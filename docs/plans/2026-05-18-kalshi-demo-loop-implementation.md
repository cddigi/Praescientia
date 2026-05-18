# Kalshi Demo Loop Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Ship the minimum end-to-end loop — poller binary, predict CLI, add-market/add-thesis CLIs, reducer auto-trigger, honored confidence threshold. Companion design at `docs/plans/2026-05-18-kalshi-demo-loop-design.md`.

**Architecture:** New `tools/poll_markets.zig` binary. Three new subcommands on `tools/kb.zig` (`predict`, `add-market`, `add-thesis`). One signature change in `src/kb/ingest.zig` (use manifest threshold). Promote `--kb-root` to a global flag on the kb CLI. No new library modules; all the heavy lifting (`observeMarket`, `recomputeThesisReality`, `observeManual`, `validateMarket`/`Thesis`) is already in place from the KB plan + follow-ups.

**Tech Stack:** Zig 0.16.0. Existing dependencies only. GitButler MCP for commits.

---

## Conventions

### Zig 0.16 reminders (carried from prior plans)

- `Dir.createDir` takes a `Permissions` enum — use `.default_dir`, not `.{}`.
- `Dir.createDirPath` is the recursive variant.
- `chain_mod.openRead` / `openForWrite` are 4-arg: `(allocator, io, dir, branch)`.
- `std.array_list.Managed(u8).writer()` does not compose with `*std.Io.Writer`; use `std.Io.Writer.Allocating` + `aw.written()`.
- Module-level `StringHashMapUnmanaged` must be reset to `.empty` at the start of every test that touches it.

### Test command

`zig build test --summary all`. Should be 137/137 at plan start and grow with each task.

### TDD cycle per task

1. Write the failing test.
2. Run; expect compile error or runtime fail.
3. Implement minimal code.
4. Re-run; expect green.
5. Commit via GitButler.

### Commit via GitButler

After the first commit on a fresh virtual branch run `but mark <branch>`. Use the MCP tool, never `git commit`.

### Editing rules

- One inline test per behavior. Reuse `std.testing.allocator`.
- Canonical-JSON payloads have alphabetically-sorted keys; verify by hand or route through `canonical_json.encodeSlice`.
- No floats in hashed payload fields.

---

## Stage 1 — `praescientia-poll-markets`

**Deliverable:** New CLI binary that iterates `kb_root/markets/`, fetches each market via the Kalshi client, writes through `kbHookMarket`, then iterates `kb_root/theses/` and runs `recomputeThesisReality` for each.

### Task 1.1 — Stub binary + build wiring

**Files:**
- Create: `tools/poll_markets.zig` (skeleton main with `--help` + usage).
- Modify: `build.zig` (append to `stage4_tools` array).

**Step 1:** Write `tools/poll_markets.zig` with a `main(init)` that delegates to `common.runMain` with one no-op subcommand `run` (handler returns 0 after printing "stub: poll-markets"). The smoke-step asserts `--help` exits 0 + prints `Usage:` so the skeleton must wire through `common.zig`.

**Step 2:** Append to `stage4_tools` in `build.zig`:
```zig
.{ .name = "praescientia-poll-markets", .src = "tools/poll_markets.zig", .step = "run-poll-markets" },
```

**Step 3:** Run `zig build test --summary all` — smoke step picks up the new tool automatically; all 138 tests green (existing 137 + the smoke-on-help auto-test).

**Step 4:** Hand-smoke: `./zig-out/bin/praescientia-poll-markets --help` exits 0 with the standard banner.

**Step 5:** Commit. `fullPrompt`: "Stage 1 Task 1.1 — praescientia-poll-markets stub binary".

---

### Task 1.2 — Iterate `kb_root/markets/` and call `kbHookMarket` per ticker

**Files:**
- Modify: `tools/poll_markets.zig`.

**Step 1: Failing test** inside `tools/poll_markets.zig` (move iteration logic into a `pollAll` library-style function so it can be tested without spinning up a real `Client`):

```zig
test "pollAll bumps chain_appends for every market in kb_root" {
    // Stub: a function pollerForTest(io, kb_root, fake_snapshot_fn) that mirrors
    // pollAll but takes a callback in place of the Kalshi client. Build it now;
    // production pollAll wraps it with the real client.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;

    try @import("praescientia").kb.init.initTree(io, tmp.dir, true); // SAMPLE market, sample thesis

    metrics.resetAll();
    try pollerForTest(std.testing.allocator, io, tmp.dir, sampleSnapFn);

    const v = metrics.chain_appends[@intFromEnum(metrics.ChainKind.market_reality)].load(.monotonic);
    try std.testing.expectEqual(@as(u64, 1), v);
}

fn sampleSnapFn(_: []const u8) ingest.MarketSnapshot {
    return .{ .ts_ms = 1, .yes_bid_cents = 50, .yes_ask_cents = 51, .volume = 100, .last_trade_cents = null };
}
```

**Step 2:** Implement `pollerForTest(allocator, io, kb_root_dir, snap_fn)`:

```zig
const SnapFn = *const fn (ticker: []const u8) ingest.MarketSnapshot;

pub fn pollerForTest(allocator: std.mem.Allocator, io: std.Io, kb_root: std.Io.Dir, snap_fn: SnapFn) !void {
    var markets_dir = try kb_root.openDir(io, "markets", .{ .iterate = true });
    defer markets_dir.close(io);
    var it = markets_dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        const snap = snap_fn(entry.name);
        try markets_mod.kbHookMarket(allocator, io, kb_root, entry.name, snap);
    }
}
```

**Step 3:** Run tests; expect green. Commit.

**Step 5:** Commit. `fullPrompt`: "Stage 1 Task 1.2 — pollerForTest iterates kb_root/markets/".

---

### Task 1.3 — Map Kalshi `Market` response to `MarketSnapshot`

**Files:**
- Modify: `tools/poll_markets.zig`.

**Step 1:** Inspect `src/kalshi/markets.zig` for the response shape. The `Market` struct has at least `ticker`, `yes_bid`, `yes_ask`, `volume`, `last_price` (or equivalents — adapt to actual field names). Write a small `toSnapshot(*const kalshi.markets.Market, ts_ms: u64) MarketSnapshot` helper.

**Step 2: Inline test** that constructs a synthetic `Market` and asserts `toSnapshot` produces the right `MarketSnapshot`.

**Step 3:** Implement.

**Step 4:** Run tests; expect green.

**Step 5:** Commit. `fullPrompt`: "Stage 1 Task 1.3 — Market → MarketSnapshot mapper".

---

### Task 1.4 — Production `pollAll` using the real Kalshi client

**Files:**
- Modify: `tools/poll_markets.zig`.

**Step 1:** Build `pollAll(ctx: *common.Context, kb_root: std.Io.Dir)` that wraps `pollerForTest` semantics with the real `ctx.client`:

```zig
pub fn pollAll(ctx: *common.Context, kb_root: std.Io.Dir) !struct { markets: usize, theses: usize, errors: usize } {
    var markets_dir = try kb_root.openDir(ctx.io, "markets", .{ .iterate = true });
    defer markets_dir.close(ctx.io);

    var market_count: usize = 0;
    var error_count: usize = 0;
    var it = markets_dir.iterate();
    while (try it.next(ctx.io)) |entry| {
        if (entry.kind != .directory) continue;
        const ticker = entry.name;
        const market = common.kalshi.markets.get(ctx.client, ctx.arena, ticker) catch |err| {
            try ctx.stderr.print("  ! {s}: fetch failed ({t})\n", .{ ticker, err });
            error_count += 1;
            continue;
        };
        const ts_ms: u64 = @intCast(@divFloor(std.Io.Clock.real.now(ctx.io).nanoseconds, 1_000_000));
        const snap = toSnapshot(&market, ts_ms);
        common.kalshi.markets.kbHookMarket(ctx.gpa, ctx.io, kb_root, ticker, snap) catch |err| {
            try ctx.stderr.print("  ! {s}: kb write failed ({t})\n", .{ ticker, err });
            error_count += 1;
            continue;
        };
        market_count += 1;
    }

    var theses_dir = try kb_root.openDir(ctx.io, "theses", .{ .iterate = true });
    defer theses_dir.close(ctx.io);
    var thesis_count: usize = 0;
    var t_it = theses_dir.iterate();
    while (try t_it.next(ctx.io)) |entry| {
        if (entry.kind != .directory) continue;
        _ = ingest.recomputeThesisReality(ctx.gpa, ctx.io, kb_root, entry.name) catch |err| {
            try ctx.stderr.print("  ! thesis {s}: recompute failed ({t})\n", .{ entry.name, err });
            error_count += 1;
            continue;
        };
        thesis_count += 1;
    }

    return .{ .markets = market_count, .theses = thesis_count, .errors = error_count };
}
```

**Step 2:** Update the subcommand handler to read `--kb-root=PATH`, open the dir, call `pollAll`, print summary. Exit code: 0 if anything succeeded, 1 if every iteration failed.

**Step 3:** Hand-smoke against demo API (requires `.secret/` creds). Use `kb init --with-sample` first.

**Step 4:** Commit. `fullPrompt`: "Stage 1 Task 1.4 — pollAll wires Kalshi client into kb hooks".

**Stage 1 exit gate:** `zig build test --summary all` green. The pollerForTest test exercises the loop end-to-end; production path verified by hand-smoke.

---

## Stage 2 — `kb predict`

### Task 2.1 — `praescientia-kb predict <thesis-id> --confidence-bp=N`

**Files:**
- Modify: `tools/kb.zig` (new subcommand + handler).

**Step 1: Add the subcommand.** Append to the subcommand list and add `cmdPredict`:

```zig
.{ .name = "predict", .description = "Append a thesis prediction (--confidence-bp=N, optional --rationale=)", .run = cmdPredict },
```

```zig
fn cmdPredict(ctx: *common.Context) !u8 {
    const thesis_id = ctx.positional(0) orelse {
        try ctx.stderr.print("usage: praescientia-kb predict <thesis-id> --confidence-bp=N [--rationale=\"...\"]\n", .{});
        return 2;
    };
    const conf_str = ctx.flagValue("--confidence-bp") orelse {
        try ctx.stderr.print("--confidence-bp is required\n", .{});
        return 2;
    };
    const confidence_bp = std.fmt.parseInt(u32, conf_str, 10) catch {
        try ctx.stderr.print("--confidence-bp must be an integer\n", .{});
        return 2;
    };
    if (confidence_bp == 0 or confidence_bp > 10000) {
        try ctx.stderr.print("--confidence-bp must be in [1, 10000]\n", .{});
        return 2;
    }
    const rationale = ctx.flagValue("--rationale") orelse "";

    const kb_root_path = ctx.flagValue("--kb-root") orelse "./kb";
    var kb_root = try std.Io.Dir.cwd().openDir(ctx.io, kb_root_path, .{ .iterate = false });
    defer kb_root.close(ctx.io);

    var thesis_path_buf: [256]u8 = undefined;
    const thesis_path = try std.fmt.bufPrint(&thesis_path_buf, "theses/{s}/prediction", .{thesis_id});
    var prediction_dir = try kb_root.openDir(ctx.io, thesis_path, .{ .iterate = false });
    defer prediction_dir.close(ctx.io);

    const ts_ms: u64 = @intCast(@divFloor(std.Io.Clock.real.now(ctx.io).nanoseconds, 1_000_000));

    var aw: std.Io.Writer.Allocating = .init(ctx.arena);
    defer aw.deinit();
    // Keys alphabetical for canonical-JSON hash stability.
    try aw.writer.print(
        "{{\"confidence_bp\":{d},\"kind\":\"thesis.prediction\",\"rationale\":\"{s}\",\"trigger\":{{\"type\":\"manual_decision\"}},\"ts\":{d}}}",
        .{ confidence_bp, rationale, ts_ms },
    );

    try ingest.observeManual(ctx.gpa, ctx.io, prediction_dir, aw.written());
    try ctx.stdout.print("wrote prediction for thesis '{s}' at confidence={d} bp\n", .{ thesis_id, confidence_bp });
    return 0;
}
```

**Step 2: Inline test** in `tools/kb.zig` (or move predict's core into `src/kb/predict.zig` if the file-iteration test pattern doesn't reach tools — preferred refactor):

Move the canonical-payload construction + `observeManual` call into `src/kb/predict.zig` as `writePrediction(allocator, io, kb_root, thesis_id, confidence_bp, rationale) !void`. The CLI handler becomes a thin parse-args + call wrapper. Test the library function:

```zig
test "writePrediction appends a thesis.prediction payload" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try @import("init.zig").initTree(io, tmp.dir, true);

    try writePrediction(std.testing.allocator, io, tmp.dir, "sample", 7200, "test");

    var pred_dir = try tmp.dir.openDir(io, "theses/sample/prediction", .{ .iterate = false });
    defer pred_dir.close(io);
    var chain = try @import("chain.zig").openRead(std.testing.allocator, io, pred_dir, "main");
    defer chain.deinit();
    try std.testing.expectEqual(@as(usize, 1), chain.len());
    try std.testing.expect(std.mem.indexOf(u8, chain.log.items.items[0].payload, "\"confidence_bp\":7200") != null);
    try std.testing.expect(std.mem.indexOf(u8, chain.log.items.items[0].payload, "\"kind\":\"thesis.prediction\"") != null);
}
```

**Step 3:** Wire `kb.predict` into `src/root.zig`. Run tests; expect green.

**Step 4:** Commit. `fullPrompt`: "Stage 2 Task 2.1 — kb predict subcommand + writePrediction library".

**Stage 2 exit gate:** Predictions can be written from the CLI; chain tests confirm shape.

---

## Stage 3 — `kb add-market` and `kb add-thesis`

### Task 3.1 — `addMarket` library helper + CLI subcommand

**Files:**
- Modify: `src/kb/init.zig` (extract `addMarket(io, root, ticker, price_delta_cents) !void` and have `writeSamples` call it).
- Modify: `tools/kb.zig` (new `add-market` subcommand).

**Step 1: Library test** in `src/kb/init.zig`:

```zig
test "addMarket creates a parseable + valid manifest" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try initTree(io, tmp.dir, false);

    try addMarket(io, tmp.dir, "KXBTC-26", 5);

    const buf = try tmp.dir.readFileAlloc(io, "markets/KXBTC-26/manifest.json", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(buf);
    var m = try @import("manifest.zig").parseMarket(std.testing.allocator, buf);
    defer m.deinit();
    try @import("manifest.zig").validateMarket(&m);
    try std.testing.expectEqual(@as(u32, 5), m.price_delta_cents);
}

test "addMarket refuses to overwrite an existing market" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try initTree(io, tmp.dir, false);
    try addMarket(io, tmp.dir, "KXBTC", 1);
    try std.testing.expectError(error.MarketExists, addMarket(io, tmp.dir, "KXBTC", 2));
}
```

**Step 2: Implement** `addMarket` in `src/kb/init.zig`. It creates `markets/<TICKER>/reality/` (returns `error.MarketExists` if the dir already exists), writes the manifest, writes empty `main.jsonl` + genesis `branches.json`.

**Step 3: CLI subcommand** in `tools/kb.zig`:

```zig
fn cmdAddMarket(ctx: *common.Context) !u8 {
    const ticker = ctx.positional(0) orelse { /* usage */ };
    const pd_str = ctx.flagValue("--price-delta-cents") orelse "1";
    const pd = std.fmt.parseInt(u32, pd_str, 10) catch { /* error */ };

    const kb_root_path = ctx.flagValue("--kb-root") orelse "./kb";
    var kb_root = try std.Io.Dir.cwd().openDir(ctx.io, kb_root_path, .{ .iterate = false });
    defer kb_root.close(ctx.io);
    try init_mod.addMarket(ctx.io, kb_root, ticker, pd);
    try ctx.stdout.print("created markets/{s} (price_delta_cents={d})\n", .{ ticker, pd });
    return 0;
}
```

**Step 4:** Run tests; green.

**Step 5:** Commit. `fullPrompt`: "Stage 3 Task 3.1 — addMarket library + kb add-market CLI".

---

### Task 3.2 — `addThesis` library helper + CLI subcommand

**Files:**
- Modify: `src/kb/init.zig`.
- Modify: `tools/kb.zig`.

**Step 1: Library test:**

```zig
test "addThesis creates a parseable + valid manifest with derived market_set" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try initTree(io, tmp.dir, false);

    try addThesis(std.testing.allocator, io, tmp.dir, .{
        .id = "fed-cuts",
        .description = "Fed cuts in June",
        .rollup_fn = "weighted_avg_v1",
        .weights_json = "{\"KXFED\":7000,\"KXRECESSION\":3000}",
        .confidence_delta_bp = 500,
    });

    const buf = try tmp.dir.readFileAlloc(io, "theses/fed-cuts/manifest.json", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(buf);
    var t = try @import("manifest.zig").parseThesis(std.testing.allocator, buf);
    defer t.deinit();
    try @import("manifest.zig").validateThesis(&t);
    try std.testing.expectEqual(@as(usize, 2), t.market_set.len);
}
```

**Step 2: Implement** `addThesis(allocator, io, root, opts: AddThesisOptions) !void`. It:
- Parses `weights_json` into a `std.json.Value` to extract the (sorted) ticker list.
- Builds the canonical-JSON manifest with `market_set` derived from the weights keys (sorted alphabetically for stability).
- Creates `theses/<id>/reality/` and `theses/<id>/prediction/` with empty `main.jsonl`s + genesis `branches.json`s.
- Returns `error.ThesisExists` if the target dir already exists.

**Step 3: CLI subcommand** mirroring add-market. Required flags: `--description`, `--weights`; optional: `--rollup` (default `weighted_avg_v1`), `--confidence-delta-bp` (default `500`).

**Step 4:** Run tests; green.

**Step 5:** Commit. `fullPrompt`: "Stage 3 Task 3.2 — addThesis library + kb add-thesis CLI".

**Stage 3 exit gate:** Operators can register markets + theses without hand-editing JSON.

---

## Stage 4 — Honor `confidence_delta_bp`

### Task 4.1 — Replace hardcoded 1-cent threshold with manifest-driven bp threshold

**Files:**
- Modify: `src/kb/ingest.zig` (`recomputeThesisReality`).

**Step 1: Failing test** at the bottom of `src/kb/ingest.zig`:

```zig
test "recomputeThesisReality skips when aggregate change is below manifest's confidence_delta_bp" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;

    // Two markets A=60c, B=40c, thesis weights 7000/3000 → first aggregate = 55c.
    // Move B to 38c: new aggregate = 0.7*61 + 0.3*40 = 42.7+12 = 54.7 → 54.
    // Delta = 1 cent = 100 bp. Set confidence_delta_bp=500 → must be skipped.
    inline for (.{ "A", "B" }) |t| {
        try tmp.dir.createDirPath(io, "markets/" ++ t ++ "/reality");
        try tmp.dir.writeFile(io, .{
            .sub_path = "markets/" ++ t ++ "/manifest.json",
            .data = "{\"kind\":\"market\",\"ticker\":\"" ++ t ++ "\",\"trigger\":{\"price_delta_cents\":1}}",
        });
        try tmp.dir.writeFile(io, .{ .sub_path = "markets/" ++ t ++ "/reality/main.jsonl", .data = "" });
        try tmp.dir.writeFile(io, .{
            .sub_path = "markets/" ++ t ++ "/reality/branches.json",
            .data = "{\"active\":\"main\",\"branches\":[{\"name\":\"main\",\"head_hash\":\"0000000000000000000000000000000000000000000000000000000000000000\",\"parent_hash\":\"0000000000000000000000000000000000000000000000000000000000000000\",\"parent_branch\":\"\",\"created_ts_ms\":0}]}",
        });
    }
    // Seed market reality.
    var a_dir = try tmp.dir.openDir(io, "markets/A", .{ .iterate = false });
    defer a_dir.close(io);
    _ = try observeMarket(std.testing.allocator, io, a_dir, .{ .ts_ms = 1, .yes_bid_cents = 60, .yes_ask_cents = 62, .volume = 1, .last_trade_cents = null });
    var b_dir = try tmp.dir.openDir(io, "markets/B", .{ .iterate = false });
    defer b_dir.close(io);
    _ = try observeMarket(std.testing.allocator, io, b_dir, .{ .ts_ms = 1, .yes_bid_cents = 40, .yes_ask_cents = 42, .volume = 1, .last_trade_cents = null });

    // Thesis with 500 bp threshold.
    try tmp.dir.createDirPath(io, "theses/t/reality");
    try tmp.dir.writeFile(io, .{
        .sub_path = "theses/t/manifest.json",
        .data = "{\"kind\":\"thesis\",\"id\":\"t\",\"description\":\"x\",\"market_set\":[\"A\",\"B\"],\"rollup_fn\":\"weighted_avg_v1\",\"weights\":{\"A\":7000,\"B\":3000},\"trigger\":{\"confidence_delta_bp\":500}}",
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "theses/t/reality/main.jsonl", .data = "" });
    try tmp.dir.writeFile(io, .{
        .sub_path = "theses/t/reality/branches.json",
        .data = "{\"active\":\"main\",\"branches\":[{\"name\":\"main\",\"head_hash\":\"0000000000000000000000000000000000000000000000000000000000000000\",\"parent_hash\":\"0000000000000000000000000000000000000000000000000000000000000000\",\"parent_branch\":\"\",\"created_ts_ms\":0}]}",
    });

    rollup_mod.registry = .empty;
    defer rollup_mod.registry.deinit(std.testing.allocator);
    try rollup_mod.registerAll(std.testing.allocator);

    // First call writes the genesis (prev_agg is null).
    try std.testing.expect(try recomputeThesisReality(std.testing.allocator, io, tmp.dir, "t"));

    // Move B from 40 → 38c. Aggregate moves ~1c = 100 bp; below the 500 bp threshold.
    _ = try observeMarket(std.testing.allocator, io, b_dir, .{ .ts_ms = 2, .yes_bid_cents = 38, .yes_ask_cents = 40, .volume = 1, .last_trade_cents = null });
    try std.testing.expect(!(try recomputeThesisReality(std.testing.allocator, io, tmp.dir, "t")));
}
```

**Step 2: Run** — currently passes because the hardcoded `delta < 1` (cents) is *also* satisfied for a 1c delta — wait, no, 1 < 1 is false, so the existing code *would write*. The new check `100 < 500` (bp) returns false. So the test asserts the new behavior. Initially this test fails because the existing code writes.

**Step 3: Implement.** Update `recomputeThesisReality`:

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

**Step 4:** Run tests; green.

**Step 5:** Commit. `fullPrompt`: "Stage 4 Task 4.1 — Honor manifest.confidence_delta_bp in reducer".

**Stage 4 exit gate:** Thesis chain growth respects the operator-configured threshold; metric bump still fires.

---

## Stage 5 — Documentation

### Task 5.1 — End-to-end loop walkthrough

**Files:**
- Modify: `README.md` (add a new "Demo Loop" section under Knowledge Base with the 4-step recipe).
- Modify: `CLAUDE.md` (add `praescientia-poll-markets` to the CLI table; note the `predict`/`add-market`/`add-thesis` subcommands on the KB row).

**Step 1:** Write the walkthrough — five commands, in order:

```bash
zig build run-kb -- init ./kb
zig build run-kb -- add-market KXBTC-26 --price-delta-cents=1 --kb-root=./kb
zig build run-kb -- add-thesis fed-jun \
    --description="Fed cuts in June FOMC" \
    --weights='{"KXBTC-26":10000}' \
    --confidence-delta-bp=500 --kb-root=./kb
zig build run-poll-markets -- --kb-root=./kb
zig build run-kb -- predict fed-jun --confidence-bp=7200 --rationale="initial belief" --kb-root=./kb
zig build run-kb -- divergence ./kb/theses/fed-jun/prediction ./kb/theses/fed-jun/reality --kb-root=./kb
```

**Step 2:** Commit. `fullPrompt`: "Stage 5 Task 5.1 — Document the demo loop".

**Stage 5 exit gate:** A new operator can run the loop from the README alone.

---

## Cross-stage invariants

1. **No floats in hashed payloads.** Predictions store `confidence_bp` as `u32`; thresholds compared in bp.
2. **Single static binary per CLI.** The poller is a new binary alongside the existing 13.
3. **Existing tests stay green.** Every `zig build test --summary all` between commits passes.
4. **GitButler-only commits.** Never `git commit`; always the MCP tool.
5. **Inline tests only.** No separate `test/` directory.

---

## Deferred (out of scope for this plan)

- Resolution auto-dispatch (`observeResolution` from market settlement events).
- Dashboard write UI (POST routes + Predict form).
- Daemon mode for the poller.

All three covered in `2026-05-18-kalshi-demo-loop-polish-strategy.md`.

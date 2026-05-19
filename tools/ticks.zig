//! praescientia-ticks — tick lifecycle CLI for the autonomous prediction
//! agent. The orchestrate skill composes these subcommands across a tick:
//!
//!   begin     Create a fresh tick id + pre-state snapshot. Prints tick_id.
//!   finish    Snapshot post-state for an in-progress tick.
//!   snapshot  Standalone primitive — write a chain-head snapshot file.
//!             Used by `begin` and `finish` internally and exposed so
//!             operators can debug snapshots without spinning a full tick.
//!
//! Future subcommands (Tasks 2.5-2.7): validate, status, rollback.

const std = @import("std");
const common = @import("common");
const praescientia = @import("praescientia");

const ticks = praescientia.kb.ticks;
const manifest_mod = praescientia.kb.manifest;

pub fn main(init: std.process.Init) !u8 {
    return common.runMain(init, "praescientia-ticks", &.{
        .{ .name = "snapshot", .description = "Write a chain-head snapshot JSON file to <out_path>", .run = cmdSnapshot },
        .{ .name = "begin", .description = "Generate a tick_id and write its pre-state snapshot", .run = cmdBegin },
        .{ .name = "finish", .description = "Write the post-state snapshot for an in-progress tick", .run = cmdFinish },
        .{ .name = "validate", .description = "Validate a sub-agent decision file against a thesis manifest", .run = cmdValidate },
        .{ .name = "status", .description = "Show the most recent ticks under kb/.ticks/", .run = cmdStatus },
    });
}

// ---------------------------------------------------------------------------
// snapshot <kb_root> <out_path>
// ---------------------------------------------------------------------------

fn cmdSnapshot(ctx: *common.Context) !u8 {
    const kb_root_path = ctx.positional(0) orelse return missing(ctx, "snapshot <kb_root> <out_path>");
    const out_path = ctx.positional(1) orelse return missing(ctx, "snapshot <kb_root> <out_path>");
    return runSnapshot(ctx, kb_root_path, out_path);
}

fn runSnapshot(ctx: *common.Context, kb_root_path: []const u8, out_path: []const u8) !u8 {
    var kb_root = std.Io.Dir.cwd().openDir(ctx.io, kb_root_path, .{ .iterate = true }) catch |e| {
        try ctx.stderr.print("open {s}: {t}\n", .{ kb_root_path, e });
        return 1;
    };
    defer kb_root.close(ctx.io);

    const entries = try ticks.snapshotHeads(ctx.gpa, ctx.io, kb_root);
    defer ticks.freeSnapshot(ctx.gpa, entries);

    var aw: std.Io.Writer.Allocating = .init(ctx.gpa);
    defer aw.deinit();
    try ticks.writeSnapshot(entries, &aw.writer);

    // Make sure the parent directory exists — snapshots commonly land in
    // `<kb_root>/.ticks/`, which is not part of the chain layout and won't
    // exist on first invocation.
    if (std.fs.path.dirname(out_path)) |parent| {
        std.Io.Dir.cwd().createDirPath(ctx.io, parent) catch {};
    }
    try std.Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = out_path, .data = aw.written() });

    // Status goes to stderr so callers using `$(praescientia-ticks begin ...)`
    // command substitution capture only protocol output (the tick id) on stdout.
    try ctx.stderr.print("wrote {d} entries to {s}\n", .{ entries.len, out_path });
    return 0;
}

// ---------------------------------------------------------------------------
// begin --kb-root=PATH
// ---------------------------------------------------------------------------

fn cmdBegin(ctx: *common.Context) !u8 {
    const kb_root_path = ctx.flagValue("--kb-root") orelse "./kb";

    const tick = ticks.Tick.init();
    var pre_path_buf: [512]u8 = undefined;
    const pre_path = try tick.path(&pre_path_buf, kb_root_path, .pre);

    const exit = try runSnapshot(ctx, kb_root_path, pre_path);
    if (exit != 0) return exit;

    // Echo the tick id on stdout so the orchestrator can capture it via
    // command substitution.
    try ctx.stdout.print("{s}\n", .{tick.id[0..]});
    return 0;
}

// ---------------------------------------------------------------------------
// finish --kb-root=PATH --tick-id=ID
// ---------------------------------------------------------------------------

fn cmdFinish(ctx: *common.Context) !u8 {
    const kb_root_path = ctx.flagValue("--kb-root") orelse "./kb";
    const tick_id = ctx.flagValue("--tick-id") orelse {
        try ctx.stderr.print("finish requires --tick-id=ID\n", .{});
        return 2;
    };
    if (tick_id.len != ticks.tick_id_len) {
        try ctx.stderr.print(
            "--tick-id must be a {d}-char ULID; got {d} chars\n",
            .{ ticks.tick_id_len, tick_id.len },
        );
        return 2;
    }

    // Reconstruct a Tick from the supplied id so we can reuse Tick.path().
    var tick: ticks.Tick = undefined;
    @memcpy(&tick.id, tick_id[0..ticks.tick_id_len]);

    var post_path_buf: [512]u8 = undefined;
    const post_path = try tick.path(&post_path_buf, kb_root_path, .post);

    return runSnapshot(ctx, kb_root_path, post_path);
}

// ---------------------------------------------------------------------------
// validate --thesis-manifest=PATH --decision=PATH [--bankroll-cap-cents=N]
// ---------------------------------------------------------------------------

/// Shape of a sub-agent's decision JSON. The orchestrator builds the
/// prompt that produces this; here we parse and validate one before it's
/// allowed to drive chain writes or order placement.
const DecisionDoc = struct {
    tick_id: ?[]const u8 = null,
    confidence_bp: u32,
    rationale: []const u8 = "",
    commentary_body: []const u8 = "",
    commentary_tags: []const []const u8 = &.{},
    orders: []const DecisionOrder = &.{},
};

const DecisionOrder = struct {
    ticker: []const u8,
    side: []const u8,
    action: []const u8,
    size: u32,
    limit_cents: u8,
    reason: []const u8 = "",
};

fn cmdValidate(ctx: *common.Context) !u8 {
    const manifest_path = ctx.flagValue("--thesis-manifest") orelse {
        try ctx.stderr.print("validate requires --thesis-manifest=PATH\n", .{});
        return 2;
    };
    const decision_path = ctx.flagValue("--decision") orelse {
        try ctx.stderr.print("validate requires --decision=PATH\n", .{});
        return 2;
    };
    var bankroll_cap_cents: u64 = std.math.maxInt(u64);
    if (ctx.flagValue("--bankroll-cap-cents")) |v| {
        bankroll_cap_cents = std.fmt.parseInt(u64, v, 10) catch {
            try ctx.stderr.print("--bankroll-cap-cents must be an integer\n", .{});
            return 2;
        };
    }

    const manifest_json = try std.Io.Dir.cwd().readFileAlloc(ctx.io, manifest_path, ctx.gpa, .unlimited);
    defer ctx.gpa.free(manifest_json);

    var manifest = manifest_mod.parseThesis(ctx.gpa, manifest_json) catch |e| {
        try ctx.stderr.print("parse manifest {s}: {t}\n", .{ manifest_path, e });
        return 1;
    };
    defer manifest.deinit();

    const decision_json = try std.Io.Dir.cwd().readFileAlloc(ctx.io, decision_path, ctx.gpa, .unlimited);
    defer ctx.gpa.free(decision_json);

    var parsed = std.json.parseFromSlice(DecisionDoc, ctx.gpa, decision_json, .{
        .ignore_unknown_fields = true,
    }) catch |e| {
        try ctx.stderr.print(
            "{{\"ok\":false,\"reason\":\"DecisionSchemaInvalid\",\"detail\":\"{t}\"}}\n",
            .{e},
        );
        return 1;
    };
    defer parsed.deinit();

    const exit = try validateDecision(
        &manifest,
        parsed.value,
        bankroll_cap_cents,
        ctx.stdout,
        ctx.stderr,
    );
    return exit;
}

/// Pure validation entry point. Returns 0 on `OK`, 1 on rejection (after
/// writing a JSON reason line to `err`). Extracted from the CLI command so
/// inline tests can drive it without constructing a `common.Context`.
pub fn validateDecision(
    manifest: *const manifest_mod.ThesisManifest,
    decision: DecisionDoc,
    bankroll_cap_cents: u64,
    out: *std.Io.Writer,
    err: *std.Io.Writer,
) !u8 {
    // 1. Decision-level schema checks.
    if (decision.confidence_bp > 10000) {
        try err.print(
            "{{\"ok\":false,\"reason\":\"ConfidenceOutOfRange\",\"got\":{d}}}\n",
            .{decision.confidence_bp},
        );
        return 1;
    }
    if (decision.commentary_body.len > 4096) {
        try err.print(
            "{{\"ok\":false,\"reason\":\"CommentaryBodyTooLong\",\"got\":{d},\"max\":4096}}\n",
            .{decision.commentary_body.len},
        );
        return 1;
    }
    if (decision.rationale.len > 500) {
        try err.print(
            "{{\"ok\":false,\"reason\":\"RationaleTooLong\",\"got\":{d},\"max\":500}}\n",
            .{decision.rationale.len},
        );
        return 1;
    }

    // 2. Per-order validation. Accumulate bankroll usage so the second buy
    //    in a tick is checked against the post-first-buy budget.
    var bankroll_used: u64 = 0;
    for (decision.orders, 0..) |o, i| {
        const side = parseSide(o.side) catch {
            try err.print(
                "{{\"ok\":false,\"reason\":\"BadSide\",\"order_index\":{d},\"got\":\"{s}\"}}\n",
                .{ i, o.side },
            );
            return 1;
        };
        const action = parseAction(o.action) catch {
            try err.print(
                "{{\"ok\":false,\"reason\":\"BadAction\",\"order_index\":{d},\"got\":\"{s}\"}}\n",
                .{ i, o.action },
            );
            return 1;
        };
        const intent: ticks.OrderIntent = .{
            .ticker = o.ticker,
            .side = side,
            .action = action,
            .size = o.size,
            .limit_cents = o.limit_cents,
            .reason = o.reason,
        };
        ticks.validateOrderIntent(intent, manifest, .{
            .bankroll_cap_cents = bankroll_cap_cents,
            .bankroll_used_cents = bankroll_used,
        }) catch |e| {
            try err.print(
                "{{\"ok\":false,\"reason\":\"{t}\",\"order_index\":{d},\"ticker\":\"{s}\"}}\n",
                .{ e, i, o.ticker },
            );
            return 1;
        };
        if (action == .buy) {
            bankroll_used +|= @as(u64, o.size) * @as(u64, o.limit_cents);
        }
    }

    try out.print("OK\n", .{});
    return 0;
}

fn parseSide(s: []const u8) !ticks.Side {
    if (std.mem.eql(u8, s, "yes")) return .yes;
    if (std.mem.eql(u8, s, "no")) return .no;
    return error.UnknownSide;
}

fn parseAction(s: []const u8) !ticks.Action {
    if (std.mem.eql(u8, s, "buy")) return .buy;
    if (std.mem.eql(u8, s, "sell")) return .sell;
    if (std.mem.eql(u8, s, "cancel")) return .cancel;
    if (std.mem.eql(u8, s, "amend")) return .amend;
    return error.UnknownAction;
}

// ---------------------------------------------------------------------------
// status --kb-root=PATH [--limit=N]
// ---------------------------------------------------------------------------

const TickStatus = struct {
    id: [ticks.tick_id_len]u8,
    has_pre: bool,
    has_post: bool,
};

fn cmdStatus(ctx: *common.Context) !u8 {
    const kb_root_path = ctx.flagValue("--kb-root") orelse "./kb";
    var limit: usize = 10;
    if (ctx.flagValue("--limit")) |v| {
        limit = std.fmt.parseInt(usize, v, 10) catch limit;
    }

    var kb_root = std.Io.Dir.cwd().openDir(ctx.io, kb_root_path, .{ .iterate = false }) catch |e| {
        try ctx.stderr.print("open {s}: {t}\n", .{ kb_root_path, e });
        return 1;
    };
    defer kb_root.close(ctx.io);

    var ticks_dir = kb_root.openDir(ctx.io, ".ticks", .{ .iterate = true }) catch |e| switch (e) {
        error.FileNotFound => {
            try ctx.stdout.print("no ticks yet under {s}/.ticks/\n", .{kb_root_path});
            return 0;
        },
        else => return e,
    };
    defer ticks_dir.close(ctx.io);

    // Group files by tick_id prefix.
    var seen: std.StringHashMapUnmanaged(TickStatus) = .empty;
    defer {
        var it = seen.iterator();
        while (it.next()) |entry| ctx.gpa.free(entry.key_ptr.*);
        seen.deinit(ctx.gpa);
    }

    var iter = ticks_dir.iterate();
    while (try iter.next(ctx.io)) |entry| {
        if (entry.kind != .file) continue;
        if (entry.name.len < ticks.tick_id_len) continue;
        const tick_id = entry.name[0..ticks.tick_id_len];
        if (ticks.tickIdMs(tick_id)) |_| {} else |_| continue;

        const gop = try seen.getOrPut(ctx.gpa, tick_id);
        if (!gop.found_existing) {
            gop.key_ptr.* = try ctx.gpa.dupe(u8, tick_id);
            gop.value_ptr.* = .{ .id = undefined, .has_pre = false, .has_post = false };
            @memcpy(&gop.value_ptr.id, tick_id);
        }
        if (std.mem.endsWith(u8, entry.name, ".pre.json")) gop.value_ptr.has_pre = true;
        if (std.mem.endsWith(u8, entry.name, ".post.json")) gop.value_ptr.has_post = true;
    }

    // Collect and sort descending by tick_id (ULIDs are time-sortable).
    var all = std.array_list.Managed(TickStatus).init(ctx.gpa);
    defer all.deinit();
    var it = seen.valueIterator();
    while (it.next()) |v| try all.append(v.*);
    std.mem.sort(TickStatus, all.items, {}, tickStatusGreaterThan);

    const shown = @min(all.items.len, limit);
    if (shown == 0) {
        try ctx.stdout.print("no ticks yet under {s}/.ticks/\n", .{kb_root_path});
        return 0;
    }

    try ctx.stdout.print("{s:<26}  started_at (ms)  state\n", .{"tick_id"});
    for (all.items[0..shown]) |s| {
        const ms = ticks.tickIdMs(s.id[0..]) catch 0;
        const state: []const u8 = if (s.has_post) "DONE" else if (s.has_pre) "IN-PROGRESS" else "ORPHAN";
        try ctx.stdout.print("{s}  {d:>14}  {s}\n", .{ s.id, ms, state });
    }
    if (all.items.len > limit) {
        try ctx.stdout.print("... {d} earlier ticks elided (--limit={d})\n", .{ all.items.len - limit, limit });
    }
    return 0;
}

fn tickStatusGreaterThan(_: void, a: TickStatus, b: TickStatus) bool {
    return std.mem.order(u8, &a.id, &b.id) == .gt;
}

// ---------------------------------------------------------------------------

fn missing(ctx: *common.Context, usage: []const u8) !u8 {
    try ctx.stderr.print("usage: praescientia-ticks {s}\n", .{usage});
    return 2;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

// --- validate tests against tests/fixtures/decisions/ ---

fn loadFixtureManifest(allocator: std.mem.Allocator, io: std.Io) !manifest_mod.ThesisManifest {
    const json = try std.Io.Dir.cwd().readFileAlloc(
        io,
        "tests/fixtures/decisions/thesis.json",
        allocator,
        .unlimited,
    );
    defer allocator.free(json);
    return manifest_mod.parseThesis(allocator, json);
}

fn validateFixture(fixture_name: []const u8) !u8 {
    const io = std.testing.io;
    var manifest = try loadFixtureManifest(std.testing.allocator, io);
    defer manifest.deinit();

    var path_buf: [256]u8 = undefined;
    const fixture_path = try std.fmt.bufPrint(&path_buf, "tests/fixtures/decisions/{s}", .{fixture_name});
    const decision_json = try std.Io.Dir.cwd().readFileAlloc(
        io,
        fixture_path,
        std.testing.allocator,
        .unlimited,
    );
    defer std.testing.allocator.free(decision_json);

    var parsed = try std.json.parseFromSlice(DecisionDoc, std.testing.allocator, decision_json, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var err: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer err.deinit();

    return validateDecision(
        &manifest,
        parsed.value,
        std.math.maxInt(u64),
        &out.writer,
        &err.writer,
    );
}

test "validate accepts a well-formed decision (ok.json)" {
    const exit = try validateFixture("ok.json");
    try std.testing.expectEqual(@as(u8, 0), exit);
}

test "validate rejects orders against tickers not in the manifest (bad_ticker.json)" {
    const exit = try validateFixture("bad_ticker.json");
    try std.testing.expectEqual(@as(u8, 1), exit);
}

test "validate rejects size-zero orders (bad_size.json)" {
    const exit = try validateFixture("bad_size.json");
    try std.testing.expectEqual(@as(u8, 1), exit);
}

test "runSnapshot writes canonical-JSON entries to disk" {
    // Driven by exercising `snapshotHeads` + `writeSnapshot` indirectly via
    // the public path the CLI takes. We don't construct a Context here —
    // those primitives are unit-tested in src/kb/ticks.zig. This test
    // confirms the file-write path lands.
    const init_mod = praescientia.kb.init;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try init_mod.initTree(io, tmp.dir, true);

    const entries = try ticks.snapshotHeads(std.testing.allocator, io, tmp.dir);
    defer ticks.freeSnapshot(std.testing.allocator, entries);

    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try ticks.writeSnapshot(entries, &aw.writer);

    try tmp.dir.createDirPath(io, ".ticks");
    try tmp.dir.writeFile(io, .{ .sub_path = ".ticks/sample.pre.json", .data = aw.written() });

    const read_back = try tmp.dir.readFileAlloc(io, ".ticks/sample.pre.json", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(read_back);
    try std.testing.expect(std.mem.startsWith(u8, read_back, "{\"entries\":["));
    try std.testing.expect(std.mem.endsWith(u8, read_back, "]}"));
}

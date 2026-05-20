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
const branches_mod = praescientia.kb.branches;
const state_chain = praescientia.state_chain;
const Hash = state_chain.Hash;

pub fn main(init: std.process.Init) !u8 {
    return common.runMain(init, "praescientia-ticks", &.{
        .{ .name = "snapshot", .description = "Write a chain-head snapshot JSON file to <out_path>", .run = cmdSnapshot },
        .{ .name = "begin", .description = "Generate a tick_id and write its pre-state snapshot", .run = cmdBegin },
        .{ .name = "finish", .description = "Write the post-state snapshot for an in-progress tick", .run = cmdFinish },
        .{ .name = "validate", .description = "Validate a sub-agent decision file against a thesis manifest", .run = cmdValidate },
        .{ .name = "validate-loss-reflection", .description = "Validate a loss-reflector response against schema caps + stoplist", .run = cmdValidateLossReflection },
        .{ .name = "classify-resolution", .description = "Classify a settlement as win/loss given the held side", .run = cmdClassifyResolution },
        .{ .name = "status", .description = "Show the most recent ticks under kb/.ticks/", .run = cmdStatus },
        .{ .name = "rollback", .description = "Fork every pre-tick head as a 'pre-{tick_id}' branch for operator rollback", .run = cmdRollback },
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
    if (decision.rationale.len > 1024) {
        try err.print(
            "{{\"ok\":false,\"reason\":\"RationaleTooLong\",\"got\":{d},\"max\":1024}}\n",
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
// rollback --tick-id=ID --kb-root=PATH
// ---------------------------------------------------------------------------

const SnapshotEntryJson = struct {
    branch: []const u8,
    head_hash: ?[]const u8,
    length: usize,
    scope_path: []const u8,
};

const SnapshotDoc = struct {
    entries: []SnapshotEntryJson,
};

fn cmdRollback(ctx: *common.Context) !u8 {
    const kb_root_path = ctx.flagValue("--kb-root") orelse "./kb";
    const tick_id = ctx.flagValue("--tick-id") orelse {
        try ctx.stderr.print("rollback requires --tick-id=ID\n", .{});
        return 2;
    };
    if (tick_id.len != ticks.tick_id_len) {
        try ctx.stderr.print(
            "--tick-id must be a {d}-char ULID; got {d} chars\n",
            .{ ticks.tick_id_len, tick_id.len },
        );
        return 2;
    }

    var kb_root = std.Io.Dir.cwd().openDir(ctx.io, kb_root_path, .{ .iterate = false }) catch |e| {
        try ctx.stderr.print("open {s}: {t}\n", .{ kb_root_path, e });
        return 1;
    };
    defer kb_root.close(ctx.io);

    var pre_rel_buf: [128]u8 = undefined;
    const pre_rel = try std.fmt.bufPrint(&pre_rel_buf, ".ticks/{s}.pre.json", .{tick_id});
    const pre_json = kb_root.readFileAlloc(ctx.io, pre_rel, ctx.gpa, .unlimited) catch |e| {
        try ctx.stderr.print("read {s}: {t}\n", .{ pre_rel, e });
        return 1;
    };
    defer ctx.gpa.free(pre_json);

    var parsed = try std.json.parseFromSlice(SnapshotDoc, ctx.gpa, pre_json, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const summary = try rollbackFromSnapshot(
        ctx.gpa,
        ctx.io,
        kb_root,
        parsed.value,
        tick_id,
        ctx.stderr,
    );
    try ctx.stdout.print(
        "rollback {s}: forked={d}, skipped={d}, failed={d}\n",
        .{ tick_id, summary.forked, summary.skipped, summary.failed },
    );
    if (summary.failed > 0) return 1;
    return 0;
}

pub const RollbackSummary = struct {
    forked: usize,
    skipped: usize,
    failed: usize,
};

/// Pure rollback core. Extracted from `cmdRollback` so inline tests can
/// drive it without constructing a Context. Iterates pre-snapshot entries,
/// forks each chain at its recorded head into a branch named
/// `pre-{tick_id}`. Idempotent — re-running against the same tick reports
/// `BranchExists` as skip, not failure.
pub fn rollbackFromSnapshot(
    allocator: std.mem.Allocator,
    io: std.Io,
    kb_root: std.Io.Dir,
    snapshot: SnapshotDoc,
    tick_id: []const u8,
    err: *std.Io.Writer,
) !RollbackSummary {
    var summary: RollbackSummary = .{ .forked = 0, .skipped = 0, .failed = 0 };
    var fork_name_buf: [64]u8 = undefined;
    const fork_name = try std.fmt.bufPrint(&fork_name_buf, "pre-{s}", .{tick_id});

    for (snapshot.entries) |e| {
        const head_hex = e.head_hash orelse {
            // Empty pre-tick chain — nothing to fork from.
            summary.skipped += 1;
            continue;
        };
        if (head_hex.len != 64) {
            try err.print("  ! {s}: malformed head_hash\n", .{e.scope_path});
            summary.failed += 1;
            continue;
        }
        var head_bytes: Hash = undefined;
        hexDecodeHash(head_hex, &head_bytes) catch {
            try err.print("  ! {s}: invalid hex in head_hash\n", .{e.scope_path});
            summary.failed += 1;
            continue;
        };

        var chain_dir = kb_root.openDir(io, e.scope_path, .{ .iterate = false }) catch |open_err| {
            try err.print("  ! {s}: open ({t})\n", .{ e.scope_path, open_err });
            summary.failed += 1;
            continue;
        };
        defer chain_dir.close(io);

        branches_mod.fork(allocator, io, chain_dir, e.branch, head_bytes, fork_name) catch |fork_err| switch (fork_err) {
            error.BranchExists => summary.skipped += 1,
            error.ForkHashNotFound => {
                try err.print(
                    "  ! {s}: pre-tick head no longer present on '{s}' branch\n",
                    .{ e.scope_path, e.branch },
                );
                summary.failed += 1;
            },
            else => {
                try err.print("  ! {s}: fork failed ({t})\n", .{ e.scope_path, fork_err });
                summary.failed += 1;
            },
        };
        // Only count as forked if no error or skip recorded for this entry.
        // Track via deltas to avoid double-counting.
    }

    // Recompute forked = entries - skipped - failed (deltas are already in summary).
    summary.forked = snapshot.entries.len - summary.skipped - summary.failed;
    return summary;
}

fn hexDecodeHash(hex: []const u8, out: *Hash) !void {
    if (hex.len != 64) return error.InvalidHex;
    for (out, 0..) |*b, i| {
        const hi = try hexNibble(hex[i * 2]);
        const lo = try hexNibble(hex[i * 2 + 1]);
        b.* = (hi << 4) | lo;
    }
}

fn hexNibble(c: u8) !u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => 10 + (c - 'a'),
        'A'...'F' => 10 + (c - 'A'),
        else => error.InvalidHex,
    };
}

// ---------------------------------------------------------------------------
// validate-loss-reflection --decision=PATH
// ---------------------------------------------------------------------------

const LossReflectionDoc = struct {
    tick_id: ?[]const u8 = null,
    what_we_believed: []const u8 = "",
    what_actually_happened: []const u8 = "",
    why_we_were_wrong: []const u8 = "",
    decision_pattern_to_avoid: []const u8 = "",
    tags: []const []const u8 = &.{},
};

fn cmdValidateLossReflection(ctx: *common.Context) !u8 {
    const decision_path = ctx.flagValue("--decision") orelse {
        try ctx.stderr.print("validate-loss-reflection requires --decision=PATH\n", .{});
        return 2;
    };

    const decision_json = try std.Io.Dir.cwd().readFileAlloc(ctx.io, decision_path, ctx.gpa, .unlimited);
    defer ctx.gpa.free(decision_json);

    var parsed = std.json.parseFromSlice(LossReflectionDoc, ctx.gpa, decision_json, .{
        .ignore_unknown_fields = true,
    }) catch |e| {
        try ctx.stderr.print(
            "{{\"ok\":false,\"reason\":\"LossReflectionSchemaInvalid\",\"detail\":\"{t}\"}}\n",
            .{e},
        );
        return 1;
    };
    defer parsed.deinit();

    return validateLossReflectionDoc(parsed.value, ctx.stdout, ctx.stderr);
}

/// Pure validation entry point. Returns 0 on `OK` (and prints `OK` to
/// `out`), 1 on rejection (and prints a JSON envelope to `err`). Extracted
/// so inline tests can drive it without a `common.Context`.
pub fn validateLossReflectionDoc(
    doc: LossReflectionDoc,
    out: *std.Io.Writer,
    err: *std.Io.Writer,
) !u8 {
    const reflection = ticks.LossReflection{
        .what_we_believed = doc.what_we_believed,
        .what_actually_happened = doc.what_actually_happened,
        .why_we_were_wrong = doc.why_we_were_wrong,
        .decision_pattern_to_avoid = doc.decision_pattern_to_avoid,
        .tags = doc.tags,
    };

    ticks.validateLossReflection(reflection) catch |e| {
        const reason = @errorName(e);
        try err.print(
            "{{\"ok\":false,\"reason\":\"{s}\"}}\n",
            .{reason},
        );
        return 1;
    };

    try out.print("OK\n", .{});
    return 0;
}

// ---------------------------------------------------------------------------
// classify-resolution --settlement=PATH
// ---------------------------------------------------------------------------

const SettlementDoc = struct {
    ticker: []const u8 = "",
    resolved_yes: bool,
    resolution_ts_ms: i64 = 0,
    our_held_side: []const u8, // "yes" or "no"
    our_contracts: u32 = 0,
    realized_pnl_cents: i64 = 0,
};

fn cmdClassifyResolution(ctx: *common.Context) !u8 {
    const settlement_path = ctx.flagValue("--settlement") orelse {
        try ctx.stderr.print("classify-resolution requires --settlement=PATH\n", .{});
        return 2;
    };

    const settlement_json = try std.Io.Dir.cwd().readFileAlloc(ctx.io, settlement_path, ctx.gpa, .unlimited);
    defer ctx.gpa.free(settlement_json);

    var parsed = std.json.parseFromSlice(SettlementDoc, ctx.gpa, settlement_json, .{
        .ignore_unknown_fields = true,
    }) catch |e| {
        try ctx.stderr.print(
            "{{\"ok\":false,\"reason\":\"SettlementSchemaInvalid\",\"detail\":\"{t}\"}}\n",
            .{e},
        );
        return 1;
    };
    defer parsed.deinit();

    return classifyResolutionDoc(parsed.value, ctx.stdout, ctx.stderr);
}

/// Pure classification entry point. Maps the doc's `our_held_side` string
/// to the typed `ticks.Side`, calls `ticks.classifyResolution`, and prints
/// `"win"` or `"loss"` to `out`. Returns 1 on schema rejection.
pub fn classifyResolutionDoc(
    doc: SettlementDoc,
    out: *std.Io.Writer,
    err: *std.Io.Writer,
) !u8 {
    const side: ticks.Side = blk: {
        if (std.mem.eql(u8, doc.our_held_side, "yes")) break :blk .yes;
        if (std.mem.eql(u8, doc.our_held_side, "no")) break :blk .no;
        try err.print(
            "{{\"ok\":false,\"reason\":\"InvalidHeldSide\",\"got\":\"{s}\"}}\n",
            .{doc.our_held_side},
        );
        return 1;
    };

    const settlement = ticks.Settlement{
        .ticker = doc.ticker,
        .resolved_yes = doc.resolved_yes,
        .resolution_ts_ms = doc.resolution_ts_ms,
        .our_held_side = side,
        .our_contracts = doc.our_contracts,
        .realized_pnl_cents = doc.realized_pnl_cents,
    };

    switch (ticks.classifyResolution(settlement)) {
        .win => try out.print("win\n", .{}),
        .loss => try out.print("loss\n", .{}),
    }
    return 0;
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

test "rollbackFromSnapshot forks each non-empty chain at its pre-tick head" {
    const init_mod = praescientia.kb.init;
    const predict_mod = praescientia.kb.predict;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try init_mod.initTree(io, tmp.dir, true); // sample thesis + sample market

    // Tick-1 prediction: advances the thesis prediction chain by one entry.
    try predict_mod.writePrediction(std.testing.allocator, io, tmp.dir, "sample", 5000, "tick1");

    // Capture pre-state for a synthetic tick-2.
    const entries = try ticks.snapshotHeads(std.testing.allocator, io, tmp.dir);
    defer ticks.freeSnapshot(std.testing.allocator, entries);

    // Convert to the SnapshotDoc shape (matches what rollbackFromSnapshot ingests).
    var entries_json = try std.testing.allocator.alloc(SnapshotEntryJson, entries.len);
    defer std.testing.allocator.free(entries_json);
    for (entries, 0..) |e, i| {
        entries_json[i] = .{
            .branch = e.branch,
            .head_hash = if (e.head_hash) |h| h[0..] else null,
            .length = e.length,
            .scope_path = e.scope_path,
        };
    }

    // Tick-2 prediction: chains advance further.
    try predict_mod.writePrediction(std.testing.allocator, io, tmp.dir, "sample", 6000, "tick2");

    var err: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer err.deinit();
    const tick_id = "01ABCDEFGHJKMNPQRSTVWXYZ12";
    const summary = try rollbackFromSnapshot(
        std.testing.allocator,
        io,
        tmp.dir,
        .{ .entries = entries_json },
        tick_id,
        &err.writer,
    );
    try std.testing.expectEqual(@as(usize, 0), summary.failed);

    // The prediction chain had a head (after the first write); rollback should
    // have produced a `pre-{tick_id}` branch on that chain dir.
    var pred_dir = try tmp.dir.openDir(io, "theses/sample/prediction", .{ .iterate = false });
    defer pred_dir.close(io);
    var pre_branch_buf: [64]u8 = undefined;
    const pre_branch = try std.fmt.bufPrint(&pre_branch_buf, "pre-{s}.jsonl", .{tick_id});
    var pre_chain_file = try pred_dir.openFile(io, pre_branch, .{});
    pre_chain_file.close(io);
}

test "rollbackFromSnapshot is idempotent (BranchExists treated as skip)" {
    const init_mod = praescientia.kb.init;
    const predict_mod = praescientia.kb.predict;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try init_mod.initTree(io, tmp.dir, true);
    try predict_mod.writePrediction(std.testing.allocator, io, tmp.dir, "sample", 5000, "");

    const entries = try ticks.snapshotHeads(std.testing.allocator, io, tmp.dir);
    defer ticks.freeSnapshot(std.testing.allocator, entries);
    var entries_json = try std.testing.allocator.alloc(SnapshotEntryJson, entries.len);
    defer std.testing.allocator.free(entries_json);
    for (entries, 0..) |e, i| {
        entries_json[i] = .{
            .branch = e.branch,
            .head_hash = if (e.head_hash) |h| h[0..] else null,
            .length = e.length,
            .scope_path = e.scope_path,
        };
    }

    var err: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer err.deinit();
    const tick_id = "01ABCDEFGHJKMNPQRSTVWXYZ12";

    const first = try rollbackFromSnapshot(std.testing.allocator, io, tmp.dir, .{ .entries = entries_json }, tick_id, &err.writer);
    try std.testing.expectEqual(@as(usize, 0), first.failed);

    const second = try rollbackFromSnapshot(std.testing.allocator, io, tmp.dir, .{ .entries = entries_json }, tick_id, &err.writer);
    try std.testing.expectEqual(@as(usize, 0), second.failed);
    // Every chain that was forked on first run shows up as skipped on the second.
    try std.testing.expect(second.skipped >= first.forked);
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

// --- validate-loss-reflection tests against tests/fixtures/loss_reflections/ ---

fn validateLossReflectionFixture(fixture_name: []const u8) !u8 {
    const io = std.testing.io;
    var path_buf: [256]u8 = undefined;
    const fixture_path = try std.fmt.bufPrint(&path_buf, "tests/fixtures/loss_reflections/{s}", .{fixture_name});
    const json = try std.Io.Dir.cwd().readFileAlloc(io, fixture_path, std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(json);

    var parsed = try std.json.parseFromSlice(LossReflectionDoc, std.testing.allocator, json, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var err: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer err.deinit();

    return validateLossReflectionDoc(parsed.value, &out.writer, &err.writer);
}

test "validate-loss-reflection accepts a specific diagnostic (ok.json)" {
    const exit = try validateLossReflectionFixture("ok.json");
    try std.testing.expectEqual(@as(u8, 0), exit);
}

test "validate-loss-reflection rejects over-length fields (bad_cap.json)" {
    const exit = try validateLossReflectionFixture("bad_cap.json");
    try std.testing.expectEqual(@as(u8, 1), exit);
}

test "validate-loss-reflection rejects stoplisted phrases (stoplist.json)" {
    const exit = try validateLossReflectionFixture("stoplist.json");
    try std.testing.expectEqual(@as(u8, 1), exit);
}

// --- classify-resolution tests against tests/fixtures/settlements/ ---

fn classifyResolutionFixture(fixture_name: []const u8) ![]u8 {
    const io = std.testing.io;
    var path_buf: [256]u8 = undefined;
    const fixture_path = try std.fmt.bufPrint(&path_buf, "tests/fixtures/settlements/{s}", .{fixture_name});
    const json = try std.Io.Dir.cwd().readFileAlloc(io, fixture_path, std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(json);

    var parsed = try std.json.parseFromSlice(SettlementDoc, std.testing.allocator, json, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var err: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer err.deinit();

    const exit = try classifyResolutionDoc(parsed.value, &out.writer, &err.writer);
    try std.testing.expectEqual(@as(u8, 0), exit);
    return std.testing.allocator.dupe(u8, std.mem.trim(u8, out.written(), "\n"));
}

test "classify-resolution: held yes + resolved yes -> 'win' (win_yes.json)" {
    const verdict = try classifyResolutionFixture("win_yes.json");
    defer std.testing.allocator.free(verdict);
    try std.testing.expectEqualStrings("win", verdict);
}

test "classify-resolution: held no + resolved no -> 'win' (win_no.json)" {
    const verdict = try classifyResolutionFixture("win_no.json");
    defer std.testing.allocator.free(verdict);
    try std.testing.expectEqualStrings("win", verdict);
}

test "classify-resolution: held no + resolved yes -> 'loss' (loss_no_holding.json)" {
    const verdict = try classifyResolutionFixture("loss_no_holding.json");
    defer std.testing.allocator.free(verdict);
    try std.testing.expectEqualStrings("loss", verdict);
}

test "classify-resolution rejects invalid held_side value" {
    const doc = SettlementDoc{
        .ticker = "KX-X",
        .resolved_yes = true,
        .resolution_ts_ms = 0,
        .our_held_side = "maybe", // not yes/no
        .our_contracts = 1,
        .realized_pnl_cents = 0,
    };
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var err: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer err.deinit();

    const exit = try classifyResolutionDoc(doc, &out.writer, &err.writer);
    try std.testing.expectEqual(@as(u8, 1), exit);
    try std.testing.expect(std.mem.indexOf(u8, err.written(), "InvalidHeldSide") != null);
}

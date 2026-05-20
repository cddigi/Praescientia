//! praescientia-screener — CLI for the market-screener sub-agent's output.
//!
//! Subcommands:
//!   validate --output=PATH [--kb-root=PATH]              Validate the agent JSON.
//!                                                        Exit 0 on accept, 1 on reject.
//!   apply    --output=PATH [--kb-root=PATH]              Materialize accepted entries:
//!            [--bucket=safe|moderate|high_risk]            add-market, add-thesis,
//!            [--dry-run]                                   commentary write (per seed).

const std = @import("std");
const common = @import("common");
const praescientia = @import("praescientia");

const screener_mod = praescientia.kb.screener;
const init_mod = praescientia.kb.init;
const commentary_mod = praescientia.kb.commentary;

pub fn main(init: std.process.Init) !u8 {
    return common.runMain(init, "praescientia-screener", &.{
        .{ .name = "validate", .description = "Validate a screener output JSON file", .run = cmdValidate },
        .{ .name = "apply", .description = "Materialize accepted bucket entries", .run = cmdApply },
    });
}

fn loadExistingMarketSet(
    arena: std.mem.Allocator,
    io: std.Io,
    kb_root: std.Io.Dir,
) ![]const []const u8 {
    var out: std.array_list.Managed([]const u8) = .init(arena);
    var theses_dir = kb_root.openDir(io, "theses", .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return out.items,
        else => return err,
    };
    defer theses_dir.close(io);
    var it = theses_dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        var thesis_dir = theses_dir.openDir(io, entry.name, .{}) catch continue;
        defer thesis_dir.close(io);
        const manifest_bytes = thesis_dir.readFileAlloc(io, "manifest.json", arena, .unlimited) catch continue;
        var parsed = std.json.parseFromSlice(std.json.Value, arena, manifest_bytes, .{}) catch continue;
        defer parsed.deinit();
        const root = parsed.value.object;
        const market_set_v = root.get("market_set") orelse continue;
        if (market_set_v != .array) continue;
        for (market_set_v.array.items) |t| {
            if (t != .string) continue;
            try out.append(try arena.dupe(u8, t.string));
        }
    }
    return out.items;
}

fn loadOutput(ctx: *common.Context) !?[]const u8 {
    const path = ctx.flagValue("--output") orelse {
        try ctx.stderr.print("--output=PATH is required (screener output JSON file)\n", .{});
        return null;
    };
    return std.Io.Dir.cwd().readFileAlloc(ctx.io, path, ctx.arena, .unlimited) catch |err| {
        try ctx.stderr.print("read --output {s}: {t}\n", .{ path, err });
        return null;
    };
}

fn parseCapsFromFlags(ctx: *common.Context) screener_mod.BucketCaps {
    var caps: screener_mod.BucketCaps = .{};
    if (ctx.flagValue("--cap-safe")) |v| {
        if (std.fmt.parseInt(usize, v, 10)) |n| caps.safe = n else |_| {}
    }
    if (ctx.flagValue("--cap-moderate")) |v| {
        if (std.fmt.parseInt(usize, v, 10)) |n| caps.moderate = n else |_| {}
    }
    if (ctx.flagValue("--cap-high-risk")) |v| {
        if (std.fmt.parseInt(usize, v, 10)) |n| caps.high_risk = n else |_| {}
    }
    return caps;
}

fn cmdValidate(ctx: *common.Context) !u8 {
    const bytes = (try loadOutput(ctx)) orelse return 2;
    const kb_root_path = ctx.flagValue("--kb-root") orelse "./kb";
    var kb_root = std.Io.Dir.cwd().openDir(ctx.io, kb_root_path, .{ .iterate = true }) catch |err| {
        try ctx.stderr.print("open kb-root {s}: {t}\n", .{ kb_root_path, err });
        return 1;
    };
    defer kb_root.close(ctx.io);
    const existing = loadExistingMarketSet(ctx.arena, ctx.io, kb_root) catch |err| {
        try ctx.stderr.print("load existing theses: {t}\n", .{err});
        return 1;
    };
    const caps = parseCapsFromFlags(ctx);
    const result = screener_mod.validate(ctx.arena, bytes, existing, caps) catch |err| {
        try ctx.stderr.print("{{\"ok\":false,\"reason\":\"{t}\"}}\n", .{err});
        return 1;
    };
    try ctx.stdout.print(
        "{{\"ok\":true,\"scan_id\":\"{s}\",\"counts\":{{\"safe\":{d},\"moderate\":{d},\"high_risk\":{d}}}}}\n",
        .{ result.output.scan_id, result.counts.safe, result.counts.moderate, result.counts.high_risk },
    );
    return 0;
}

const ApplyPlan = struct {
    add_market: []const u8,
    add_thesis: struct {
        id: []const u8,
        description: []const u8,
        weights_json: []const u8,
    },
    commentaries: []const []const u8,
    bucket: []const u8,
    confidence_bp: u32,
    suggested_size_pct_of_cap: u32,
};

fn buildWeightsJson(arena: std.mem.Allocator, ticker: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "{{\"{s}\":10000}}", .{ticker});
}

fn buildDescription(
    arena: std.mem.Allocator,
    entry: screener_mod.BucketEntry,
) ![]const u8 {
    return std.fmt.allocPrint(
        arena,
        "[screener:{s}] {s} | implied={d}c our={d}c edge={d}c conf={d}bp size_pct={d}%",
        .{
            entry.bucket.key(),
            entry.primary_signal,
            entry.implied_yes_cents,
            entry.our_estimate_yes_cents,
            entry.edge_cents,
            entry.confidence_bp,
            entry.suggested_size_pct_of_cap,
        },
    );
}

fn entryMatchesBucketFilter(entry: screener_mod.BucketEntry, filter: ?[]const u8) bool {
    const f = filter orelse return true;
    if (std.mem.eql(u8, f, "all")) return true;
    const kind = screener_mod.BucketKind.parse(f) orelse return true;
    return entry.bucket == kind;
}

fn cmdApply(ctx: *common.Context) !u8 {
    const bytes = (try loadOutput(ctx)) orelse return 2;
    const dry_run = ctx.flagValue("--dry-run") != null or
        for (ctx.args[1..]) |a| {
            if (std.mem.eql(u8, a, "--dry-run")) break true;
        } else false;
    const bucket_filter = ctx.flagValue("--bucket");
    const kb_root_path = ctx.flagValue("--kb-root") orelse "./kb";

    var kb_root = std.Io.Dir.cwd().openDir(ctx.io, kb_root_path, .{ .iterate = true }) catch |err| {
        try ctx.stderr.print("open kb-root {s}: {t}\n", .{ kb_root_path, err });
        return 1;
    };
    defer kb_root.close(ctx.io);

    const existing = loadExistingMarketSet(ctx.arena, ctx.io, kb_root) catch |err| {
        try ctx.stderr.print("load existing theses: {t}\n", .{err});
        return 1;
    };
    const caps = parseCapsFromFlags(ctx);

    const validation = screener_mod.validate(ctx.arena, bytes, existing, caps) catch |err| {
        try ctx.stderr.print("{{\"ok\":false,\"reason\":\"{t}\"}}\n", .{err});
        return 1;
    };

    var plans: std.array_list.Managed(ApplyPlan) = .init(ctx.arena);
    for (validation.output.buckets) |entry| {
        if (!entryMatchesBucketFilter(entry, bucket_filter)) continue;
        const weights_json = try buildWeightsJson(ctx.arena, entry.ticker);
        const description = try buildDescription(ctx.arena, entry);
        try plans.append(.{
            .add_market = entry.ticker,
            .add_thesis = .{
                .id = entry.proposed_thesis_id,
                .description = description,
                .weights_json = weights_json,
            },
            .commentaries = entry.suggested_seed_commentary,
            .bucket = entry.bucket.key(),
            .confidence_bp = entry.confidence_bp,
            .suggested_size_pct_of_cap = entry.suggested_size_pct_of_cap,
        });
    }

    if (dry_run) {
        try ctx.stdout.print(
            "{{\"ok\":true,\"dry_run\":true,\"scan_id\":\"{s}\",\"planned\":{d},\"writes\":[\n",
            .{ validation.output.scan_id, plans.items.len },
        );
        for (plans.items, 0..) |p, i| {
            try ctx.stdout.print(
                "  {{\"bucket\":\"{s}\",\"thesis_id\":\"{s}\",\"ticker\":\"{s}\",\"commentaries\":{d},\"confidence_bp\":{d},\"size_pct\":{d}}}{s}\n",
                .{
                    p.bucket,
                    p.add_thesis.id,
                    p.add_market,
                    p.commentaries.len,
                    p.confidence_bp,
                    p.suggested_size_pct_of_cap,
                    if (i == plans.items.len - 1) "" else ",",
                },
            );
        }
        try ctx.stdout.print("]}}\n", .{});
        return 0;
    }

    // Real apply path — write to disk.
    var written: usize = 0;
    var commentary_written: usize = 0;
    for (plans.items) |p| {
        // Add market (idempotent — init.addMarket creates a directory; if it
        // already exists, the call returns an error which we treat as already-
        // present and continue).
        init_mod.addMarket(ctx.io, kb_root, p.add_market, 1) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => {
                try ctx.stderr.print("add-market {s}: {t}\n", .{ p.add_market, err });
                continue;
            },
        };
        // Add thesis.
        init_mod.addThesis(ctx.gpa, ctx.io, kb_root, .{
            .id = p.add_thesis.id,
            .description = p.add_thesis.description,
            .rollup_fn = "weighted_avg_v1",
            .weights_json = p.add_thesis.weights_json,
            .confidence_delta_bp = 300,
        }) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => {
                try ctx.stderr.print("add-thesis {s}: {t}\n", .{ p.add_thesis.id, err });
                continue;
            },
        };
        written += 1;
        // Write seed commentaries.
        const ts_ms: i64 = @intCast(@divFloor(std.Io.Clock.real.now(ctx.io).nanoseconds, 1_000_000));
        const tags = [_][]const u8{ "screener-seed", "first-tick-ready" };
        const scope: commentary_mod.Scope = .{ .thesis = p.add_thesis.id };
        for (p.commentaries) |body| {
            const payload: commentary_mod.CommentaryPayload = .{
                .agent = .{ .model = "praescientia-market-screener", .run_id = validation.output.scan_id },
                .body = body,
                .references = &.{},
                .parent_hash = null,
                .inputs = .{ .prediction_head = null, .market_set_heads = &.{} },
                .tags = &tags,
                .ts_ms = ts_ms,
            };
            const result = commentary_mod.writeCommentary(ctx.gpa, ctx.io, kb_root, scope, payload) catch |err| {
                try ctx.stderr.print("commentary write {s}: {t}\n", .{ p.add_thesis.id, err });
                continue;
            };
            ctx.gpa.free(result.scope_path);
            commentary_written += 1;
        }
    }

    try ctx.stdout.print(
        "{{\"ok\":true,\"applied\":{d},\"commentaries_written\":{d},\"scan_id\":\"{s}\"}}\n",
        .{ written, commentary_written, validation.output.scan_id },
    );
    return 0;
}

// ---------------------------------------------------------------------------
// Tests — pure helpers (the validate/apply lifecycle is exercised end-to-end
// by scripts/screener_smoke.sh).
// ---------------------------------------------------------------------------

test "buildWeightsJson — emits single-ticker map" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const s = try buildWeightsJson(arena, "KX-FOO-BAR");
    try std.testing.expectEqualStrings("{\"KX-FOO-BAR\":10000}", s);
}

test "entryMatchesBucketFilter — matches when filter null or all" {
    const entry: screener_mod.BucketEntry = .{
        .bucket = .safe,
        .ticker = "KX-A",
        .proposed_thesis_id = "x",
        .primary_signal = "x",
        .implied_yes_cents = 50,
        .our_estimate_yes_cents = 55,
        .edge_cents = 5,
        .confidence_bp = 5000,
        .research_required = "",
        .suggested_seed_commentary = &.{},
        .suggested_size_pct_of_cap = 10,
    };
    try std.testing.expect(entryMatchesBucketFilter(entry, null));
    try std.testing.expect(entryMatchesBucketFilter(entry, "all"));
    try std.testing.expect(entryMatchesBucketFilter(entry, "safe"));
    try std.testing.expect(!entryMatchesBucketFilter(entry, "moderate"));
    try std.testing.expect(!entryMatchesBucketFilter(entry, "high_risk"));
}

//! kb.ingest — pushes observations into market chains, gated by per-market
//! trigger predicates.

const std = @import("std");
const Allocator = std.mem.Allocator;
const chain_mod = @import("chain.zig");
const manifest_mod = @import("manifest.zig");
const rollup_mod = @import("rollup.zig");

pub const MarketSnapshot = struct {
    ts_ms: u64,
    yes_bid_cents: u32,
    yes_ask_cents: u32,
    volume: u64,
    last_trade_cents: ?u32,
};

/// Apply the market's trigger predicate against the current chain head, and
/// if it fires, append a `market.reality` checkpoint. Returns true if a
/// checkpoint was written.
pub fn observeMarket(
    allocator: Allocator,
    io: std.Io,
    market_dir: std.Io.Dir,
    snap: MarketSnapshot,
) !bool {
    // Load manifest.
    const manifest_buf = try market_dir.readFileAlloc(io, "manifest.json", allocator, .unlimited);
    defer allocator.free(manifest_buf);
    var manifest = try manifest_mod.parseMarket(allocator, manifest_buf);
    defer manifest.deinit();
    try manifest_mod.validateMarket(&manifest);

    // Open the reality chain directory.
    var reality_dir = try market_dir.openDir(io, "reality", .{ .iterate = false });
    defer reality_dir.close(io);

    // Peek the current head's payload to extract prev_yes_bid for trigger comparison.
    var prev_yes_bid: ?u32 = null;
    {
        var read = try chain_mod.openRead(allocator, io, reality_dir, "main");
        defer read.deinit();
        if (read.len() > 0) {
            const last = read.log.items.items[read.len() - 1];
            var parsed = try std.json.parseFromSlice(std.json.Value, allocator, last.payload, .{});
            defer parsed.deinit();
            if (parsed.value.object.get("yes_bid_cents")) |v| {
                prev_yes_bid = @intCast(v.integer);
            }
        }
    }

    // Predicate: first observation always fires; otherwise compare bid delta.
    const fires = prev_yes_bid == null or absDeltaU32(prev_yes_bid.?, snap.yes_bid_cents) >= manifest.price_delta_cents;
    if (!fires) {
        @import("metrics.zig").bumpObserveSkipped(.price_delta_below_threshold);
        return false;
    }

    // Build the canonical-JSON payload. Keys are pre-sorted alphabetically so
    // the line stays hash-stable without a separate canonical_json round-trip.
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    if (snap.last_trade_cents) |lt| {
        try aw.writer.print("{{\"kind\":\"market.reality\",\"last_trade_cents\":{d},", .{lt});
    } else {
        try aw.writer.writeAll("{\"kind\":\"market.reality\",\"last_trade_cents\":null,");
    }
    if (prev_yes_bid) |p| {
        try aw.writer.print("\"trigger\":{{\"prev_yes_bid\":{d},\"type\":\"price_delta\"}},", .{p});
    } else {
        try aw.writer.writeAll("\"trigger\":{\"prev_yes_bid\":null,\"type\":\"price_delta\"},");
    }
    try aw.writer.print(
        "\"ts\":{d},\"volume\":{d},\"yes_ask_cents\":{d},\"yes_bid_cents\":{d}}}",
        .{ snap.ts_ms, snap.volume, snap.yes_ask_cents, snap.yes_bid_cents },
    );

    var h = try chain_mod.openForWrite(allocator, io, reality_dir, "main");
    defer h.deinit();
    _ = try h.append(aw.written());
    return true;
}

fn absDeltaU32(a: u32, b: u32) u32 {
    return if (a > b) a - b else b - a;
}

pub const Resolution = struct {
    ts_ms: u64,
    resolved_yes: bool,
};

/// Append a terminal `market.reality` record stamped with the market's
/// resolution outcome. Bypasses the price_delta predicate — resolution
/// always fires.
pub fn observeResolution(
    allocator: Allocator,
    io: std.Io,
    market_dir: std.Io.Dir,
    res: Resolution,
) !void {
    var reality_dir = try market_dir.openDir(io, "reality", .{ .iterate = false });
    defer reality_dir.close(io);

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try aw.writer.print(
        "{{\"kind\":\"market.reality\",\"resolved_yes\":{s},\"trigger\":{{\"type\":\"resolution\"}},\"ts\":{d}}}",
        .{ if (res.resolved_yes) "true" else "false", res.ts_ms },
    );

    var h = try chain_mod.openForWrite(allocator, io, reality_dir, "main");
    defer h.deinit();
    _ = try h.append(aw.written());
}

/// Append a fully pre-formed canonical-JSON payload to the active "main"
/// branch in `chain_dir`. Bypasses all predicates — caller is responsible
/// for canonical-JSON encoding. Used by prediction/thesis chains where the
/// trigger logic lives elsewhere.
pub fn observeManual(
    allocator: Allocator,
    io: std.Io,
    chain_dir: std.Io.Dir,
    canonical_payload: []const u8,
) !void {
    var h = try chain_mod.openForWrite(allocator, io, chain_dir, "main");
    defer h.deinit();
    _ = try h.append(canonical_payload);
}

test "observeManual bypasses predicates and appends raw payload" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.writeFile(io, .{ .sub_path = "main.jsonl", .data = "" });
    try tmp.dir.writeFile(io, .{
        .sub_path = "branches.json",
        .data =
        \\{"active":"main","branches":[{"name":"main","head_hash":"0000000000000000000000000000000000000000000000000000000000000000","parent_hash":"0000000000000000000000000000000000000000000000000000000000000000","parent_branch":"","created_ts_ms":0}]}
        ,
    });

    const payload = "{\"confidence_bp\":7200,\"kind\":\"market.prediction\",\"rationale\":\"manual override\",\"trigger\":{\"type\":\"manual_decision\"},\"ts\":42}";
    try observeManual(std.testing.allocator, io, tmp.dir, payload);

    var chain = try chain_mod.openRead(std.testing.allocator, io, tmp.dir, "main");
    defer chain.deinit();
    try std.testing.expectEqual(@as(usize, 1), chain.len());
}

test "observeResolution appends a terminal record" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.createDirPath(io, "reality");

    try tmp.dir.writeFile(io, .{
        .sub_path = "manifest.json",
        .data = "{\"kind\":\"market\",\"ticker\":\"KXTEST\",\"trigger\":{\"price_delta_cents\":1}}",
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

    try observeResolution(std.testing.allocator, io, tmp.dir, .{ .ts_ms = 999, .resolved_yes = true });

    var chain = try chain_mod.openRead(std.testing.allocator, io, reality_dir, "main");
    defer chain.deinit();
    try std.testing.expectEqual(@as(usize, 1), chain.len());
    try std.testing.expect(std.mem.indexOf(u8, chain.log.items.items[0].payload, "\"resolution\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, chain.log.items.items[0].payload, "\"resolved_yes\":true") != null);
}

test "observeMarket appends only when price moved past manifest threshold" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.createDirPath(io, "reality");

    // Seed market manifest with 1c threshold + empty reality chain + branches.json.
    try tmp.dir.writeFile(io, .{
        .sub_path = "manifest.json",
        .data = "{\"kind\":\"market\",\"ticker\":\"KXTEST\",\"trigger\":{\"price_delta_cents\":1}}",
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

    // First observation: empty chain → always appends.
    const wrote1 = try observeMarket(std.testing.allocator, io, tmp.dir, .{
        .ts_ms = 100,
        .yes_bid_cents = 50,
        .yes_ask_cents = 51,
        .volume = 1000,
        .last_trade_cents = null,
    });
    try std.testing.expect(wrote1);

    // Second: 0c delta → no append.
    const wrote2 = try observeMarket(std.testing.allocator, io, tmp.dir, .{
        .ts_ms = 200,
        .yes_bid_cents = 50,
        .yes_ask_cents = 51,
        .volume = 1100,
        .last_trade_cents = null,
    });
    try std.testing.expect(!wrote2);

    // Third: 2c delta → appends.
    const wrote3 = try observeMarket(std.testing.allocator, io, tmp.dir, .{
        .ts_ms = 300,
        .yes_bid_cents = 52,
        .yes_ask_cents = 53,
        .volume = 1200,
        .last_trade_cents = null,
    });
    try std.testing.expect(wrote3);

    var chain = try chain_mod.openRead(std.testing.allocator, io, reality_dir, "main");
    defer chain.deinit();
    try std.testing.expectEqual(@as(usize, 2), chain.len());
}

/// Read every market head named in `theses/<thesis_id>/manifest.json`, compose
/// them through the named rollup, and write the result as a `thesis.reality`
/// checkpoint on the thesis chain (if the aggregate moved enough or the chain
/// is empty). Returns true if a checkpoint was written.
pub fn recomputeThesisReality(
    allocator: Allocator,
    io: std.Io,
    kb_root: std.Io.Dir,
    thesis_id: []const u8,
) !bool {
    var thesis_path_buf: [256]u8 = undefined;
    const thesis_path = try std.fmt.bufPrint(&thesis_path_buf, "theses/{s}", .{thesis_id});
    var thesis_dir = try kb_root.openDir(io, thesis_path, .{ .iterate = false });
    defer thesis_dir.close(io);

    const manifest_buf = try thesis_dir.readFileAlloc(io, "manifest.json", allocator, .unlimited);
    defer allocator.free(manifest_buf);
    var manifest = try manifest_mod.parseThesis(allocator, manifest_buf);
    defer manifest.deinit();
    try manifest_mod.validateThesis(&manifest);

    const rollup_fn = rollup_mod.lookup(manifest.rollup_fn) orelse return error.UnknownRollupFn;

    const snaps = try allocator.alloc(rollup_mod.MarketSnapshotForRollup, manifest.market_set.len);
    // Track how many entries have a fully-initialized head_hash_hex so the
    // unwind path doesn't free undefined memory if a loop iteration errors.
    var initialized: usize = 0;
    defer {
        for (snaps[0..initialized]) |s| allocator.free(@constCast(s.head_hash_hex));
        allocator.free(snaps);
    }

    for (manifest.market_set, 0..) |ticker, i| {
        var market_path_buf: [256]u8 = undefined;
        const market_path = try std.fmt.bufPrint(&market_path_buf, "markets/{s}/reality", .{ticker});
        var reality_dir = try kb_root.openDir(io, market_path, .{ .iterate = false });
        defer reality_dir.close(io);

        var read = try chain_mod.openRead(allocator, io, reality_dir, "main");
        defer read.deinit();
        if (read.len() == 0) return false; // can't roll up a market with no observations yet
        const last = read.log.items.items[read.len() - 1];

        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, last.payload, .{});
        defer parsed.deinit();
        const obj = parsed.value.object;
        const yes_bid: u32 = if (obj.get("yes_bid_cents")) |v| @intCast(v.integer) else 0;
        const yes_ask: u32 = if (obj.get("yes_ask_cents")) |v| @intCast(v.integer) else 0;

        var hex: [64]u8 = undefined;
        _ = std.fmt.bufPrint(&hex, "{x}", .{last.hash}) catch unreachable;
        const hex_owned = try allocator.dupe(u8, &hex);
        snaps[i] = .{
            .ticker = ticker,
            .yes_bid_cents = yes_bid,
            .yes_ask_cents = yes_ask,
            .head_hash_hex = hex_owned,
        };
        initialized = i + 1;
    }

    const result = rollup_fn(.{ .sources = snaps, .weights_bp = manifest.weights_bp });

    // Compare against current thesis reality head — only emit on first entry
    // or when the aggregate has moved. The 1-cent floor is a deterministic
    // placeholder; future polish can derive the threshold from
    // manifest.confidence_delta_bp (500 bp = 5 cents).
    var reality_dir = try thesis_dir.openDir(io, "reality", .{ .iterate = false });
    defer reality_dir.close(io);
    var prev_agg: ?u32 = null;
    {
        var read = try chain_mod.openRead(allocator, io, reality_dir, "main");
        defer read.deinit();
        if (read.len() > 0) {
            const last = read.log.items.items[read.len() - 1];
            var parsed = try std.json.parseFromSlice(std.json.Value, allocator, last.payload, .{});
            defer parsed.deinit();
            if (parsed.value.object.get("aggregate_yes_cents")) |v| prev_agg = @intCast(v.integer);
        }
    }
    if (prev_agg) |p| {
        const delta = if (p > result.aggregate_yes_cents) p - result.aggregate_yes_cents else result.aggregate_yes_cents - p;
        if (delta < 1) {
            @import("metrics.zig").bumpObserveSkipped(.aggregate_unchanged);
            return false;
        }
    }

    // Emit canonical-ordered JSON: aggregate_yes_cents, kind, rollup_fn,
    // sources (alphabetical by ticker — manifest order is honored), trigger, ts.
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try aw.writer.print(
        "{{\"aggregate_yes_cents\":{d},\"kind\":\"thesis.reality\",\"rollup_fn\":\"{s}\",\"sources\":{{",
        .{ result.aggregate_yes_cents, manifest.rollup_fn },
    );
    for (snaps, 0..) |s, i| {
        if (i > 0) try aw.writer.writeByte(',');
        try aw.writer.print("\"{s}\":\"{s}\"", .{ s.ticker, s.head_hash_hex });
    }
    const ts_ms: u64 = @intCast(@divFloor(std.Io.Clock.real.now(io).nanoseconds, 1_000_000));
    try aw.writer.print(
        "}},\"trigger\":{{\"type\":\"source_delta\"}},\"ts\":{d}}}",
        .{ts_ms},
    );

    var h = try chain_mod.openForWrite(allocator, io, reality_dir, "main");
    defer h.deinit();
    _ = try h.append(aw.written());
    return true;
}

test "recomputeThesisReality appends a thesis.reality entry when rollup crosses threshold" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;

    // Two market chains with one entry each at 60c (A) and 40c (B).
    inline for (.{ "A", "B" }) |t| {
        const market_path = "markets/" ++ t;
        try tmp.dir.createDirPath(io, market_path ++ "/reality");
        try tmp.dir.writeFile(io, .{
            .sub_path = market_path ++ "/manifest.json",
            .data = "{\"kind\":\"market\",\"ticker\":\"" ++ t ++ "\",\"trigger\":{\"price_delta_cents\":1}}",
        });
        try tmp.dir.writeFile(io, .{ .sub_path = market_path ++ "/reality/main.jsonl", .data = "" });
        try tmp.dir.writeFile(io, .{
            .sub_path = market_path ++ "/reality/branches.json",
            .data = "{\"active\":\"main\",\"branches\":[{\"name\":\"main\",\"head_hash\":\"0000000000000000000000000000000000000000000000000000000000000000\",\"parent_hash\":\"0000000000000000000000000000000000000000000000000000000000000000\",\"parent_branch\":\"\",\"created_ts_ms\":0}]}",
        });
    }
    var a_dir = try tmp.dir.openDir(io, "markets/A", .{ .iterate = false });
    defer a_dir.close(io);
    _ = try observeMarket(std.testing.allocator, io, a_dir, .{
        .ts_ms = 1,
        .yes_bid_cents = 60,
        .yes_ask_cents = 62,
        .volume = 1,
        .last_trade_cents = null,
    });
    var b_dir = try tmp.dir.openDir(io, "markets/B", .{ .iterate = false });
    defer b_dir.close(io);
    _ = try observeMarket(std.testing.allocator, io, b_dir, .{
        .ts_ms = 1,
        .yes_bid_cents = 40,
        .yes_ask_cents = 42,
        .volume = 1,
        .last_trade_cents = null,
    });

    try tmp.dir.createDirPath(io, "theses/t/reality");
    try tmp.dir.writeFile(io, .{
        .sub_path = "theses/t/manifest.json",
        .data =
        \\{"kind":"thesis","id":"t","description":"x","market_set":["A","B"],"rollup_fn":"weighted_avg_v1","weights":{"A":7000,"B":3000},"trigger":{"confidence_delta_bp":500}}
        ,
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "theses/t/reality/main.jsonl", .data = "" });
    try tmp.dir.writeFile(io, .{
        .sub_path = "theses/t/reality/branches.json",
        .data = "{\"active\":\"main\",\"branches\":[{\"name\":\"main\",\"head_hash\":\"0000000000000000000000000000000000000000000000000000000000000000\",\"parent_hash\":\"0000000000000000000000000000000000000000000000000000000000000000\",\"parent_branch\":\"\",\"created_ts_ms\":0}]}",
    });

    rollup_mod.registry = .empty;
    defer rollup_mod.registry.deinit(std.testing.allocator);
    try rollup_mod.registerAll(std.testing.allocator);

    const wrote = try recomputeThesisReality(std.testing.allocator, io, tmp.dir, "t");
    try std.testing.expect(wrote);

    var thesis_reality_dir = try tmp.dir.openDir(io, "theses/t/reality", .{ .iterate = false });
    defer thesis_reality_dir.close(io);
    var chain = try chain_mod.openRead(std.testing.allocator, io, thesis_reality_dir, "main");
    defer chain.deinit();
    try std.testing.expectEqual(@as(usize, 1), chain.len());
    try std.testing.expect(std.mem.indexOf(u8, chain.log.items.items[0].payload, "\"aggregate_yes_cents\":55") != null);
}

test "observeMarket rejects an invalid manifest" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.createDirPath(io, "reality");

    // price_delta_cents = 0 is invalid per validateMarket.
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
        .ts_ms = 1,
        .yes_bid_cents = 50,
        .yes_ask_cents = 51,
        .volume = 1,
        .last_trade_cents = null,
    }));
}

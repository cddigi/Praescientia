//! kb.ingest — pushes observations into market chains, gated by per-market
//! trigger predicates.

const std = @import("std");
const Allocator = std.mem.Allocator;
const chain_mod = @import("chain.zig");
const manifest_mod = @import("manifest.zig");

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
    if (!fires) return false;

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

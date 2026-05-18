//! Bootstrap a fresh kb_root directory tree.
//!
//! `initTree(io, root, with_sample)` creates `<root>/markets/` and
//! `<root>/theses/`. With `with_sample=true`, also lays down one market
//! (`SAMPLE`) and one thesis (`sample`) with parseable manifests + empty
//! chains. The samples double as the in-repo reference for "what does a
//! real manifest look like."

const std = @import("std");

const empty_branches_json =
    "{\"active\":\"main\",\"branches\":[{\"name\":\"main\"," ++
    "\"head_hash\":\"0000000000000000000000000000000000000000000000000000000000000000\"," ++
    "\"parent_hash\":\"0000000000000000000000000000000000000000000000000000000000000000\"," ++
    "\"parent_branch\":\"\",\"created_ts_ms\":0}]}";

pub fn initTree(io: std.Io, root: std.Io.Dir, with_sample: bool) !void {
    try root.createDir(io, "markets", .default_dir);
    try root.createDir(io, "theses", .default_dir);
    if (with_sample) try writeSamples(io, root);
}

/// Lay down `markets/<ticker>/manifest.json` + empty `reality/` chain. Refuses
/// to overwrite an existing market — caller can delete the dir manually if
/// they really want to start over.
pub fn addMarket(io: std.Io, root: std.Io.Dir, ticker: []const u8, price_delta_cents: u32) !void {
    var market_path_buf: [256]u8 = undefined;
    const market_path = try std.fmt.bufPrint(&market_path_buf, "markets/{s}", .{ticker});

    // Refuse to overwrite. `access` returns FileNotFound on absence; any other
    // outcome means the dir is already there.
    if (root.access(io, market_path, .{})) |_| {
        return error.MarketExists;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }

    var reality_path_buf: [256]u8 = undefined;
    const reality_path = try std.fmt.bufPrint(&reality_path_buf, "markets/{s}/reality", .{ticker});
    try root.createDirPath(io, reality_path);

    var manifest_path_buf: [256]u8 = undefined;
    const manifest_path = try std.fmt.bufPrint(&manifest_path_buf, "markets/{s}/manifest.json", .{ticker});

    // Canonical-JSON: alphabetical top-level keys (kind, ticker, trigger).
    // 512 bytes is plenty — ticker is validated to <= 64 chars elsewhere.
    var json_buf: [512]u8 = undefined;
    const json = try std.fmt.bufPrint(
        &json_buf,
        "{{\"kind\":\"market\",\"ticker\":\"{s}\",\"trigger\":{{\"price_delta_cents\":{d}}}}}",
        .{ ticker, price_delta_cents },
    );
    try root.writeFile(io, .{ .sub_path = manifest_path, .data = json });

    var main_jsonl_buf: [256]u8 = undefined;
    const main_jsonl_path = try std.fmt.bufPrint(&main_jsonl_buf, "markets/{s}/reality/main.jsonl", .{ticker});
    try root.writeFile(io, .{ .sub_path = main_jsonl_path, .data = "" });

    var branches_path_buf: [256]u8 = undefined;
    const branches_path = try std.fmt.bufPrint(&branches_path_buf, "markets/{s}/reality/branches.json", .{ticker});
    try root.writeFile(io, .{ .sub_path = branches_path, .data = empty_branches_json });
}

fn writeSamples(io: std.Io, root: std.Io.Dir) !void {
    // SAMPLE market — single ticker, 1c price-delta trigger.
    try addMarket(io, root, "SAMPLE", 1);

    // sample thesis — one source (SAMPLE at 100% weight), weighted_avg_v1.
    try root.createDirPath(io, "theses/sample/reality");
    try root.createDirPath(io, "theses/sample/prediction");
    try root.writeFile(io, .{
        .sub_path = "theses/sample/manifest.json",
        .data = "{\"kind\":\"thesis\",\"id\":\"sample\",\"description\":\"sample thesis\"," ++
            "\"market_set\":[\"SAMPLE\"],\"rollup_fn\":\"weighted_avg_v1\"," ++
            "\"weights\":{\"SAMPLE\":10000},\"trigger\":{\"confidence_delta_bp\":500}}",
    });
    inline for (.{ "reality", "prediction" }) |sub| {
        try root.writeFile(io, .{ .sub_path = "theses/sample/" ++ sub ++ "/main.jsonl", .data = "" });
        try root.writeFile(io, .{ .sub_path = "theses/sample/" ++ sub ++ "/branches.json", .data = empty_branches_json });
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

test "addMarket creates a parseable + valid manifest" {
    const manifest_mod = @import("manifest.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try initTree(io, tmp.dir, false);

    try addMarket(io, tmp.dir, "KXBTC-26", 5);

    const buf = try tmp.dir.readFileAlloc(io, "markets/KXBTC-26/manifest.json", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(buf);
    var m = try manifest_mod.parseMarket(std.testing.allocator, buf);
    defer m.deinit();
    try manifest_mod.validateMarket(&m);
    try std.testing.expectEqual(@as(u32, 5), m.price_delta_cents);

    // reality/main.jsonl + branches.json must exist.
    try tmp.dir.access(io, "markets/KXBTC-26/reality/main.jsonl", .{});
    try tmp.dir.access(io, "markets/KXBTC-26/reality/branches.json", .{});
}

test "addMarket refuses to overwrite an existing market" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try initTree(io, tmp.dir, false);
    try addMarket(io, tmp.dir, "KXBTC", 1);
    try std.testing.expectError(error.MarketExists, addMarket(io, tmp.dir, "KXBTC", 2));
}

test "initTree --with-sample produces parseable + valid manifests" {
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

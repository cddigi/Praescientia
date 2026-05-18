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

pub const AddThesisOptions = struct {
    id: []const u8,
    description: []const u8,
    rollup_fn: []const u8 = "weighted_avg_v1",
    /// JSON object literal mapping ticker → weight_bp, e.g.
    /// `{"KXFED":7000,"KXRECESSION":3000}`. Weights must sum to 10000.
    /// `market_set` is derived from the sorted keys.
    weights_json: []const u8,
    confidence_delta_bp: u32 = 500,
};

/// Lay down `theses/<id>/manifest.json` + empty `reality/` and `prediction/`
/// chains. Refuses to overwrite an existing thesis. `market_set` is derived
/// from the keys of `weights_json` sorted alphabetically so the manifest is
/// deterministic regardless of caller key order.
pub fn addThesis(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: std.Io.Dir,
    opts: AddThesisOptions,
) !void {
    var thesis_path_buf: [256]u8 = undefined;
    const thesis_path = try std.fmt.bufPrint(&thesis_path_buf, "theses/{s}", .{opts.id});

    if (root.access(io, thesis_path, .{})) |_| {
        return error.ThesisExists;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }

    // Parse weights_json once to extract keys + values.
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, opts.weights_json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.WeightsMustBeObject;
    const weights_obj = parsed.value.object;
    if (weights_obj.count() == 0) return error.EmptyMarketSet;

    // Sort tickers alphabetically for stable on-disk layout.
    const tickers = try allocator.alloc([]const u8, weights_obj.count());
    defer allocator.free(tickers);
    {
        var it = weights_obj.iterator();
        var i: usize = 0;
        while (it.next()) |e| : (i += 1) tickers[i] = e.key_ptr.*;
    }
    std.mem.sort([]const u8, tickers, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);

    // Build the manifest JSON. Key order mirrors the existing `writeSamples`
    // output so operators see consistent shapes across fresh init + add.
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try aw.writer.print(
        "{{\"kind\":\"thesis\",\"id\":\"{s}\",\"description\":\"{s}\",\"market_set\":[",
        .{ opts.id, opts.description },
    );
    for (tickers, 0..) |t, i| {
        if (i > 0) try aw.writer.writeByte(',');
        try aw.writer.print("\"{s}\"", .{t});
    }
    try aw.writer.print("],\"rollup_fn\":\"{s}\",\"weights\":{{", .{opts.rollup_fn});
    for (tickers, 0..) |t, i| {
        if (i > 0) try aw.writer.writeByte(',');
        const w = weights_obj.get(t) orelse return error.MissingTickerWeight;
        const w_int: i64 = w.integer;
        try aw.writer.print("\"{s}\":{d}", .{ t, w_int });
    }
    try aw.writer.print("}},\"trigger\":{{\"confidence_delta_bp\":{d}}}}}", .{opts.confidence_delta_bp});

    // Create dirs.
    var reality_path_buf: [256]u8 = undefined;
    const reality_path = try std.fmt.bufPrint(&reality_path_buf, "theses/{s}/reality", .{opts.id});
    try root.createDirPath(io, reality_path);

    var prediction_path_buf: [256]u8 = undefined;
    const prediction_path = try std.fmt.bufPrint(&prediction_path_buf, "theses/{s}/prediction", .{opts.id});
    try root.createDirPath(io, prediction_path);

    // Write manifest.
    var manifest_path_buf: [256]u8 = undefined;
    const manifest_path = try std.fmt.bufPrint(&manifest_path_buf, "theses/{s}/manifest.json", .{opts.id});
    try root.writeFile(io, .{ .sub_path = manifest_path, .data = aw.written() });

    // Write empty main.jsonl + genesis branches.json for both reality and prediction.
    inline for (.{ "reality", "prediction" }) |sub| {
        var jsonl_buf: [256]u8 = undefined;
        const jsonl_path = try std.fmt.bufPrint(&jsonl_buf, "theses/{s}/" ++ sub ++ "/main.jsonl", .{opts.id});
        try root.writeFile(io, .{ .sub_path = jsonl_path, .data = "" });

        var branches_buf: [256]u8 = undefined;
        const branches_path = try std.fmt.bufPrint(&branches_buf, "theses/{s}/" ++ sub ++ "/branches.json", .{opts.id});
        try root.writeFile(io, .{ .sub_path = branches_path, .data = empty_branches_json });
    }
}

test "addThesis creates a parseable + valid manifest with derived market_set" {
    const manifest_mod = @import("manifest.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try initTree(io, tmp.dir, false);
    try addMarket(io, tmp.dir, "KXFED", 1);
    try addMarket(io, tmp.dir, "KXRECESSION", 1);

    try addThesis(std.testing.allocator, io, tmp.dir, .{
        .id = "fed-cuts",
        .description = "Fed cuts in June",
        .rollup_fn = "weighted_avg_v1",
        .weights_json = "{\"KXFED\":7000,\"KXRECESSION\":3000}",
        .confidence_delta_bp = 500,
    });

    const buf = try tmp.dir.readFileAlloc(io, "theses/fed-cuts/manifest.json", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(buf);
    var t = try manifest_mod.parseThesis(std.testing.allocator, buf);
    defer t.deinit();
    try manifest_mod.validateThesis(&t);
    try std.testing.expectEqual(@as(usize, 2), t.market_set.len);
    // Sorted alphabetically: KXFED < KXRECESSION
    try std.testing.expectEqualStrings("KXFED", t.market_set[0]);
    try std.testing.expectEqualStrings("KXRECESSION", t.market_set[1]);
    try std.testing.expectEqual(@as(u32, 7000), t.weights_bp[0]);
    try std.testing.expectEqual(@as(u32, 3000), t.weights_bp[1]);
    try std.testing.expectEqual(@as(u32, 500), t.confidence_delta_bp);

    // Both chain dirs must exist with empty main.jsonl + genesis branches.json.
    try tmp.dir.access(io, "theses/fed-cuts/reality/main.jsonl", .{});
    try tmp.dir.access(io, "theses/fed-cuts/reality/branches.json", .{});
    try tmp.dir.access(io, "theses/fed-cuts/prediction/main.jsonl", .{});
    try tmp.dir.access(io, "theses/fed-cuts/prediction/branches.json", .{});
}

test "addThesis refuses to overwrite an existing thesis" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try initTree(io, tmp.dir, false);
    try addThesis(std.testing.allocator, io, tmp.dir, .{
        .id = "x",
        .description = "y",
        .weights_json = "{\"A\":10000}",
    });
    try std.testing.expectError(error.ThesisExists, addThesis(std.testing.allocator, io, tmp.dir, .{
        .id = "x",
        .description = "y",
        .weights_json = "{\"A\":10000}",
    }));
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

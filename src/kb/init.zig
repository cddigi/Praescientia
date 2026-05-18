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

fn writeSamples(io: std.Io, root: std.Io.Dir) !void {
    // SAMPLE market — single ticker, 1c price-delta trigger.
    try root.createDirPath(io, "markets/SAMPLE/reality");
    try root.writeFile(io, .{
        .sub_path = "markets/SAMPLE/manifest.json",
        .data = "{\"kind\":\"market\",\"ticker\":\"SAMPLE\",\"trigger\":{\"price_delta_cents\":1}}",
    });
    try root.writeFile(io, .{ .sub_path = "markets/SAMPLE/reality/main.jsonl", .data = "" });
    try root.writeFile(io, .{ .sub_path = "markets/SAMPLE/reality/branches.json", .data = empty_branches_json });

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

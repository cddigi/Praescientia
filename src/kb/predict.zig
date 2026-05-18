//! kb.predict — record a `thesis.prediction` checkpoint on a thesis's
//! prediction chain. Keys in the canonical-JSON payload are kept in strict
//! alphabetical order so the chain hash is stable.
//!
//! The trigger field is fixed to `{"type":"manual_decision"}` — predictions
//! are operator decisions, not derived from market state.

const std = @import("std");
const Allocator = std.mem.Allocator;
const chain_mod = @import("chain.zig");
const ingest_mod = @import("ingest.zig");

/// Append a `thesis.prediction` entry to `theses/<thesis_id>/prediction/main.jsonl`.
/// `confidence_bp` is the operator's belief in the thesis at the time of writing
/// (1..10000). `rationale` is optional free-form text — empty string is allowed
/// but the field is always present so the payload shape is stable.
pub fn writePrediction(
    allocator: Allocator,
    io: std.Io,
    kb_root: std.Io.Dir,
    thesis_id: []const u8,
    confidence_bp: u32,
    rationale: []const u8,
) !void {
    var path_buf: [256]u8 = undefined;
    const prediction_path = try std.fmt.bufPrint(&path_buf, "theses/{s}/prediction", .{thesis_id});
    var prediction_dir = try kb_root.openDir(io, prediction_path, .{ .iterate = false });
    defer prediction_dir.close(io);

    const ts_ms: u64 = @intCast(@divFloor(std.Io.Clock.real.now(io).nanoseconds, 1_000_000));

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    // Keys alphabetical for hash stability: confidence_bp, kind, rationale, trigger, ts.
    try aw.writer.print(
        "{{\"confidence_bp\":{d},\"kind\":\"thesis.prediction\",\"rationale\":\"{s}\",\"trigger\":{{\"type\":\"manual_decision\"}},\"ts\":{d}}}",
        .{ confidence_bp, rationale, ts_ms },
    );

    try ingest_mod.observeManual(allocator, io, prediction_dir, aw.written());
}

test "writePrediction appends a thesis.prediction payload" {
    const init_mod = @import("init.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try init_mod.initTree(io, tmp.dir, true);

    try writePrediction(std.testing.allocator, io, tmp.dir, "sample", 7200, "test");

    var pred_dir = try tmp.dir.openDir(io, "theses/sample/prediction", .{ .iterate = false });
    defer pred_dir.close(io);
    var chain = try chain_mod.openRead(std.testing.allocator, io, pred_dir, "main");
    defer chain.deinit();
    try std.testing.expectEqual(@as(usize, 1), chain.len());
    const payload = chain.log.items.items[0].payload;
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"confidence_bp\":7200") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"kind\":\"thesis.prediction\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"rationale\":\"test\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"type\":\"manual_decision\"") != null);
}

test "writePrediction accepts an empty rationale" {
    const init_mod = @import("init.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try init_mod.initTree(io, tmp.dir, true);

    try writePrediction(std.testing.allocator, io, tmp.dir, "sample", 5000, "");

    var pred_dir = try tmp.dir.openDir(io, "theses/sample/prediction", .{ .iterate = false });
    defer pred_dir.close(io);
    var chain = try chain_mod.openRead(std.testing.allocator, io, pred_dir, "main");
    defer chain.deinit();
    try std.testing.expectEqual(@as(usize, 1), chain.len());
    try std.testing.expect(std.mem.indexOf(u8, chain.log.items.items[0].payload, "\"rationale\":\"\"") != null);
}

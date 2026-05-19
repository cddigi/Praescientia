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

pub fn main(init: std.process.Init) !u8 {
    return common.runMain(init, "praescientia-ticks", &.{
        .{ .name = "snapshot", .description = "Write a chain-head snapshot JSON file to <out_path>", .run = cmdSnapshot },
        .{ .name = "begin", .description = "Generate a tick_id and write its pre-state snapshot", .run = cmdBegin },
        .{ .name = "finish", .description = "Write the post-state snapshot for an in-progress tick", .run = cmdFinish },
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

fn missing(ctx: *common.Context, usage: []const u8) !u8 {
    try ctx.stderr.print("usage: praescientia-ticks {s}\n", .{usage});
    return 2;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

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

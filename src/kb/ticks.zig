//! kb.ticks — tick primitives for the autonomous prediction agent.
//!
//! Each tick is a single state transition with a ULID identifier. The
//! orchestrator snapshots chain heads before and after, writes events to
//! a per-tick JSONL file, and tracks rejected sub-agent decisions on the
//! side. All paths live under `<kb_root>/.ticks/`.
//!
//! This module owns just the primitives — types, ULIDs, paths, and
//! schema/cap validation. The `praescientia-ticks` CLI (Stage 2) and the
//! orchestrate skill (Stage 5) compose them.

const std = @import("std");
const Allocator = std.mem.Allocator;

const txlog = @import("../txlog.zig");
const chain_mod = @import("chain.zig");
const branches_mod = @import("branches.zig");
const state_chain = @import("../state_chain.zig");
const Hash = state_chain.Hash;

/// Length of the ULID portion of a tick id (Crockford-base32, 26 chars).
pub const tick_id_len: usize = 26;

/// One tick. Created at the start of a tick; the `id` is the audit anchor
/// for every artifact the tick produces (chain entries, snapshot files,
/// rejection logs, client_order_ids).
pub const Tick = struct {
    id: [tick_id_len]u8,

    /// Generate a fresh tick. ULID body = 48-bit Unix-ms timestamp + 80-bit
    /// CSPRNG randomness. Monotonic across ms boundaries but not within a
    /// single ms — fine for tick cadences measured in minutes.
    pub fn init() Tick {
        var tick: Tick = undefined;
        var tx_buf: [txlog.tx_id_len]u8 = undefined;
        txlog.generateTxId(&tx_buf);
        // generateTxId emits "tx_<26-char ULID>"; we only need the ULID body.
        @memcpy(&tick.id, tx_buf[3..][0..tick_id_len]);
        return tick;
    }

    /// Compose the on-disk path for one of the tick's artifact files.
    /// `buf` must be large enough to hold the full path; on overflow returns
    /// `error.NoSpaceLeft` (the `std.fmt.bufPrint` contract).
    pub fn path(self: *const Tick, buf: []u8, kb_root: []const u8, kind: PathKind) ![]u8 {
        return std.fmt.bufPrint(buf, "{s}/.ticks/{s}.{s}.{s}", .{
            kb_root,
            self.id[0..],
            @tagName(kind),
            kind.extension(),
        });
    }
};

/// The four per-tick artifact kinds. Determines both the filename suffix
/// and the file extension (`events` is JSONL; everything else is single-
/// object JSON).
pub const PathKind = enum {
    pre,
    post,
    events,
    rejected,

    fn extension(self: PathKind) []const u8 {
        return switch (self) {
            .events => "jsonl",
            .pre, .post, .rejected => "json",
        };
    }
};

// ---------------------------------------------------------------------------
// Chain-head snapshots
// ---------------------------------------------------------------------------

/// Per-chain snapshot entry. Identifies one chain by its kb_root-relative
/// path and captures the active-branch head at snapshot time. Used as both
/// the pre-tick rollback anchor and the post-tick "what changed" delta.
///
/// `scope_path` and `branch` are owned by `allocator`; free via `free(allocator)`
/// or by calling `freeSnapshot(allocator, slice)`.
pub const SnapshotEntry = struct {
    /// kb_root-relative chain directory path. Examples:
    ///   - "commentary/global"
    ///   - "markets/SAMPLE/reality"
    ///   - "theses/sample/prediction"
    scope_path: []const u8,
    /// Active branch name (typically "main").
    branch: []const u8,
    /// Hex-encoded head hash, or null for an empty chain.
    head_hash: ?[64]u8,
    /// Number of entries in the active branch.
    length: usize,

    pub fn free(self: SnapshotEntry, allocator: Allocator) void {
        allocator.free(self.scope_path);
        allocator.free(self.branch);
    }
};

/// Free every owned string in a snapshot slice plus the slice itself.
pub fn freeSnapshot(allocator: Allocator, entries: []SnapshotEntry) void {
    for (entries) |e| e.free(allocator);
    allocator.free(entries);
}

/// Walk the chain tree under `kb_root` and return one entry per chain.
/// Visits, in this order before sorting:
///
///   commentary/global/             (if present — only created on first write)
///   markets/<TICKER>/reality/
///   markets/<TICKER>/commentary/
///   theses/<id>/reality/
///   theses/<id>/prediction/
///   theses/<id>/commentary/
///
/// The returned slice is sorted alphabetically by `scope_path` for
/// canonical/deterministic output. A missing chain dir under a market or
/// thesis is silently skipped — it may simply not have been admitted yet.
/// Caller owns the returned slice; use `freeSnapshot` to release.
pub fn snapshotHeads(allocator: Allocator, io: std.Io, kb_root: std.Io.Dir) ![]SnapshotEntry {
    var list: std.array_list.Managed(SnapshotEntry) = .init(allocator);
    errdefer {
        for (list.items) |e| e.free(allocator);
        list.deinit();
    }

    // Global commentary — optional, created on first write.
    try collectChainIfPresent(allocator, io, kb_root, "commentary/global", &list);

    // Markets — each one has reality/ and commentary/.
    try collectGroup(allocator, io, kb_root, "markets", &[_][]const u8{ "reality", "commentary" }, &list);

    // Theses — each one has reality/, prediction/, and commentary/.
    try collectGroup(allocator, io, kb_root, "theses", &[_][]const u8{ "reality", "prediction", "commentary" }, &list);

    const entries = try list.toOwnedSlice();
    errdefer freeSnapshot(allocator, entries);

    std.mem.sort(SnapshotEntry, entries, {}, snapshotEntryLessThan);
    return entries;
}

fn snapshotEntryLessThan(_: void, a: SnapshotEntry, b: SnapshotEntry) bool {
    return std.mem.lessThan(u8, a.scope_path, b.scope_path);
}

fn collectGroup(
    allocator: Allocator,
    io: std.Io,
    kb_root: std.Io.Dir,
    group: []const u8, // "markets" or "theses"
    chain_kinds: []const []const u8,
    list: *std.array_list.Managed(SnapshotEntry),
) !void {
    var group_dir = kb_root.openDir(io, group, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer group_dir.close(io);

    var iter = group_dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind != .directory) continue;

        for (chain_kinds) |kind| {
            var path_buf: [512]u8 = undefined;
            const rel = try std.fmt.bufPrint(&path_buf, "{s}/{s}/{s}", .{ group, entry.name, kind });
            try collectChainIfPresent(allocator, io, kb_root, rel, list);
        }
    }
}

fn collectChainIfPresent(
    allocator: Allocator,
    io: std.Io,
    kb_root: std.Io.Dir,
    scope_path: []const u8,
    list: *std.array_list.Managed(SnapshotEntry),
) !void {
    var chain_dir = kb_root.openDir(io, scope_path, .{ .iterate = false }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer chain_dir.close(io);

    // Load branches.json to learn the active branch.
    const branches_data = chain_dir.readFileAlloc(io, "branches.json", allocator, .unlimited) catch |err| switch (err) {
        error.FileNotFound => return, // partially-initialized chain dir — skip.
        else => return err,
    };
    defer allocator.free(branches_data);

    var bf = try branches_mod.parseSlice(allocator, branches_data);
    defer bf.deinit();

    const active = bf.active;

    // Read the active branch to extract head + length.
    var chain = try chain_mod.openRead(allocator, io, chain_dir, active);
    defer chain.deinit();

    var head_hex: ?[64]u8 = null;
    if (chain.head()) |h| {
        var buf: [64]u8 = undefined;
        hexEncodeHash(h, &buf);
        head_hex = buf;
    }

    try list.append(.{
        .scope_path = try allocator.dupe(u8, scope_path),
        .branch = try allocator.dupe(u8, active),
        .head_hash = head_hex,
        .length = chain.len(),
    });
}

fn hexEncodeHash(hash: Hash, out: *[64]u8) void {
    const hex = "0123456789abcdef";
    for (hash, 0..) |b, i| {
        out[i * 2] = hex[b >> 4];
        out[i * 2 + 1] = hex[b & 0xf];
    }
}

/// Write a canonical-JSON encoding of a snapshot slice. Top-level shape:
///
///   {"entries":[
///     {"branch":"main","head_hash":"<hex>|null","length":N,"scope_path":"..."},
///     ...
///   ]}
///
/// Keys alphabetical, no whitespace. Caller is responsible for entries
/// already being sorted by `scope_path` — `snapshotHeads` guarantees this.
pub fn writeSnapshot(entries: []const SnapshotEntry, writer: *std.Io.Writer) !void {
    try writer.writeAll("{\"entries\":[");
    for (entries, 0..) |e, i| {
        if (i > 0) try writer.writeByte(',');
        try writer.writeAll("{\"branch\":\"");
        try writer.writeAll(e.branch);
        try writer.writeAll("\",\"head_hash\":");
        if (e.head_hash) |h| {
            try writer.writeByte('"');
            try writer.writeAll(h[0..]);
            try writer.writeByte('"');
        } else {
            try writer.writeAll("null");
        }
        try writer.print(",\"length\":{d},\"scope_path\":\"", .{e.length});
        try writer.writeAll(e.scope_path);
        try writer.writeAll("\"}");
    }
    try writer.writeAll("]}");
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "Tick.init generates a 26-char Crockford-base32 ULID" {
    const t = Tick.init();
    // Crockford alphabet: 0-9, A-Z minus I, L, O, U.
    for (t.id) |c| {
        const ok = (c >= '0' and c <= '9') or
            (c >= 'A' and c <= 'Z' and c != 'I' and c != 'L' and c != 'O' and c != 'U');
        try std.testing.expect(ok);
    }
}

test "Tick.path composes pre/post/events/rejected paths" {
    const t = Tick.init();
    var buf: [256]u8 = undefined;

    const pre = try t.path(&buf, "./kb", .pre);
    try std.testing.expect(std.mem.endsWith(u8, pre, ".pre.json"));
    try std.testing.expect(std.mem.startsWith(u8, pre, "./kb/.ticks/"));
    try std.testing.expect(std.mem.indexOf(u8, pre, t.id[0..]) != null);

    const post = try t.path(&buf, "./kb", .post);
    try std.testing.expect(std.mem.endsWith(u8, post, ".post.json"));

    const events = try t.path(&buf, "./kb", .events);
    try std.testing.expect(std.mem.endsWith(u8, events, ".events.jsonl"));

    const rejected = try t.path(&buf, "./kb", .rejected);
    try std.testing.expect(std.mem.endsWith(u8, rejected, ".rejected.json"));
}

test "Tick.path threads an absolute kb_root through" {
    const t = Tick.init();
    var buf: [256]u8 = undefined;
    const p = try t.path(&buf, "/var/lib/praescientia/kb", .pre);
    try std.testing.expect(std.mem.startsWith(u8, p, "/var/lib/praescientia/kb/.ticks/"));
}

test "Tick.init produces distinct ids across rapid calls" {
    const a = Tick.init();
    const b = Tick.init();
    // CSPRNG randomness suffix makes collision practically impossible even
    // within the same millisecond.
    try std.testing.expect(!std.mem.eql(u8, &a.id, &b.id));
}

test "snapshotHeads returns one entry per chain in alphabetical scope_path order" {
    const init_mod = @import("init.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try init_mod.initTree(io, tmp.dir, true); // creates SAMPLE market + sample thesis

    const entries = try snapshotHeads(std.testing.allocator, io, tmp.dir);
    defer freeSnapshot(std.testing.allocator, entries);

    // initTree(with_sample=true) materializes:
    //   markets/SAMPLE/reality, markets/SAMPLE/commentary,
    //   theses/sample/reality, theses/sample/prediction, theses/sample/commentary
    // No commentary/global yet (created on first write).
    try std.testing.expectEqual(@as(usize, 5), entries.len);

    // Alphabetical scope_path ordering.
    for (entries[1..], 1..) |e, i| {
        try std.testing.expect(std.mem.lessThan(u8, entries[i - 1].scope_path, e.scope_path));
    }

    // Every entry should name the "main" branch.
    for (entries) |e| try std.testing.expectEqualStrings("main", e.branch);
}

test "snapshotHeads reflects chain growth on subsequent calls" {
    const init_mod = @import("init.zig");
    const predict_mod = @import("predict.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try init_mod.initTree(io, tmp.dir, true);

    const before = try snapshotHeads(std.testing.allocator, io, tmp.dir);
    defer freeSnapshot(std.testing.allocator, before);

    try predict_mod.writePrediction(std.testing.allocator, io, tmp.dir, "sample", 5000, "test");

    const after = try snapshotHeads(std.testing.allocator, io, tmp.dir);
    defer freeSnapshot(std.testing.allocator, after);

    // Find the prediction chain entries in each snapshot.
    var before_pred: ?SnapshotEntry = null;
    var after_pred: ?SnapshotEntry = null;
    for (before) |e| {
        if (std.mem.eql(u8, e.scope_path, "theses/sample/prediction")) before_pred = e;
    }
    for (after) |e| {
        if (std.mem.eql(u8, e.scope_path, "theses/sample/prediction")) after_pred = e;
    }

    try std.testing.expectEqual(@as(usize, 0), before_pred.?.length);
    try std.testing.expectEqual(@as(usize, 1), after_pred.?.length);
    try std.testing.expect(before_pred.?.head_hash == null);
    try std.testing.expect(after_pred.?.head_hash != null);
}

test "snapshotHeads handles an empty kb_root gracefully" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    // No markets/, no theses/, no commentary/global — bare directory.
    const entries = try snapshotHeads(std.testing.allocator, io, tmp.dir);
    defer freeSnapshot(std.testing.allocator, entries);
    try std.testing.expectEqual(@as(usize, 0), entries.len);
}

test "writeSnapshot emits canonical JSON with alphabetical keys" {
    const init_mod = @import("init.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try init_mod.initTree(io, tmp.dir, true);

    const entries = try snapshotHeads(std.testing.allocator, io, tmp.dir);
    defer freeSnapshot(std.testing.allocator, entries);

    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try writeSnapshot(entries, &aw.writer);

    const out = aw.written();
    // Spot-check the canonical shape.
    try std.testing.expect(std.mem.startsWith(u8, out, "{\"entries\":["));
    try std.testing.expect(std.mem.endsWith(u8, out, "]}"));
    // Keys alphabetical: branch < head_hash < length < scope_path.
    try std.testing.expect(std.mem.indexOf(u8, out, "\"branch\":\"main\",\"head_hash\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, ",\"length\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, ",\"scope_path\":\"markets/SAMPLE/commentary\"") != null);
    // Empty chains serialize head_hash as JSON null.
    try std.testing.expect(std.mem.indexOf(u8, out, "\"head_hash\":null") != null);
}

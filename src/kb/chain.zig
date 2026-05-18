//! Knowledge-base chain — wraps txlog.TxLog with branch metadata.

const std = @import("std");
const Allocator = std.mem.Allocator;

const txlog = @import("../txlog.zig");
const branches_mod = @import("branches.zig");
const Hash = @import("../state_chain.zig").Hash;

/// In-memory knowledge-base chain. Wraps a `txlog.TxLog` with a branch identity.
///
/// **Lifetime contract:** Slices and pointers returned by `at`, `tail`,
/// `rangeByHash`, `rangeByTime` reference the in-memory `TxLog`'s backing
/// `array_list.Managed(Tx)`. Any subsequent mutation through a `WriteHandle`
/// can reallocate that backing array and invalidate held references.
/// Callers MUST NOT hold these references across an append.
pub const Chain = struct {
    allocator: Allocator,
    log: txlog.TxLog,
    branch_name: []u8, // owned

    pub fn deinit(self: *Chain) void {
        self.log.deinit();
        self.allocator.free(self.branch_name);
    }

    pub fn head(self: *const Chain) ?Hash {
        if (self.log.len() == 0) return null;
        return self.log.items.items[self.log.len() - 1].hash;
    }

    pub fn len(self: *const Chain) usize {
        return self.log.len();
    }

    /// Returns a pointer to the entry with the given hash, or null. Zero-copy; see Chain lifetime contract.
    pub fn at(self: *const Chain, hash: Hash) ?*const txlog.Tx {
        for (self.log.items.items) |*tx| {
            if (std.mem.eql(u8, &tx.hash, &hash)) return tx;
        }
        return null;
    }

    /// Returns the last `n` entries. Zero-copy slice; see Chain lifetime contract.
    pub fn tail(self: *const Chain, n: usize) []const txlog.Tx {
        const total = self.log.len();
        if (n >= total) return self.log.items.items;
        return self.log.items.items[total - n ..];
    }

    /// Returns the inclusive range `[from, to]` by hash, or null if either is missing or `to` precedes `from`. Zero-copy slice; see Chain lifetime contract.
    pub fn rangeByHash(self: *const Chain, from: Hash, to: Hash) ?[]const txlog.Tx {
        var from_idx: ?usize = null;
        var to_idx: ?usize = null;
        for (self.log.items.items, 0..) |*tx, i| {
            if (from_idx == null and std.mem.eql(u8, &tx.hash, &from)) from_idx = i;
            if (std.mem.eql(u8, &tx.hash, &to)) to_idx = i;
        }
        if (from_idx == null or to_idx == null) return null;
        if (to_idx.? < from_idx.?) return null;
        return self.log.items.items[from_idx.? .. to_idx.? + 1];
    }

    /// Returns entries whose timestamp falls in `[from_ms, to_ms]`. Zero-copy slice; see Chain lifetime contract.
    pub fn rangeByTime(self: *const Chain, from_ms: u64, to_ms: u64) []const txlog.Tx {
        _ = self;
        _ = from_ms;
        _ = to_ms;
        return &.{}; // implemented after payload ts-parsing is in place (Task 1.13)
    }
};

pub fn openRead(allocator: Allocator, io: std.Io, dir: std.Io.Dir, branch: []const u8) !Chain {
    var file_name_buf: [256]u8 = undefined;
    const file_name = try std.fmt.bufPrint(&file_name_buf, "{s}.jsonl", .{branch});

    const data = dir.readFileAlloc(io, file_name, allocator, .unlimited) catch |err| switch (err) {
        error.FileNotFound => return error.BranchNotFound,
        else => return err,
    };
    defer allocator.free(data);

    var log = try txlog.TxLog.parseSlice(allocator, data);
    errdefer log.deinit();

    return .{
        .allocator = allocator,
        .log = log,
        .branch_name = try allocator.dupe(u8, branch),
    };
}

test "openRead loads an existing branch's JSONL" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;

    // Hand-craft a one-entry JSONL using TxLog directly.
    var src: txlog.TxLog = .init(std.testing.allocator);
    defer src.deinit();
    _ = try src.append("{\"v\":1}");

    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try src.writeAll(&aw.writer);

    try tmp.dir.writeFile(io, .{ .sub_path = "main.jsonl", .data = aw.written() });

    var chain = try openRead(std.testing.allocator, io, tmp.dir, "main");
    defer chain.deinit();
    try std.testing.expectEqual(@as(usize, 1), chain.len());
    try std.testing.expect(chain.head() != null);
}

test "tail returns last N entries; rangeByHash bounds inclusive" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    var src: txlog.TxLog = .init(std.testing.allocator);
    defer src.deinit();
    _ = try src.append("{\"v\":1}");
    _ = try src.append("{\"v\":2}");
    _ = try src.append("{\"v\":3}");

    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try src.writeAll(&aw.writer);
    try tmp.dir.writeFile(io, .{ .sub_path = "main.jsonl", .data = aw.written() });

    var chain = try openRead(std.testing.allocator, io, tmp.dir, "main");
    defer chain.deinit();

    try std.testing.expectEqual(@as(usize, 2), chain.tail(2).len);
    try std.testing.expectEqualStrings("{\"v\":3}", chain.tail(1)[0].payload);

    const h0 = src.items.items[0].hash;
    const h2 = src.items.items[2].hash;
    const r = chain.rangeByHash(h0, h2).?;
    try std.testing.expectEqual(@as(usize, 3), r.len);

    // at: hit + miss
    try std.testing.expect(chain.at(h0) != null);
    try std.testing.expect(chain.at(@as(Hash, @splat(0xFF))) == null);

    // tail edge cases
    try std.testing.expectEqual(@as(usize, 0), chain.tail(0).len);
    try std.testing.expectEqual(@as(usize, 3), chain.tail(99).len);

    // rangeByHash edge cases
    try std.testing.expect(chain.rangeByHash(h2, h0) == null); // inverted: to before from
    try std.testing.expect(chain.rangeByHash(h0, @as(Hash, @splat(0xFF))) == null); // to missing
    const single = chain.rangeByHash(h0, h0).?;
    try std.testing.expectEqual(@as(usize, 1), single.len);

    // rangeByTime is stubbed; assert empty for now
    try std.testing.expectEqual(@as(usize, 0), chain.rangeByTime(0, 1).len);
}

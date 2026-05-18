//! Knowledge-base chain — wraps txlog.TxLog with branch metadata.

const std = @import("std");
const Allocator = std.mem.Allocator;

const txlog = @import("../txlog.zig");
const branches_mod = @import("branches.zig");
const Hash = @import("../state_chain.zig").Hash;
const hash_hex_len = txlog.hash_hex_len;

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
    try branches_mod.validateBranchName(branch);
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

pub const WriteHandle = struct {
    allocator: Allocator,
    chain: Chain,
    file: std.Io.File, // holds the exclusive lock for the lifetime of the handle
    io: std.Io,
    branch_file_name: []u8,
    /// Set to true when a file-write or sync fails after the in-memory chain
    /// has already advanced. Once poisoned, further appends fail fast with
    /// `error.HandlePoisoned` to prevent on-disk corruption from subsequent
    /// entries chained against an unwritten predecessor.
    poisoned: bool = false,

    pub fn deinit(self: *WriteHandle) void {
        // Closing the file releases the advisory lock (POSIX flock semantics).
        self.file.close(self.io);
        self.chain.deinit();
        self.allocator.free(self.branch_file_name);
    }

    pub fn append(self: *WriteHandle, canonical_json: []const u8) !*const txlog.Tx {
        if (self.poisoned) return error.HandlePoisoned;

        const tx = try self.chain.log.append(canonical_json);

        var line_buf: std.Io.Writer.Allocating = .init(self.allocator);
        defer line_buf.deinit();

        // Emit exactly this one tx via the existing txlog wire format.
        var prev_hex: [hash_hex_len]u8 = undefined;
        var hash_hex: [hash_hex_len]u8 = undefined;
        _ = std.fmt.bufPrint(&prev_hex, "{x}", .{tx.prev_hash}) catch unreachable;
        _ = std.fmt.bufPrint(&hash_hex, "{x}", .{tx.hash}) catch unreachable;
        try line_buf.writer.print(
            "{{\"tx_id\":\"{s}\",\"prev_hash\":\"{s}\",\"hash\":\"{s}\",\"payload\":{s}}}\n",
            .{ tx.tx_id, prev_hex, hash_hex, tx.payload },
        );

        // Persist to disk. On failure, mark the handle poisoned so subsequent
        // appends fail fast (in-memory state and disk are now divergent).
        // Positional writes (no seek-from-end on std.Io.File in Zig 0.16) also
        // avoid races with any concurrent positioned readers we may add later.
        const eof = self.file.length(self.io) catch |err| {
            self.poisoned = true;
            return err;
        };
        self.file.writePositionalAll(self.io, line_buf.written(), eof) catch |err| {
            self.poisoned = true;
            return err;
        };
        self.file.sync(self.io) catch |err| { // fdatasync on POSIX; fallback on others.
            self.poisoned = true;
            return err;
        };

        return tx;
    }
};

pub fn openForWrite(allocator: Allocator, io: std.Io, dir: std.Io.Dir, branch: []const u8) !WriteHandle {
    try branches_mod.validateBranchName(branch);
    var file_name_buf: [256]u8 = undefined;
    const file_name = try std.fmt.bufPrint(&file_name_buf, "{s}.jsonl", .{branch});

    var file = dir.openFile(io, file_name, .{ .mode = .read_write }) catch |err| switch (err) {
        error.FileNotFound => try dir.createFile(io, file_name, .{ .read = true, .truncate = false }),
        else => return err,
    };
    errdefer file.close(io);

    // Advisory exclusive lock, non-blocking. tryLock returns false on contention;
    // surface that as error.AlreadyLocked so callers can fail fast.
    if (!try file.tryLock(io, .exclusive)) return error.AlreadyLocked;

    // Self-heal a torn tail from a prior crashed writer.
    try recoverTornTail(allocator, io, dir, file_name);

    // Load existing chain content. We hold the exclusive lock, so reading via the
    // dir (separate fd, same inode) is race-free with any well-behaved writer.
    const data = try dir.readFileAlloc(io, file_name, allocator, .unlimited);
    defer allocator.free(data);

    var log = try txlog.TxLog.parseSlice(allocator, data);
    errdefer log.deinit();

    const branch_file_name_owned = try allocator.dupe(u8, file_name);
    errdefer allocator.free(branch_file_name_owned);

    const branch_name_owned = try allocator.dupe(u8, branch);
    // No errdefer needed for branch_name_owned — this is the last fallible op.

    return .{
        .allocator = allocator,
        .chain = .{
            .allocator = allocator,
            .log = log,
            .branch_name = branch_name_owned,
        },
        .file = file,
        .io = io,
        .branch_file_name = branch_file_name_owned,
        .poisoned = false,
    };
}

test "openForWrite acquires an exclusive lock; second open fails fast" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;

    // Empty branch file is acceptable — chain is empty, head = null.
    try tmp.dir.writeFile(io, .{ .sub_path = "main.jsonl", .data = "" });

    var h1 = try openForWrite(std.testing.allocator, io, tmp.dir, "main");
    defer h1.deinit();

    const err = openForWrite(std.testing.allocator, io, tmp.dir, "main");
    try std.testing.expectError(error.AlreadyLocked, err);
}

test "openForWrite releases the lock on deinit" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.writeFile(io, .{ .sub_path = "main.jsonl", .data = "" });

    {
        var h1 = try openForWrite(std.testing.allocator, io, tmp.dir, "main");
        h1.deinit(); // explicit deinit before scope exit
    }

    // Second open must now succeed — the prior lock was released.
    var h2 = try openForWrite(std.testing.allocator, io, tmp.dir, "main");
    defer h2.deinit();
}

test "openRead rejects invalid branch names" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try std.testing.expectError(
        error.InvalidBranchName,
        openRead(std.testing.allocator, io, tmp.dir, "../evil"),
    );
}

test "openForWrite rejects invalid branch names" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try std.testing.expectError(
        error.InvalidBranchName,
        openForWrite(std.testing.allocator, io, tmp.dir, "../evil"),
    );
}

test "append rejects further writes when WriteHandle is poisoned" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.writeFile(io, .{ .sub_path = "main.jsonl", .data = "" });

    var h = try openForWrite(std.testing.allocator, io, tmp.dir, "main");
    defer h.deinit();

    _ = try h.append("{\"v\":1}");
    try std.testing.expectEqual(@as(usize, 1), h.chain.len());

    h.poisoned = true;
    try std.testing.expectError(error.HandlePoisoned, h.append("{\"v\":2}"));
}

test "append writes a JSONL line, fdatasyncs, and updates the in-memory chain" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.writeFile(io, .{ .sub_path = "main.jsonl", .data = "" });

    var h = try openForWrite(std.testing.allocator, io, tmp.dir, "main");
    defer h.deinit();

    _ = try h.append("{\"kind\":\"market.reality\",\"ts\":1,\"yes_bid_cents\":50,\"yes_ask_cents\":51}");
    try std.testing.expectEqual(@as(usize, 1), h.chain.len());

    // File on disk has exactly one line.
    const buf = try tmp.dir.readFileAlloc(io, "main.jsonl", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(buf);
    var line_count: usize = 0;
    for (buf) |c| if (c == '\n') {
        line_count += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), line_count);
}

/// Recover from a torn write at the tail of `branch_file_name`.
///
/// Opens the file read+write and inspects its current contents through a
/// separate read fd on the same inode. When invoked from `openForWrite` this
/// is race-free because the caller holds the exclusive advisory lock; the
/// separate-fd read just observes bytes on the same inode. Anything after
/// the last `\n` is a torn partial line and is truncated. If the remaining
/// content still fails hash-chain validation (rare: power loss between write
/// and `fsync`), the last complete line is peeled off and the file is
/// truncated to the preceding newline.
pub fn recoverTornTail(allocator: Allocator, io: std.Io, dir: std.Io.Dir, branch_file_name: []const u8) !void {
    var file = try dir.openFile(io, branch_file_name, .{ .mode = .read_write });
    defer file.close(io);

    // Read current contents via a separate fd through the directory — same
    // inode. Safe under the caller's lock (see doc comment).
    const data = try dir.readFileAlloc(io, branch_file_name, allocator, .unlimited);
    defer allocator.free(data);

    if (data.len == 0) return;

    // Find the last newline; anything after it is a torn write.
    const last_nl = std.mem.lastIndexOfScalar(u8, data, '\n');
    if (last_nl == null) {
        // No newline at all — the entire file is a torn partial line.
        try file.setLength(io, 0);
        return;
    }
    const valid_len = last_nl.? + 1;
    if (valid_len < data.len) {
        try file.setLength(io, valid_len);
    }

    // Additionally, validate the truncated chain — if the LAST complete line
    // is itself hash-broken (rare: power loss between write and sync), peel it.
    const trimmed = data[0..valid_len];
    var probe = txlog.TxLog.parseSlice(allocator, trimmed) catch |err| switch (err) {
        error.HashMismatch, error.PrevHashBroken => {
            // Drop the last newline-terminated line and re-validate.
            // `trimmed` ends in '\n' at index valid_len - 1; search before it.
            const prior_nl = std.mem.lastIndexOfScalar(u8, trimmed[0 .. valid_len - 1], '\n');
            const new_len: usize = if (prior_nl) |i| i + 1 else 0;
            try file.setLength(io, new_len);
            return;
        },
        else => return err,
    };
    probe.deinit();
}

test "recoverTornTail truncates a malformed final line" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;

    // Build a well-formed two-line JSONL then append a torn third line.
    var src: txlog.TxLog = .init(std.testing.allocator);
    defer src.deinit();
    _ = try src.append("{\"v\":1}");
    _ = try src.append("{\"v\":2}");
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try src.writeAll(&aw.writer);

    var full = std.array_list.Managed(u8).init(std.testing.allocator);
    defer full.deinit();
    try full.appendSlice(aw.written());
    try full.appendSlice("{\"tx_id\":\"tx_BROKE"); // torn line, no newline

    try tmp.dir.writeFile(io, .{ .sub_path = "main.jsonl", .data = full.items });

    try recoverTornTail(std.testing.allocator, io, tmp.dir, "main.jsonl");

    // After recovery, file parses cleanly and has exactly 2 entries.
    const after = try tmp.dir.readFileAlloc(io, "main.jsonl", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(after);
    var parsed = try txlog.TxLog.parseSlice(std.testing.allocator, after);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 2), parsed.len());
}

test "openForWrite self-heals a torn-tail chain" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;

    // Build a valid 2-line JSONL via TxLog, then append a torn line.
    var src: txlog.TxLog = .init(std.testing.allocator);
    defer src.deinit();
    _ = try src.append("{\"v\":1}");
    _ = try src.append("{\"v\":2}");

    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try src.writeAll(&aw.writer);

    var full = std.array_list.Managed(u8).init(std.testing.allocator);
    defer full.deinit();
    try full.appendSlice(aw.written());
    try full.appendSlice("{\"tx_id\":\"tx_TORN");
    try tmp.dir.writeFile(io, .{ .sub_path = "main.jsonl", .data = full.items });

    // openForWrite must now self-heal and return a handle with 2 entries.
    var h = try openForWrite(std.testing.allocator, io, tmp.dir, "main");
    defer h.deinit();
    try std.testing.expectEqual(@as(usize, 2), h.chain.len());
}

test "golden lifecycle: write 3 -> fork at idx1 -> switchActive -> recover torn tail" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;

    // Seed empty main + branches.json.
    try tmp.dir.writeFile(io, .{ .sub_path = "main.jsonl", .data = "" });
    try tmp.dir.writeFile(io, .{
        .sub_path = "branches.json",
        .data =
        \\{"active":"main","branches":[{"name":"main","head_hash":"0000000000000000000000000000000000000000000000000000000000000000","parent_hash":"0000000000000000000000000000000000000000000000000000000000000000","parent_branch":"","created_ts_ms":0}]}
        ,
    });

    // 1. Write 3 entries on main.
    var fork_at_hash: Hash = undefined;
    {
        var h = try openForWrite(std.testing.allocator, io, tmp.dir, "main");
        defer h.deinit();
        _ = try h.append("{\"kind\":\"market.reality\",\"ts\":1,\"yes_bid_cents\":50}");
        const tx2 = try h.append("{\"kind\":\"market.reality\",\"ts\":2,\"yes_bid_cents\":55}");
        fork_at_hash = tx2.hash;
        _ = try h.append("{\"kind\":\"market.reality\",\"ts\":3,\"yes_bid_cents\":60}");
    }

    // 2. Fork at idx 1 -> exp-a.
    try branches_mod.fork(std.testing.allocator, io, tmp.dir, "main", fork_at_hash, "exp-a");

    // 3. Switch active to exp-a.
    try branches_mod.switchActive(std.testing.allocator, io, tmp.dir, "exp-a");

    // 4. exp-a chain has 2 entries; main still has 3.
    var exp_a = try openRead(std.testing.allocator, io, tmp.dir, "exp-a");
    defer exp_a.deinit();
    try std.testing.expectEqual(@as(usize, 2), exp_a.len());

    var main_chain = try openRead(std.testing.allocator, io, tmp.dir, "main");
    defer main_chain.deinit();
    try std.testing.expectEqual(@as(usize, 3), main_chain.len());

    // 5. Append a 3rd entry to exp-a, then simulate a torn write.
    {
        var h = try openForWrite(std.testing.allocator, io, tmp.dir, "exp-a");
        defer h.deinit();
        _ = try h.append("{\"kind\":\"market.reality\",\"ts\":4,\"yes_bid_cents\":58}");
    }
    {
        var f = try tmp.dir.openFile(io, "exp-a.jsonl", .{ .mode = .read_write });
        defer f.close(io);
        // std.Io.File has no seekFromEnd in 0.16 - use length() + writePositionalAll.
        const eof = try f.length(io);
        try f.writePositionalAll(io, "{\"tx_id\":\"tx_TORN_", eof);
    }

    try recoverTornTail(std.testing.allocator, io, tmp.dir, "exp-a.jsonl");

    var exp_a_recovered = try openRead(std.testing.allocator, io, tmp.dir, "exp-a");
    defer exp_a_recovered.deinit();
    try std.testing.expectEqual(@as(usize, 3), exp_a_recovered.len());
}

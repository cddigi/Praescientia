//! Branch metadata for kb chains. Each chain directory contains one
//! `branches.json` file enumerating its branches; each branch is a separate
//! JSONL file in the same directory.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Hash = @import("../state_chain.zig").Hash;
const hash_hex_len = 64;

pub const BranchInfo = struct {
    name: []const u8,
    head_hash: Hash,
    parent_hash: Hash,
    parent_branch: []const u8, // empty string for the root branch
    created_ts_ms: u64,
};

pub const BranchesFile = struct {
    allocator: Allocator,
    active: []const u8, // name of the default branch for reads
    branches: []BranchInfo,

    pub fn deinit(self: *BranchesFile) void {
        for (self.branches) |b| {
            self.allocator.free(b.name);
            self.allocator.free(b.parent_branch);
        }
        self.allocator.free(self.branches);
        self.allocator.free(self.active);
    }
};

pub fn parseSlice(allocator: Allocator, json: []const u8) !BranchesFile {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    const active_src = root.get("active").?.string;
    const list = root.get("branches").?.array;

    const branches = try allocator.alloc(BranchInfo, list.items.len);
    errdefer allocator.free(branches);

    for (list.items, 0..) |item, i| {
        const obj = item.object;
        const name = try allocator.dupe(u8, obj.get("name").?.string);
        errdefer allocator.free(name);
        const parent_branch = try allocator.dupe(u8, obj.get("parent_branch").?.string);
        errdefer allocator.free(parent_branch);

        var head_hash: Hash = undefined;
        try hexDecode(obj.get("head_hash").?.string, &head_hash);
        var parent_hash: Hash = undefined;
        try hexDecode(obj.get("parent_hash").?.string, &parent_hash);

        branches[i] = .{
            .name = name,
            .head_hash = head_hash,
            .parent_hash = parent_hash,
            .parent_branch = parent_branch,
            .created_ts_ms = @intCast(obj.get("created_ts_ms").?.integer),
        };
    }

    return .{
        .allocator = allocator,
        .active = try allocator.dupe(u8, active_src),
        .branches = branches,
    };
}

fn hexDecode(hex: []const u8, out: *Hash) !void {
    if (hex.len != hash_hex_len) return error.WrongHexLength;
    for (out, 0..) |*byte, i| {
        const hi = try hexNibble(hex[i * 2]);
        const lo = try hexNibble(hex[i * 2 + 1]);
        byte.* = (hi << 4) | lo;
    }
}

fn hexNibble(c: u8) !u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => 10 + c - 'a',
        'A'...'F' => 10 + c - 'A',
        else => error.InvalidHex,
    };
}

fn validateBranchName(name: []const u8) !void {
    for (name) |c| {
        if (c == '"' or c == '\\' or c < 0x20) return error.InvalidBranchName;
    }
}

pub fn writeSlice(allocator: Allocator, bf: *const BranchesFile) ![]u8 {
    try validateBranchName(bf.active);
    for (bf.branches) |b| {
        try validateBranchName(b.name);
        try validateBranchName(b.parent_branch);
    }

    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    const w = &aw.writer;

    try w.print("{{\"active\":\"{s}\",\"branches\":[", .{bf.active});
    for (bf.branches, 0..) |b, i| {
        if (i > 0) try w.writeByte(',');
        var head_hex: [hash_hex_len]u8 = undefined;
        var parent_hex: [hash_hex_len]u8 = undefined;
        _ = std.fmt.bufPrint(&head_hex, "{x}", .{b.head_hash}) catch unreachable;
        _ = std.fmt.bufPrint(&parent_hex, "{x}", .{b.parent_hash}) catch unreachable;
        try w.print(
            "{{\"name\":\"{s}\",\"head_hash\":\"{s}\",\"parent_hash\":\"{s}\",\"parent_branch\":\"{s}\",\"created_ts_ms\":{d}}}",
            .{ b.name, head_hex, parent_hex, b.parent_branch, b.created_ts_ms },
        );
    }
    try w.writeAll("]}");
    return aw.toOwnedSlice();
}

test "writeSlice + parseSlice round-trip is stable" {
    const original_json =
        \\{"active":"main","branches":[{"name":"main","head_hash":"0000000000000000000000000000000000000000000000000000000000000000","parent_hash":"0000000000000000000000000000000000000000000000000000000000000000","parent_branch":"","created_ts_ms":1747500000000}]}
    ;
    var bf = try parseSlice(std.testing.allocator, original_json);
    defer bf.deinit();

    const round = try writeSlice(std.testing.allocator, &bf);
    defer std.testing.allocator.free(round);

    try std.testing.expectEqualStrings(original_json, round);

    var bf2 = try parseSlice(std.testing.allocator, round);
    defer bf2.deinit();

    try std.testing.expectEqualStrings(bf.active, bf2.active);
    try std.testing.expectEqual(bf.branches.len, bf2.branches.len);
    try std.testing.expectEqualSlices(u8, &bf.branches[0].head_hash, &bf2.branches[0].head_hash);
}

test "parseSlice round-trips a two-branch file" {
    const json =
        \\{"active":"main","branches":[
        \\{"name":"main","head_hash":"0000000000000000000000000000000000000000000000000000000000000000",
        \\"parent_hash":"0000000000000000000000000000000000000000000000000000000000000000",
        \\"parent_branch":"","created_ts_ms":1747500000000},
        \\{"name":"fork-a","head_hash":"abababababababababababababababababababababababababababababababab",
        \\"parent_hash":"cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd",
        \\"parent_branch":"main","created_ts_ms":1747510000000}
        \\]}
    ;
    var bf = try parseSlice(std.testing.allocator, json);
    defer bf.deinit();
    try std.testing.expectEqualStrings("main", bf.active);
    try std.testing.expectEqual(@as(usize, 2), bf.branches.len);
    try std.testing.expectEqualStrings("fork-a", bf.branches[1].name);
    try std.testing.expectEqualStrings("main", bf.branches[1].parent_branch);
}

test "writeSlice rejects branch names with JSON-special characters" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const sa = arena.allocator();

    const branches = try sa.alloc(BranchInfo, 1);
    branches[0] = .{
        .name = try sa.dupe(u8, "evil\"name"),
        .head_hash = @splat(0),
        .parent_hash = @splat(0),
        .parent_branch = try sa.dupe(u8, ""),
        .created_ts_ms = 0,
    };
    const bf = BranchesFile{
        .allocator = sa,
        .active = try sa.dupe(u8, "main"),
        .branches = branches,
    };

    try std.testing.expectError(error.InvalidBranchName, writeSlice(std.testing.allocator, &bf));
}

pub fn atomicWrite(dir: std.Io.Dir, io: std.Io, bf: *const BranchesFile, scratch: Allocator) !void {
    const bytes = try writeSlice(scratch, bf);
    defer scratch.free(bytes);

    var tmp_name_buf: [64]u8 = undefined;
    const nanos = std.Io.Clock.awake.now(io).nanoseconds;
    const tmp_name = try std.fmt.bufPrint(&tmp_name_buf, ".branches.json.tmp.{d}", .{nanos});

    {
        var f = try dir.createFile(io, tmp_name, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, bytes);
        try f.sync(io);
    }
    try dir.rename(tmp_name, dir, "branches.json", io);
}

test "atomicWrite produces a parseable branches.json" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const sa = arena.allocator();

    const branches = try sa.alloc(BranchInfo, 1);
    branches[0] = .{
        .name = try sa.dupe(u8, "main"),
        .head_hash = @splat(0),
        .parent_hash = @splat(0),
        .parent_branch = try sa.dupe(u8, ""),
        .created_ts_ms = 1747500000000,
    };
    const bf = BranchesFile{
        .allocator = sa,
        .active = try sa.dupe(u8, "main"),
        .branches = branches,
    };

    try atomicWrite(tmp.dir, std.testing.io, &bf, std.testing.allocator);

    const buf = try tmp.dir.readFileAlloc(std.testing.io, "branches.json", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(buf);
    var parsed = try parseSlice(std.testing.allocator, buf);
    defer parsed.deinit();
    try std.testing.expectEqualStrings("main", parsed.active);
}

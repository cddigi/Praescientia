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

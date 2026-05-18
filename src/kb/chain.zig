//! Knowledge-base chain — wraps txlog.TxLog with branch metadata.

const std = @import("std");
const Allocator = std.mem.Allocator;

const txlog = @import("../txlog.zig");
const branches_mod = @import("branches.zig");
const Hash = @import("../state_chain.zig").Hash;

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

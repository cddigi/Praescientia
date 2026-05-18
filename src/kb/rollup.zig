//! Compile-time registry of rollup functions. Each thesis manifest names a
//! rollup by string; the registry resolves names to function pointers.

const std = @import("std");

pub const MarketSnapshotForRollup = struct {
    ticker: []const u8,
    yes_bid_cents: u32,
    yes_ask_cents: u32,
    head_hash_hex: []const u8,
};

pub const RollupInput = struct {
    sources: []const MarketSnapshotForRollup,
    weights_bp: []const u32, // parallel to sources, sums to 10000 (validated by caller)
};

pub const RollupResult = struct {
    aggregate_yes_cents: u32,
};

pub const RollupFn = *const fn (input: RollupInput) RollupResult;

pub var registry: std.StringHashMapUnmanaged(RollupFn) = .empty;

pub fn register(allocator: std.mem.Allocator, name: []const u8, f: RollupFn) !void {
    try registry.put(allocator, name, f);
}

pub fn lookup(name: []const u8) ?RollupFn {
    return registry.get(name);
}

fn dummyV1(input: RollupInput) RollupResult {
    _ = input;
    return .{ .aggregate_yes_cents = 0 };
}

test "register + lookup round-trip" {
    try register(std.testing.allocator, "dummy_v1", &dummyV1);
    defer registry.deinit(std.testing.allocator);

    const f = lookup("dummy_v1").?;
    const r = f(.{ .sources = &.{}, .weights_bp = &.{} });
    try std.testing.expectEqual(@as(u32, 0), r.aggregate_yes_cents);
}

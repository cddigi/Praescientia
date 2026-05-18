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

/// Weighted mid-price aggregator. Each source contributes (yes_bid + yes_ask)/2,
/// weighted by its basis-point weight. `weights_bp` must be parallel to `sources`;
/// a 0 total weight yields 0.
pub fn weightedAvgV1(input: RollupInput) RollupResult {
    std.debug.assert(input.sources.len == input.weights_bp.len);
    var total: u64 = 0;
    var weight_total: u64 = 0;
    for (input.sources, input.weights_bp) |src, w| {
        const mid = (@as(u64, src.yes_bid_cents) + @as(u64, src.yes_ask_cents)) / 2;
        total += mid * @as(u64, w);
        weight_total += w;
    }
    if (weight_total == 0) return .{ .aggregate_yes_cents = 0 };
    return .{ .aggregate_yes_cents = @intCast(total / weight_total) };
}

test "weighted_avg_v1 averages by basis-point weights" {
    const sources = [_]MarketSnapshotForRollup{
        .{ .ticker = "A", .yes_bid_cents = 60, .yes_ask_cents = 62, .head_hash_hex = "aa" ** 32 },
        .{ .ticker = "B", .yes_bid_cents = 40, .yes_ask_cents = 42, .head_hash_hex = "bb" ** 32 },
    };
    const weights = [_]u32{ 7000, 3000 };
    const r = weightedAvgV1(.{ .sources = &sources, .weights_bp = &weights });
    // mid-prices: (60+62)/2 = 61, (40+42)/2 = 41
    // weighted: 0.7*61 + 0.3*41 = 42.7 + 12.3 = 55
    try std.testing.expectEqual(@as(u32, 55), r.aggregate_yes_cents);
}

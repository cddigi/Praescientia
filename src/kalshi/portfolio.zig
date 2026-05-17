//! Kalshi `/portfolio/*` endpoints — all require authentication.
//!
//! Position/settlement/fill entries are kept as `std.json.Value` rather than
//! frozen structs: the demo account at fixture-capture time was empty, so the
//! real per-entry shape can't be locked down without speculative typing.

const std = @import("std");
const client_mod = @import("client.zig");

const Allocator = std.mem.Allocator;
const Client = client_mod.Client;
const QueryParam = client_mod.QueryParam;

pub const BalanceBreakdown = struct {
    balance: []const u8 = "",
    exchange_index: i64 = 0,
};

pub const Balance = struct {
    balance: i64,
    balance_breakdown: []BalanceBreakdown = &.{},
    portfolio_value: i64 = 0,
    updated_ts: i64 = 0,
};

pub const PositionsList = struct {
    cursor: []const u8 = "",
    event_positions: []std.json.Value = &.{},
    market_positions: []std.json.Value = &.{},
};

pub const SettlementsList = struct {
    cursor: []const u8 = "",
    settlements: []std.json.Value = &.{},
};

pub const FillsList = struct {
    cursor: []const u8 = "",
    fills: []std.json.Value = &.{},
};

pub const ListOptions = struct {
    limit: ?u32 = null,
    cursor: ?[]const u8 = null,
    ticker: ?[]const u8 = null,
    event_ticker: ?[]const u8 = null,
    min_ts: ?i64 = null,
    max_ts: ?i64 = null,
};

/// GET /portfolio/balance
pub fn balance(client: *Client, arena: Allocator) !Balance {
    return getJson(Balance, client, arena, "/portfolio/balance", &.{});
}

/// GET /portfolio/positions
pub fn positions(client: *Client, arena: Allocator, opts: ListOptions) !PositionsList {
    return getJson(PositionsList, client, arena, "/portfolio/positions", try queryFromList(arena, opts));
}

/// GET /portfolio/settlements
pub fn settlements(client: *Client, arena: Allocator, opts: ListOptions) !SettlementsList {
    return getJson(SettlementsList, client, arena, "/portfolio/settlements", try queryFromList(arena, opts));
}

/// GET /portfolio/fills
pub fn fills(client: *Client, arena: Allocator, opts: ListOptions) !FillsList {
    return getJson(FillsList, client, arena, "/portfolio/fills", try queryFromList(arena, opts));
}

fn getJson(
    comptime T: type,
    client: *Client,
    arena: Allocator,
    path: []const u8,
    query: []const QueryParam,
) !T {
    if (!client.hasCredentials()) return error.MissingCredentials;
    const resp = try client.request(arena, .{ .path = path, .query = query });
    if (!resp.isSuccess()) return error.HttpStatus;
    return resp.parseInto(T, arena);
}

fn queryFromList(arena: Allocator, opts: ListOptions) ![]const QueryParam {
    var q: std.array_list.Managed(QueryParam) = .init(arena);
    if (opts.limit) |v| try q.append(.{ .key = "limit", .value = try std.fmt.allocPrint(arena, "{d}", .{v}) });
    if (opts.cursor) |v| try q.append(.{ .key = "cursor", .value = v });
    if (opts.ticker) |v| try q.append(.{ .key = "ticker", .value = v });
    if (opts.event_ticker) |v| try q.append(.{ .key = "event_ticker", .value = v });
    if (opts.min_ts) |v| try q.append(.{ .key = "min_ts", .value = try std.fmt.allocPrint(arena, "{d}", .{v}) });
    if (opts.max_ts) |v| try q.append(.{ .key = "max_ts", .value = try std.fmt.allocPrint(arena, "{d}", .{v}) });
    return q.items;
}

const fixture_balance = @embedFile("testdata/portfolio_balance.json");
const fixture_positions = @embedFile("testdata/portfolio_positions.json");
const fixture_settlements = @embedFile("testdata/portfolio_settlements.json");
const fixture_fills = @embedFile("testdata/portfolio_fills.json");

test "parses /portfolio/balance fixture" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const parsed = try std.json.parseFromSliceLeaky(Balance, a, fixture_balance, .{ .ignore_unknown_fields = true });
    try std.testing.expect(parsed.balance >= 0);
    try std.testing.expect(parsed.balance_breakdown.len > 0);
    try std.testing.expectEqualStrings("100.0000", parsed.balance_breakdown[0].balance);
}

test "parses /portfolio/positions fixture (empty arrays)" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const parsed = try std.json.parseFromSliceLeaky(PositionsList, a, fixture_positions, .{ .ignore_unknown_fields = true });
    try std.testing.expectEqual(@as(usize, 0), parsed.market_positions.len);
    try std.testing.expectEqual(@as(usize, 0), parsed.event_positions.len);
}

test "parses /portfolio/settlements fixture" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const parsed = try std.json.parseFromSliceLeaky(SettlementsList, a, fixture_settlements, .{ .ignore_unknown_fields = true });
    try std.testing.expectEqual(@as(usize, 0), parsed.settlements.len);
}

test "parses /portfolio/fills fixture" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const parsed = try std.json.parseFromSliceLeaky(FillsList, a, fixture_fills, .{ .ignore_unknown_fields = true });
    try std.testing.expectEqual(@as(usize, 0), parsed.fills.len);
}

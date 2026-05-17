//! Kalshi `/historical/*` and historical-data endpoints.
//! All require authentication.

const std = @import("std");
const client_mod = @import("client.zig");

const Allocator = std.mem.Allocator;
const Client = client_mod.Client;
const QueryParam = client_mod.QueryParam;

pub const Cutoff = struct {
    market_settled_ts: []const u8 = "",
    orders_updated_ts: []const u8 = "",
    trades_created_ts: []const u8 = "",
};

pub const TradesList = struct {
    cursor: []const u8 = "",
    trades: []std.json.Value = &.{},
};

pub const ListOptions = struct {
    limit: ?u32 = null,
    cursor: ?[]const u8 = null,
    ticker: ?[]const u8 = null,
    min_ts: ?i64 = null,
    max_ts: ?i64 = null,
};

/// GET /historical/cutoff — latest historical-data freshness markers.
pub fn cutoff(client: *Client, arena: Allocator) !Cutoff {
    if (!client.hasCredentials()) return error.MissingCredentials;
    const resp = try client.request(arena, .{ .path = "/historical/cutoff" });
    if (!resp.isSuccess()) return error.HttpStatus;
    return resp.parseInto(Cutoff, arena);
}

/// GET /markets/trades — recent trades across all markets (public; auth optional).
pub fn marketTrades(client: *Client, arena: Allocator, opts: ListOptions) !TradesList {
    var q: std.array_list.Managed(QueryParam) = .init(arena);
    if (opts.limit) |v| try q.append(.{ .key = "limit", .value = try std.fmt.allocPrint(arena, "{d}", .{v}) });
    if (opts.cursor) |v| try q.append(.{ .key = "cursor", .value = v });
    if (opts.ticker) |v| try q.append(.{ .key = "ticker", .value = v });
    if (opts.min_ts) |v| try q.append(.{ .key = "min_ts", .value = try std.fmt.allocPrint(arena, "{d}", .{v}) });
    if (opts.max_ts) |v| try q.append(.{ .key = "max_ts", .value = try std.fmt.allocPrint(arena, "{d}", .{v}) });

    const resp = try client.request(arena, .{ .path = "/markets/trades", .query = q.items });
    if (!resp.isSuccess()) return error.HttpStatus;
    return resp.parseInto(TradesList, arena);
}

pub const CandlesticksOptions = struct {
    period_interval: ?u32 = null,
    start_ts: ?i64 = null,
    end_ts: ?i64 = null,
};

/// GET /historical/markets/{ticker}/candlesticks
pub fn candlesticks(client: *Client, arena: Allocator, ticker: []const u8, opts: CandlesticksOptions) !std.json.Value {
    if (!client.hasCredentials()) return error.MissingCredentials;
    var q: std.array_list.Managed(QueryParam) = .init(arena);
    if (opts.period_interval) |v| try q.append(.{ .key = "period_interval", .value = try std.fmt.allocPrint(arena, "{d}", .{v}) });
    if (opts.start_ts) |v| try q.append(.{ .key = "start_ts", .value = try std.fmt.allocPrint(arena, "{d}", .{v}) });
    if (opts.end_ts) |v| try q.append(.{ .key = "end_ts", .value = try std.fmt.allocPrint(arena, "{d}", .{v}) });

    const path = try std.fmt.allocPrint(arena, "/historical/markets/{s}/candlesticks", .{ticker});
    const resp = try client.request(arena, .{ .path = path, .query = q.items });
    if (!resp.isSuccess()) return error.HttpStatus;
    return std.json.parseFromSliceLeaky(std.json.Value, arena, resp.body, .{});
}

pub const FillsOptions = struct {
    limit: ?u32 = null,
    cursor: ?[]const u8 = null,
    ticker: ?[]const u8 = null,
    min_ts: ?i64 = null,
    max_ts: ?i64 = null,
};

/// GET /historical/fills — historical fills for the authenticated user.
pub fn fills(client: *Client, arena: Allocator, opts: FillsOptions) !std.json.Value {
    if (!client.hasCredentials()) return error.MissingCredentials;
    var q: std.array_list.Managed(QueryParam) = .init(arena);
    if (opts.limit) |v| try q.append(.{ .key = "limit", .value = try std.fmt.allocPrint(arena, "{d}", .{v}) });
    if (opts.cursor) |v| try q.append(.{ .key = "cursor", .value = v });
    if (opts.ticker) |v| try q.append(.{ .key = "ticker", .value = v });
    if (opts.min_ts) |v| try q.append(.{ .key = "min_ts", .value = try std.fmt.allocPrint(arena, "{d}", .{v}) });
    if (opts.max_ts) |v| try q.append(.{ .key = "max_ts", .value = try std.fmt.allocPrint(arena, "{d}", .{v}) });

    const resp = try client.request(arena, .{ .path = "/historical/fills", .query = q.items });
    if (!resp.isSuccess()) return error.HttpStatus;
    return std.json.parseFromSliceLeaky(std.json.Value, arena, resp.body, .{});
}

pub const OrdersOptions = struct {
    limit: ?u32 = null,
    cursor: ?[]const u8 = null,
    ticker: ?[]const u8 = null,
    status: ?[]const u8 = null,
    min_ts: ?i64 = null,
    max_ts: ?i64 = null,
};

/// GET /historical/orders — archived orders from the historical database.
pub fn orders(client: *Client, arena: Allocator, opts: OrdersOptions) !std.json.Value {
    if (!client.hasCredentials()) return error.MissingCredentials;
    var q: std.array_list.Managed(QueryParam) = .init(arena);
    if (opts.limit) |v| try q.append(.{ .key = "limit", .value = try std.fmt.allocPrint(arena, "{d}", .{v}) });
    if (opts.cursor) |v| try q.append(.{ .key = "cursor", .value = v });
    if (opts.ticker) |v| try q.append(.{ .key = "ticker", .value = v });
    if (opts.status) |v| try q.append(.{ .key = "status", .value = v });
    if (opts.min_ts) |v| try q.append(.{ .key = "min_ts", .value = try std.fmt.allocPrint(arena, "{d}", .{v}) });
    if (opts.max_ts) |v| try q.append(.{ .key = "max_ts", .value = try std.fmt.allocPrint(arena, "{d}", .{v}) });

    const resp = try client.request(arena, .{ .path = "/historical/orders", .query = q.items });
    if (!resp.isSuccess()) return error.HttpStatus;
    return std.json.parseFromSliceLeaky(std.json.Value, arena, resp.body, .{});
}

pub const TradesOptions = struct {
    limit: ?u32 = null,
    cursor: ?[]const u8 = null,
    ticker: ?[]const u8 = null,
    min_ts: ?i64 = null,
    max_ts: ?i64 = null,
};

/// GET /historical/trades — all historical trades across markets.
pub fn trades(client: *Client, arena: Allocator, opts: TradesOptions) !std.json.Value {
    if (!client.hasCredentials()) return error.MissingCredentials;
    var q: std.array_list.Managed(QueryParam) = .init(arena);
    if (opts.limit) |v| try q.append(.{ .key = "limit", .value = try std.fmt.allocPrint(arena, "{d}", .{v}) });
    if (opts.cursor) |v| try q.append(.{ .key = "cursor", .value = v });
    if (opts.ticker) |v| try q.append(.{ .key = "ticker", .value = v });
    if (opts.min_ts) |v| try q.append(.{ .key = "min_ts", .value = try std.fmt.allocPrint(arena, "{d}", .{v}) });
    if (opts.max_ts) |v| try q.append(.{ .key = "max_ts", .value = try std.fmt.allocPrint(arena, "{d}", .{v}) });

    const resp = try client.request(arena, .{ .path = "/historical/trades", .query = q.items });
    if (!resp.isSuccess()) return error.HttpStatus;
    return std.json.parseFromSliceLeaky(std.json.Value, arena, resp.body, .{});
}

pub const MarketsOptions = struct {
    limit: ?u32 = null,
    cursor: ?[]const u8 = null,
    series_ticker: ?[]const u8 = null,
    status: ?[]const u8 = null,
};

/// GET /historical/markets — list of archived markets.
pub fn markets(client: *Client, arena: Allocator, opts: MarketsOptions) !std.json.Value {
    if (!client.hasCredentials()) return error.MissingCredentials;
    var q: std.array_list.Managed(QueryParam) = .init(arena);
    if (opts.limit) |v| try q.append(.{ .key = "limit", .value = try std.fmt.allocPrint(arena, "{d}", .{v}) });
    if (opts.cursor) |v| try q.append(.{ .key = "cursor", .value = v });
    if (opts.series_ticker) |v| try q.append(.{ .key = "series_ticker", .value = v });
    if (opts.status) |v| try q.append(.{ .key = "status", .value = v });

    const resp = try client.request(arena, .{ .path = "/historical/markets", .query = q.items });
    if (!resp.isSuccess()) return error.HttpStatus;
    return std.json.parseFromSliceLeaky(std.json.Value, arena, resp.body, .{});
}

/// GET /historical/markets/{ticker} — single archived market.
pub fn market(client: *Client, arena: Allocator, ticker: []const u8) !std.json.Value {
    if (!client.hasCredentials()) return error.MissingCredentials;
    const path = try std.fmt.allocPrint(arena, "/historical/markets/{s}", .{ticker});
    const resp = try client.request(arena, .{ .path = path });
    if (!resp.isSuccess()) return error.HttpStatus;
    return std.json.parseFromSliceLeaky(std.json.Value, arena, resp.body, .{});
}

const fixture_cutoff = @embedFile("testdata/historical_cutoff.json");
const fixture_trades = @embedFile("testdata/historical_market_trades.json");

test "parses /historical/cutoff fixture" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const parsed = try std.json.parseFromSliceLeaky(Cutoff, a, fixture_cutoff, .{ .ignore_unknown_fields = true });
    try std.testing.expect(parsed.market_settled_ts.len > 0);
}

test "parses /markets/trades fixture" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const parsed = try std.json.parseFromSliceLeaky(TradesList, a, fixture_trades, .{ .ignore_unknown_fields = true });
    try std.testing.expect(parsed.trades.len > 0);
}

test {
    _ = candlesticks;
    _ = fills;
    _ = orders;
    _ = trades;
    _ = markets;
    _ = market;
}

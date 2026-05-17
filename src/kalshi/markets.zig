//! Kalshi `/markets/*` endpoints.
//!
//! Typed surface covers the identity + pricing fields most consumers need;
//! additional fields are silently accepted via `ignore_unknown_fields = true`.
//! For analyses needing the full payload, parse the response body separately
//! as `std.json.Value`.

const std = @import("std");
const client_mod = @import("client.zig");

const Allocator = std.mem.Allocator;
const Client = client_mod.Client;
const QueryParam = client_mod.QueryParam;

/// Kalshi market summary. Prices and volumes are strings (e.g. "0.5000")
/// because Kalshi reports them in decimal-dollars with explicit precision.
pub const Market = struct {
    ticker: []const u8,
    event_ticker: []const u8 = "",
    status: []const u8 = "",
    market_type: []const u8 = "",
    title: []const u8 = "",
    subtitle: []const u8 = "",
    yes_sub_title: ?[]const u8 = null,
    no_sub_title: ?[]const u8 = null,
    yes_bid_dollars: []const u8 = "",
    yes_ask_dollars: []const u8 = "",
    no_bid_dollars: []const u8 = "",
    no_ask_dollars: []const u8 = "",
    last_price_dollars: []const u8 = "",
    volume_fp: []const u8 = "",
    open_interest_fp: []const u8 = "",
    liquidity_dollars: []const u8 = "",
    open_time: []const u8 = "",
    close_time: []const u8 = "",
    expiration_time: []const u8 = "",
};

/// Paginated `/markets` response.
pub const MarketList = struct {
    markets: []Market,
    cursor: ?[]const u8 = null,
};

/// Single-market `/markets/{ticker}` response — Kalshi wraps the market in a
/// `market` key.
pub const MarketWrapped = struct {
    market: Market,
};

pub const ListOptions = struct {
    limit: ?u32 = null,
    cursor: ?[]const u8 = null,
    event_ticker: ?[]const u8 = null,
    series_ticker: ?[]const u8 = null,
    status: ?[]const u8 = null,
    tickers: ?[]const u8 = null,
    min_close_ts: ?i64 = null,
    max_close_ts: ?i64 = null,
};

/// GET /markets — paginated list.
pub fn list(client: *Client, arena: Allocator, opts: ListOptions) !MarketList {
    var query: std.array_list.Managed(QueryParam) = .init(arena);
    if (opts.limit) |v| try query.append(.{ .key = "limit", .value = try fmtU32(arena, v) });
    if (opts.cursor) |v| try query.append(.{ .key = "cursor", .value = v });
    if (opts.event_ticker) |v| try query.append(.{ .key = "event_ticker", .value = v });
    if (opts.series_ticker) |v| try query.append(.{ .key = "series_ticker", .value = v });
    if (opts.status) |v| try query.append(.{ .key = "status", .value = v });
    if (opts.tickers) |v| try query.append(.{ .key = "tickers", .value = v });
    if (opts.min_close_ts) |v| try query.append(.{ .key = "min_close_ts", .value = try fmtI64(arena, v) });
    if (opts.max_close_ts) |v| try query.append(.{ .key = "max_close_ts", .value = try fmtI64(arena, v) });

    const resp = try client.request(arena, .{ .path = "/markets", .query = query.items });
    if (!resp.isSuccess()) return error.HttpStatus;
    return resp.parseInto(MarketList, arena);
}

/// GET /markets/{ticker}
pub fn get(client: *Client, arena: Allocator, ticker: []const u8) !Market {
    const path = try std.fmt.allocPrint(arena, "/markets/{s}", .{ticker});
    const resp = try client.request(arena, .{ .path = path });
    if (!resp.isSuccess()) return error.HttpStatus;
    const wrapped = try resp.parseInto(MarketWrapped, arena);
    return wrapped.market;
}

/// GET /markets/{ticker}/orderbook — shape varies by market, kept as Value tree.
pub fn orderbook(client: *Client, arena: Allocator, ticker: []const u8) !std.json.Value {
    const path = try std.fmt.allocPrint(arena, "/markets/{s}/orderbook", .{ticker});
    const resp = try client.request(arena, .{ .path = path });
    if (!resp.isSuccess()) return error.HttpStatus;
    return std.json.parseFromSliceLeaky(std.json.Value, arena, resp.body, .{});
}

fn fmtU32(arena: Allocator, v: u32) ![]const u8 {
    return std.fmt.allocPrint(arena, "{d}", .{v});
}

fn fmtI64(arena: Allocator, v: i64) ![]const u8 {
    return std.fmt.allocPrint(arena, "{d}", .{v});
}

const fixture_list = @embedFile("testdata/markets_list.json");
const fixture_get = @embedFile("testdata/markets_get.json");
const fixture_orderbook = @embedFile("testdata/markets_orderbook.json");

test "parses /markets list fixture" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const parsed = try std.json.parseFromSliceLeaky(MarketList, a, fixture_list, .{ .ignore_unknown_fields = true });
    try std.testing.expect(parsed.markets.len > 0);
    try std.testing.expect(parsed.markets[0].ticker.len > 0);
    try std.testing.expect(parsed.markets[0].event_ticker.len > 0);
}

test "parses /markets/{ticker} fixture" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const parsed = try std.json.parseFromSliceLeaky(MarketWrapped, a, fixture_get, .{ .ignore_unknown_fields = true });
    try std.testing.expect(parsed.market.ticker.len > 0);
}

test "parses /markets/{ticker}/orderbook fixture" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const v = try std.json.parseFromSliceLeaky(std.json.Value, a, fixture_orderbook, .{});
    _ = v.object.get("orderbook_fp") orelse return error.MissingOrderbookFp;
}

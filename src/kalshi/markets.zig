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

pub const TradesOptions = struct {
    limit: ?u32 = null,
    cursor: ?[]const u8 = null,
    ticker: ?[]const u8 = null,
    min_ts: ?i64 = null,
    max_ts: ?i64 = null,
};

/// GET /markets/trades — paginated trades across all markets.
pub fn trades(client: *Client, arena: Allocator, opts: TradesOptions) !std.json.Value {
    var q: std.array_list.Managed(QueryParam) = .init(arena);
    if (opts.limit) |v| try q.append(.{ .key = "limit", .value = try fmtU32(arena, v) });
    if (opts.cursor) |v| try q.append(.{ .key = "cursor", .value = v });
    if (opts.ticker) |v| try q.append(.{ .key = "ticker", .value = v });
    if (opts.min_ts) |v| try q.append(.{ .key = "min_ts", .value = try fmtI64(arena, v) });
    if (opts.max_ts) |v| try q.append(.{ .key = "max_ts", .value = try fmtI64(arena, v) });

    const resp = try client.request(arena, .{ .path = "/markets/trades", .query = q.items });
    if (!resp.isSuccess()) return error.HttpStatus;
    return std.json.parseFromSliceLeaky(std.json.Value, arena, resp.body, .{});
}

pub const CandlesticksOptions = struct {
    period_interval: ?u32 = null,
    start_ts: ?i64 = null,
    end_ts: ?i64 = null,
};

/// GET /series/{series_ticker}/markets/{market_ticker}/candlesticks
pub fn candlesticks(
    client: *Client,
    arena: Allocator,
    series_ticker: []const u8,
    market_ticker: []const u8,
    opts: CandlesticksOptions,
) !std.json.Value {
    var q: std.array_list.Managed(QueryParam) = .init(arena);
    if (opts.period_interval) |v| try q.append(.{ .key = "period_interval", .value = try fmtU32(arena, v) });
    if (opts.start_ts) |v| try q.append(.{ .key = "start_ts", .value = try fmtI64(arena, v) });
    if (opts.end_ts) |v| try q.append(.{ .key = "end_ts", .value = try fmtI64(arena, v) });

    const path = try std.fmt.allocPrint(arena, "/series/{s}/markets/{s}/candlesticks", .{ series_ticker, market_ticker });
    const resp = try client.request(arena, .{ .path = path, .query = q.items });
    if (!resp.isSuccess()) return error.HttpStatus;
    return std.json.parseFromSliceLeaky(std.json.Value, arena, resp.body, .{});
}

const OrderbooksBody = struct {
    market_tickers: []const []const u8,
};

/// POST /markets/orderbooks — fetch order books for several tickers at once.
pub fn orderbooks(client: *Client, arena: Allocator, tickers: []const []const u8) !std.json.Value {
    var aw: std.Io.Writer.Allocating = .init(arena);
    const body_struct: OrderbooksBody = .{ .market_tickers = tickers };
    try std.json.Stringify.value(body_struct, .{ .whitespace = .minified }, &aw.writer);
    const resp = try client.request(arena, .{
        .path = "/markets/orderbooks",
        .method = .POST,
        .body = aw.written(),
    });
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

test {
    _ = trades;
    _ = candlesticks;
    _ = orderbooks;
}

const ingest = @import("../kb/ingest.zig");

/// Optional pass-through: callers that have a kb_root opened and a market
/// directory inside it call this after every successful `get`/`list` to keep
/// the reality chain current. If no kb_root is configured, this function is
/// never called.
pub fn kbHookMarket(
    allocator: std.mem.Allocator,
    io: std.Io,
    kb_root: std.Io.Dir,
    ticker: []const u8,
    snap: ingest.MarketSnapshot,
) !void {
    var market_path_buf: [256]u8 = undefined;
    const market_path = try std.fmt.bufPrint(&market_path_buf, "markets/{s}", .{ticker});
    var market_dir = try kb_root.openDir(io, market_path, .{ .iterate = false });
    defer market_dir.close(io);
    _ = try ingest.observeMarket(allocator, io, market_dir, snap);
}

test "kb_root hook: get() appends to market chain when kb_root is set" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.createDirPath(io, "markets/KXTEST/reality");
    try tmp.dir.writeFile(io, .{
        .sub_path = "markets/KXTEST/manifest.json",
        .data = "{\"kind\":\"market\",\"ticker\":\"KXTEST\",\"trigger\":{\"price_delta_cents\":1}}",
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "markets/KXTEST/reality/main.jsonl", .data = "" });
    try tmp.dir.writeFile(io, .{
        .sub_path = "markets/KXTEST/reality/branches.json",
        .data = "{\"active\":\"main\",\"branches\":[{\"name\":\"main\",\"head_hash\":\"0000000000000000000000000000000000000000000000000000000000000000\",\"parent_hash\":\"0000000000000000000000000000000000000000000000000000000000000000\",\"parent_branch\":\"\",\"created_ts_ms\":0}]}",
    });

    try kbHookMarket(std.testing.allocator, io, tmp.dir, "KXTEST", .{
        .ts_ms = 1,
        .yes_bid_cents = 50,
        .yes_ask_cents = 51,
        .volume = 100,
        .last_trade_cents = null,
    });

    var market_dir = try tmp.dir.openDir(io, "markets/KXTEST", .{ .iterate = false });
    defer market_dir.close(io);
    var reality_dir = try market_dir.openDir(io, "reality", .{ .iterate = false });
    defer reality_dir.close(io);
    var chain = try @import("../kb/chain.zig").openRead(std.testing.allocator, io, reality_dir, "main");
    defer chain.deinit();
    try std.testing.expectEqual(@as(usize, 1), chain.len());
}

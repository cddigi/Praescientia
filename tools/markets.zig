//! praescientia-markets — port of scripts/kalshi_markets.jl.
//!
//! Subcommands:
//!   list                                      GET /markets
//!   get TICKER                                GET /markets/{ticker}
//!   trades                                    GET /markets/trades
//!   candlesticks SERIES_TICKER MARKET_TICKER  GET /series/{s}/markets/{m}/candlesticks
//!   orderbook TICKER                          GET /markets/{ticker}/orderbook
//!   orderbooks T1,T2,...                      POST /markets/orderbooks

const std = @import("std");
const common = @import("common");

pub fn main(init: std.process.Init) !u8 {
    return common.runMain(init, "praescientia-markets", &.{
        .{ .name = "list", .description = "List markets", .run = cmdList },
        .{ .name = "get", .description = "Get a market by ticker", .run = cmdGet },
        .{ .name = "trades", .description = "Paginated trades across markets", .run = cmdTrades },
        .{ .name = "candlesticks", .description = "Live market candlesticks", .run = cmdCandlesticks },
        .{ .name = "orderbook", .description = "Order book for a single market", .run = cmdOrderbook },
        .{ .name = "orderbooks", .description = "Order books for multiple markets", .run = cmdOrderbooks },
    });
}

fn parseU32(s: ?[]const u8) ?u32 {
    if (s) |v| return std.fmt.parseInt(u32, v, 10) catch null;
    return null;
}

fn parseI64(s: ?[]const u8) ?i64 {
    if (s) |v| return std.fmt.parseInt(i64, v, 10) catch null;
    return null;
}

fn cmdList(ctx: *common.Context) !u8 {
    const opts: common.kalshi.markets.ListOptions = .{
        .limit = parseU32(ctx.flagValue("--limit")),
        .series_ticker = ctx.flagValue("--series_ticker"),
        .event_ticker = ctx.flagValue("--event_ticker"),
        .status = ctx.flagValue("--status"),
    };
    const v = try common.kalshi.markets.list(ctx.client, ctx.arena, opts);
    try common.printJson(v, ctx.stdout);
    return 0;
}

fn cmdGet(ctx: *common.Context) !u8 {
    const ticker = ctx.positional(0) orelse {
        try ctx.stderr.print("usage: get TICKER\n", .{});
        return 2;
    };
    const v = try common.kalshi.markets.get(ctx.client, ctx.arena, ticker);
    try common.printJson(v, ctx.stdout);
    return 0;
}

fn cmdTrades(ctx: *common.Context) !u8 {
    const opts: common.kalshi.markets.TradesOptions = .{
        .limit = parseU32(ctx.flagValue("--limit")),
        .ticker = ctx.flagValue("--ticker"),
        .min_ts = parseI64(ctx.flagValue("--min_ts")),
        .max_ts = parseI64(ctx.flagValue("--max_ts")),
    };
    const v = try common.kalshi.markets.trades(ctx.client, ctx.arena, opts);
    try common.printJson(v, ctx.stdout);
    return 0;
}

fn cmdCandlesticks(ctx: *common.Context) !u8 {
    const series_ticker = ctx.positional(0) orelse {
        try ctx.stderr.print("usage: candlesticks SERIES_TICKER MARKET_TICKER\n", .{});
        return 2;
    };
    const market_ticker = ctx.positional(1) orelse {
        try ctx.stderr.print("usage: candlesticks SERIES_TICKER MARKET_TICKER\n", .{});
        return 2;
    };
    const opts: common.kalshi.markets.CandlesticksOptions = .{
        .period_interval = parseU32(ctx.flagValue("--period_interval")),
        .start_ts = parseI64(ctx.flagValue("--start_ts")),
        .end_ts = parseI64(ctx.flagValue("--end_ts")),
    };
    const v = try common.kalshi.markets.candlesticks(ctx.client, ctx.arena, series_ticker, market_ticker, opts);
    try common.printJson(v, ctx.stdout);
    return 0;
}

fn cmdOrderbook(ctx: *common.Context) !u8 {
    const ticker = ctx.positional(0) orelse {
        try ctx.stderr.print("usage: orderbook TICKER\n", .{});
        return 2;
    };
    const v = try common.kalshi.markets.orderbook(ctx.client, ctx.arena, ticker);
    try common.printJson(v, ctx.stdout);
    return 0;
}

fn cmdOrderbooks(ctx: *common.Context) !u8 {
    const csv = ctx.positional(0) orelse {
        try ctx.stderr.print("usage: orderbooks TICKER1,TICKER2,...\n", .{});
        return 2;
    };
    var list: std.array_list.Managed([]const u8) = .init(ctx.arena);
    var it = std.mem.splitScalar(u8, csv, ',');
    while (it.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " ");
        if (trimmed.len > 0) try list.append(trimmed);
    }
    const v = try common.kalshi.markets.orderbooks(ctx.client, ctx.arena, list.items);
    try common.printJson(v, ctx.stdout);
    return 0;
}

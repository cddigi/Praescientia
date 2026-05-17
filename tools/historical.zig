//! praescientia-historical — port of scripts/kalshi_historical.jl.
//!
//! Subcommands:
//!   cutoff                  GET /historical/cutoff
//!   candlesticks TICKER     GET /historical/markets/{ticker}/candlesticks
//!   fills                   GET /historical/fills
//!   orders                  GET /historical/orders
//!   trades                  GET /historical/trades
//!   markets                 GET /historical/markets
//!   market TICKER           GET /historical/markets/{ticker}

const std = @import("std");
const common = @import("common");

pub fn main(init: std.process.Init) !u8 {
    return common.runMain(init, "praescientia-historical", &.{
        .{ .name = "cutoff", .description = "Cutoff timestamps between live/historical", .run = cmdCutoff },
        .{ .name = "candlesticks", .description = "Archived candlestick data", .run = cmdCandlesticks },
        .{ .name = "fills", .description = "Historical fills (auth required)", .run = cmdFills },
        .{ .name = "orders", .description = "Archived orders (auth required)", .run = cmdOrders },
        .{ .name = "trades", .description = "Historical trades", .run = cmdTrades },
        .{ .name = "markets", .description = "List archived markets", .run = cmdMarkets },
        .{ .name = "market", .description = "Specific historical market", .run = cmdMarket },
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

fn cmdCutoff(ctx: *common.Context) !u8 {
    const v = try common.kalshi.historical.cutoff(ctx.client, ctx.arena);
    try common.printJson(v, ctx.stdout);
    return 0;
}

fn cmdCandlesticks(ctx: *common.Context) !u8 {
    const ticker = ctx.positional(0) orelse {
        try ctx.stderr.print("usage: candlesticks TICKER\n", .{});
        return 2;
    };
    const opts: common.kalshi.historical.CandlesticksOptions = .{
        .period_interval = parseU32(ctx.flagValue("--period_interval")),
        .start_ts = parseI64(ctx.flagValue("--start_ts")),
        .end_ts = parseI64(ctx.flagValue("--end_ts")),
    };
    const v = try common.kalshi.historical.candlesticks(ctx.client, ctx.arena, ticker, opts);
    try common.printJson(v, ctx.stdout);
    return 0;
}

fn cmdFills(ctx: *common.Context) !u8 {
    const opts: common.kalshi.historical.FillsOptions = .{
        .limit = parseU32(ctx.flagValue("--limit")),
        .ticker = ctx.flagValue("--ticker"),
        .min_ts = parseI64(ctx.flagValue("--min_ts")),
        .max_ts = parseI64(ctx.flagValue("--max_ts")),
    };
    const v = try common.kalshi.historical.fills(ctx.client, ctx.arena, opts);
    try common.printJson(v, ctx.stdout);
    return 0;
}

fn cmdOrders(ctx: *common.Context) !u8 {
    const opts: common.kalshi.historical.OrdersOptions = .{
        .limit = parseU32(ctx.flagValue("--limit")),
        .ticker = ctx.flagValue("--ticker"),
        .status = ctx.flagValue("--status"),
        .min_ts = parseI64(ctx.flagValue("--min_ts")),
        .max_ts = parseI64(ctx.flagValue("--max_ts")),
    };
    const v = try common.kalshi.historical.orders(ctx.client, ctx.arena, opts);
    try common.printJson(v, ctx.stdout);
    return 0;
}

fn cmdTrades(ctx: *common.Context) !u8 {
    const opts: common.kalshi.historical.TradesOptions = .{
        .limit = parseU32(ctx.flagValue("--limit")),
        .ticker = ctx.flagValue("--ticker"),
        .min_ts = parseI64(ctx.flagValue("--min_ts")),
        .max_ts = parseI64(ctx.flagValue("--max_ts")),
    };
    const v = try common.kalshi.historical.trades(ctx.client, ctx.arena, opts);
    try common.printJson(v, ctx.stdout);
    return 0;
}

fn cmdMarkets(ctx: *common.Context) !u8 {
    const opts: common.kalshi.historical.MarketsOptions = .{
        .limit = parseU32(ctx.flagValue("--limit")),
        .series_ticker = ctx.flagValue("--series_ticker"),
        .status = ctx.flagValue("--status"),
    };
    const v = try common.kalshi.historical.markets(ctx.client, ctx.arena, opts);
    try common.printJson(v, ctx.stdout);
    return 0;
}

fn cmdMarket(ctx: *common.Context) !u8 {
    const ticker = ctx.positional(0) orelse {
        try ctx.stderr.print("usage: market TICKER\n", .{});
        return 2;
    };
    const v = try common.kalshi.historical.market(ctx.client, ctx.arena, ticker);
    try common.printJson(v, ctx.stdout);
    return 0;
}

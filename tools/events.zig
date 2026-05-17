//! praescientia-events — port of scripts/kalshi_events.jl.
//!
//! Subcommands:
//!   list                                       GET /events
//!   multivariate                               GET /multivariate_events
//!   get EVENT_TICKER                           GET /events/{event_ticker}
//!   metadata EVENT_TICKER                      GET /events/{event_ticker}/metadata
//!   candlesticks SERIES_TICKER EVENT_TICKER    GET /series/.../events/.../candlesticks
//!   forecast SERIES_TICKER EVENT_TICKER        GET /series/.../events/.../forecast
//!   collection COLLECTION_TICKER               GET /multivariate_event_collections/{ticker}

const std = @import("std");
const common = @import("common");

pub fn main(init: std.process.Init) !u8 {
    return common.runMain(init, "praescientia-events", &.{
        .{ .name = "list", .description = "List standard events", .run = cmdList },
        .{ .name = "multivariate", .description = "List multivariate combo events", .run = cmdMultivariate },
        .{ .name = "get", .description = "Get a specific event", .run = cmdGet },
        .{ .name = "metadata", .description = "Get event metadata", .run = cmdMetadata },
        .{ .name = "candlesticks", .description = "Event candlesticks", .run = cmdCandlesticks },
        .{ .name = "forecast", .description = "Forecast percentile history", .run = cmdForecast },
        .{ .name = "collection", .description = "Multivariate event collection", .run = cmdCollection },
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

fn hasFlag(ctx: *const common.Context, name: []const u8) bool {
    for (ctx.args[1..]) |a| if (std.mem.eql(u8, a, name)) return true;
    return false;
}

fn cmdList(ctx: *common.Context) !u8 {
    const opts: common.kalshi.events.ListOptions = .{
        .limit = parseU32(ctx.flagValue("--limit")),
        .status = ctx.flagValue("--status"),
        .series_ticker = ctx.flagValue("--series_ticker"),
        .with_nested_markets = if (hasFlag(ctx, "--with_nested_markets")) true else null,
    };
    const v = try common.kalshi.events.list(ctx.client, ctx.arena, opts);
    try common.printJson(v, ctx.stdout);
    return 0;
}

fn cmdMultivariate(ctx: *common.Context) !u8 {
    const opts: common.kalshi.events.MultivariateOptions = .{
        .limit = parseU32(ctx.flagValue("--limit")),
    };
    const v = try common.kalshi.events.listMultivariate(ctx.client, ctx.arena, opts);
    try common.printJson(v, ctx.stdout);
    return 0;
}

fn cmdGet(ctx: *common.Context) !u8 {
    const ticker = ctx.positional(0) orelse {
        try ctx.stderr.print("usage: get EVENT_TICKER\n", .{});
        return 2;
    };
    const v = try common.kalshi.events.get(ctx.client, ctx.arena, ticker);
    try common.printJson(v, ctx.stdout);
    return 0;
}

fn cmdMetadata(ctx: *common.Context) !u8 {
    const ticker = ctx.positional(0) orelse {
        try ctx.stderr.print("usage: metadata EVENT_TICKER\n", .{});
        return 2;
    };
    const v = try common.kalshi.events.metadata(ctx.client, ctx.arena, ticker);
    try common.printJson(v, ctx.stdout);
    return 0;
}

fn cmdCandlesticks(ctx: *common.Context) !u8 {
    const series_ticker = ctx.positional(0) orelse {
        try ctx.stderr.print("usage: candlesticks SERIES_TICKER EVENT_TICKER\n", .{});
        return 2;
    };
    const event_ticker = ctx.positional(1) orelse {
        try ctx.stderr.print("usage: candlesticks SERIES_TICKER EVENT_TICKER\n", .{});
        return 2;
    };
    const opts: common.kalshi.events.CandlesticksOptions = .{
        .period_interval = parseU32(ctx.flagValue("--period_interval")),
        .start_ts = parseI64(ctx.flagValue("--start_ts")),
        .end_ts = parseI64(ctx.flagValue("--end_ts")),
    };
    const v = try common.kalshi.events.candlesticks(ctx.client, ctx.arena, series_ticker, event_ticker, opts);
    try common.printJson(v, ctx.stdout);
    return 0;
}

fn cmdForecast(ctx: *common.Context) !u8 {
    const series_ticker = ctx.positional(0) orelse {
        try ctx.stderr.print("usage: forecast SERIES_TICKER EVENT_TICKER\n", .{});
        return 2;
    };
    const event_ticker = ctx.positional(1) orelse {
        try ctx.stderr.print("usage: forecast SERIES_TICKER EVENT_TICKER\n", .{});
        return 2;
    };
    const v = try common.kalshi.events.forecast(ctx.client, ctx.arena, series_ticker, event_ticker);
    try common.printJson(v, ctx.stdout);
    return 0;
}

fn cmdCollection(ctx: *common.Context) !u8 {
    const ticker = ctx.positional(0) orelse {
        try ctx.stderr.print("usage: collection COLLECTION_TICKER\n", .{});
        return 2;
    };
    const v = try common.kalshi.events.collection(ctx.client, ctx.arena, ticker);
    try common.printJson(v, ctx.stdout);
    return 0;
}

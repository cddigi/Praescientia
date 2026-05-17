//! praescientia-search — port of scripts/kalshi_search.jl.
//!
//! Subcommands:
//!   tags                 GET /search/tags_by_categories
//!   sport_filters        GET /search/filters_by_sport
//!   targets              GET /structured_targets
//!   target TARGET_ID     GET /structured_targets/{target_id}
//!   series SERIES_TICKER GET /series/{series_ticker}

const std = @import("std");
const common = @import("common");

const search = common.kalshi.search;

pub fn main(init: std.process.Init) !u8 {
    return common.runMain(init, "praescientia-search", &.{
        .{ .name = "tags", .description = "Tags by series categories", .run = cmdTags },
        .{ .name = "sport_filters", .description = "Filters by sport", .run = cmdSportFilters },
        .{ .name = "targets", .description = "List structured targets", .run = cmdTargets },
        .{ .name = "target", .description = "Get specific structured target (TARGET_ID)", .run = cmdTarget },
        .{ .name = "series", .description = "Get series information (SERIES_TICKER)", .run = cmdSeries },
    });
}

fn requirePositional(ctx: *common.Context, name: []const u8) !?[]const u8 {
    if (ctx.positional(0)) |v| return v;
    try ctx.stderr.print("{s} required\n", .{name});
    return null;
}

fn cmdTags(ctx: *common.Context) !u8 {
    const v = try search.tagsByCategories(ctx.client, ctx.arena);
    try common.printJson(v, ctx.stdout);
    return 0;
}

fn cmdSportFilters(ctx: *common.Context) !u8 {
    const v = try search.filtersBySport(ctx.client, ctx.arena);
    try common.printJson(v, ctx.stdout);
    return 0;
}

fn cmdTargets(ctx: *common.Context) !u8 {
    const v = try search.structuredTargets(ctx.client, ctx.arena);
    try common.printJson(v, ctx.stdout);
    return 0;
}

fn cmdTarget(ctx: *common.Context) !u8 {
    const id = (try requirePositional(ctx, "TARGET_ID")) orelse return 2;
    const v = try search.searchTarget(ctx.client, ctx.arena, id);
    try common.printJson(v, ctx.stdout);
    return 0;
}

fn cmdSeries(ctx: *common.Context) !u8 {
    const ticker = (try requirePositional(ctx, "SERIES_TICKER")) orelse return 2;
    const v = try search.series(ctx.client, ctx.arena, ticker);
    try common.printJson(v, ctx.stdout);
    return 0;
}

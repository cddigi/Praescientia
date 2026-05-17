//! praescientia-live-data — port of scripts/kalshi_live_data.jl.
//!
//! Subcommands:
//!   milestones                       GET /milestones (--category --competition --limit)
//!   milestone MILESTONE_ID           GET /milestones/{id}
//!   live MILESTONE_ID                GET /live_data/milestone/{id}
//!   live_legacy TYPE MILESTONE_ID    GET /live_data/{type}/milestone/{id}
//!   batch ID1,ID2,...                GET /live_data/batch?milestone_ids=...
//!   game_stats MILESTONE_ID          GET /live_data/milestone/{id}/game_stats

const std = @import("std");
const common = @import("common");

const ld = common.kalshi.live_data;

pub fn main(init: std.process.Init) !u8 {
    return common.runMain(init, "praescientia-live-data", &.{
        .{ .name = "milestones", .description = "List milestones (--category --competition --limit)", .run = cmdMilestones },
        .{ .name = "milestone", .description = "Get specific milestone (MILESTONE_ID)", .run = cmdMilestone },
        .{ .name = "live", .description = "Live data for milestone (MILESTONE_ID)", .run = cmdLive },
        .{ .name = "live_legacy", .description = "Legacy live data (TYPE MILESTONE_ID)", .run = cmdLiveLegacy },
        .{ .name = "batch", .description = "Batch live data (ID1,ID2,...)", .run = cmdBatch },
        .{ .name = "game_stats", .description = "Play-by-play game stats (MILESTONE_ID)", .run = cmdGameStats },
    });
}

fn parseU32(s: []const u8) !u32 {
    return std.fmt.parseInt(u32, s, 10);
}

fn requirePositional(ctx: *common.Context, i: usize, name: []const u8) !?[]const u8 {
    if (ctx.positional(i)) |v| return v;
    try ctx.stderr.print("{s} required\n", .{name});
    return null;
}

fn cmdMilestones(ctx: *common.Context) !u8 {
    var opts: ld.ListOptions = .{};
    if (ctx.flagValue("--limit")) |s| opts.limit = try parseU32(s);
    if (ctx.flagValue("--category")) |s| opts.category = s;
    if (ctx.flagValue("--competition")) |s| opts.competition = s;
    const v = try ld.listMilestones(ctx.client, ctx.arena, opts);
    try common.printJson(v, ctx.stdout);
    return 0;
}

fn cmdMilestone(ctx: *common.Context) !u8 {
    const id = (try requirePositional(ctx, 0, "MILESTONE_ID")) orelse return 2;
    const v = try ld.getMilestone(ctx.client, ctx.arena, id);
    try common.printJson(v, ctx.stdout);
    return 0;
}

fn cmdLive(ctx: *common.Context) !u8 {
    const id = (try requirePositional(ctx, 0, "MILESTONE_ID")) orelse return 2;
    const v = try ld.liveData(ctx.client, ctx.arena, id);
    try common.printJson(v, ctx.stdout);
    return 0;
}

fn cmdLiveLegacy(ctx: *common.Context) !u8 {
    const type_str = (try requirePositional(ctx, 0, "TYPE")) orelse return 2;
    const id = (try requirePositional(ctx, 1, "MILESTONE_ID")) orelse return 2;
    const v = try ld.liveDataLegacy(ctx.client, ctx.arena, type_str, id);
    try common.printJson(v, ctx.stdout);
    return 0;
}

fn cmdBatch(ctx: *common.Context) !u8 {
    const csv = (try requirePositional(ctx, 0, "ID1,ID2,...")) orelse return 2;
    const v = try ld.batch(ctx.client, ctx.arena, csv);
    try common.printJson(v, ctx.stdout);
    return 0;
}

fn cmdGameStats(ctx: *common.Context) !u8 {
    const id = (try requirePositional(ctx, 0, "MILESTONE_ID")) orelse return 2;
    const v = try ld.gameStats(ctx.client, ctx.arena, id);
    try common.printJson(v, ctx.stdout);
    return 0;
}

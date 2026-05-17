//! praescientia-exchange — port of scripts/kalshi_exchange.jl.
//!
//! Subcommands:
//!   status         GET /exchange/status
//!   schedule       GET /exchange/schedule
//!   announcements  GET /exchange/announcements

const std = @import("std");
const common = @import("common");

pub fn main(init: std.process.Init) !u8 {
    return common.runMain(init, "praescientia-exchange", &.{
        .{ .name = "status", .description = "Exchange operational status", .run = cmdStatus },
        .{ .name = "schedule", .description = "Exchange operating schedule", .run = cmdSchedule },
        .{ .name = "announcements", .description = "Exchange-wide announcements", .run = cmdAnnouncements },
    });
}

fn cmdStatus(ctx: *common.Context) !u8 {
    const s = try common.kalshi.exchange.status(ctx.client, ctx.arena);
    try common.printJson(s, ctx.stdout);
    return 0;
}

fn cmdSchedule(ctx: *common.Context) !u8 {
    const v = try common.kalshi.exchange.schedule(ctx.client, ctx.arena);
    try common.printJson(v, ctx.stdout);
    return 0;
}

fn cmdAnnouncements(ctx: *common.Context) !u8 {
    const v = try common.kalshi.exchange.announcements(ctx.client, ctx.arena);
    try common.printJson(v, ctx.stdout);
    return 0;
}

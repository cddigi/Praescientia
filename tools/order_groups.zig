//! praescientia-order-groups — port of scripts/kalshi_order_groups.jl.
//!
//! Subcommands:
//!   list                       GET    /portfolio/order_groups
//!   create --max_contracts=N   POST   /portfolio/order_groups/create
//!   get GROUP_ID               GET    /portfolio/order_groups/{id}
//!   delete GROUP_ID            DELETE /portfolio/order_groups/{id}
//!   reset GROUP_ID             PUT    /portfolio/order_groups/{id}/reset
//!   trigger GROUP_ID           PUT    /portfolio/order_groups/{id}/trigger
//!   set_limit GROUP_ID         PUT    /portfolio/order_groups/{id}/limit (--max_contracts)

const std = @import("std");
const common = @import("common");

const og = common.kalshi.order_groups;

pub fn main(init: std.process.Init) !u8 {
    return common.runMain(init, "praescientia-order-groups", &.{
        .{ .name = "list", .description = "List all order groups", .run = cmdList },
        .{ .name = "create", .description = "Create order group (--max_contracts=N)", .run = cmdCreate },
        .{ .name = "get", .description = "Get order group (GROUP_ID)", .run = cmdGet },
        .{ .name = "delete", .description = "Delete group & cancel orders (GROUP_ID)", .run = cmdDelete },
        .{ .name = "reset", .description = "Reset matched contracts counter (GROUP_ID)", .run = cmdReset },
        .{ .name = "trigger", .description = "Trigger group & cancel orders (GROUP_ID)", .run = cmdTrigger },
        .{ .name = "set_limit", .description = "Update contract limit (--max_contracts=N)", .run = cmdSetLimit },
    });
}

fn parseU32(s: []const u8) !u32 {
    return std.fmt.parseInt(u32, s, 10);
}

fn requirePositional(ctx: *common.Context, name: []const u8) !?[]const u8 {
    if (ctx.positional(0)) |v| return v;
    try ctx.stderr.print("{s} required\n", .{name});
    return null;
}

fn requireFlag(ctx: *common.Context, flag: []const u8) !?[]const u8 {
    if (ctx.flagValue(flag)) |v| return v;
    try ctx.stderr.print("{s} required\n", .{flag});
    return null;
}

fn cmdList(ctx: *common.Context) !u8 {
    const v = try og.list(ctx.client, ctx.arena);
    try common.printJson(v, ctx.stdout);
    return 0;
}

fn cmdCreate(ctx: *common.Context) !u8 {
    const s = (try requireFlag(ctx, "--max_contracts")) orelse return 2;
    const v = try og.create(ctx.client, ctx.arena, try parseU32(s));
    try common.printJson(v, ctx.stdout);
    return 0;
}

fn cmdGet(ctx: *common.Context) !u8 {
    const id = (try requirePositional(ctx, "GROUP_ID")) orelse return 2;
    const v = try og.get(ctx.client, ctx.arena, id);
    try common.printJson(v, ctx.stdout);
    return 0;
}

fn cmdDelete(ctx: *common.Context) !u8 {
    const id = (try requirePositional(ctx, "GROUP_ID")) orelse return 2;
    const v = try og.delete_(ctx.client, ctx.arena, id);
    try common.printJson(v, ctx.stdout);
    return 0;
}

fn cmdReset(ctx: *common.Context) !u8 {
    const id = (try requirePositional(ctx, "GROUP_ID")) orelse return 2;
    const v = try og.reset(ctx.client, ctx.arena, id);
    try common.printJson(v, ctx.stdout);
    return 0;
}

fn cmdTrigger(ctx: *common.Context) !u8 {
    const id = (try requirePositional(ctx, "GROUP_ID")) orelse return 2;
    const v = try og.trigger(ctx.client, ctx.arena, id);
    try common.printJson(v, ctx.stdout);
    return 0;
}

fn cmdSetLimit(ctx: *common.Context) !u8 {
    const id = (try requirePositional(ctx, "GROUP_ID")) orelse return 2;
    const s = (try requireFlag(ctx, "--max_contracts")) orelse return 2;
    const v = try og.setLimit(ctx.client, ctx.arena, id, try parseU32(s));
    try common.printJson(v, ctx.stdout);
    return 0;
}

//! praescientia-account — port of scripts/kalshi_account.jl.
//!
//! Subcommands:
//!   list_keys       GET    /api_keys
//!   create_key      POST   /api_keys           (--public_key_file=PATH)
//!   generate_key    POST   /api_keys/generate
//!   delete_key KEY_ID DELETE /api_keys/{id}
//!   limits          GET    /account/limits
//!   incentives      GET    /incentive_programs [--status, --type]
//!   fcm_orders      GET    /fcm/orders         [--subtrader_id, --limit]
//!   fcm_positions   GET    /fcm/positions      [--subtrader_id]

const std = @import("std");
const common = @import("common");

pub fn main(init: std.process.Init) !u8 {
    return common.runMain(init, "praescientia-account", &.{
        .{ .name = "list_keys", .description = "List all API keys", .run = cmdListKeys },
        .{ .name = "create_key", .description = "Create an API key (provide public key file)", .run = cmdCreateKey },
        .{ .name = "generate_key", .description = "Generate an API key pair (save the private key!)", .run = cmdGenerateKey },
        .{ .name = "delete_key", .description = "Permanently delete an API key", .run = cmdDeleteKey },
        .{ .name = "limits", .description = "Show API tier rate limits", .run = cmdLimits },
        .{ .name = "incentives", .description = "List incentive programs", .run = cmdIncentives },
        .{ .name = "fcm_orders", .description = "FCM orders (Premier/Market Maker only)", .run = cmdFcmOrders },
        .{ .name = "fcm_positions", .description = "FCM positions (Premier/Market Maker only)", .run = cmdFcmPositions },
    });
}

fn parseU32(s: []const u8) ?u32 {
    return std.fmt.parseInt(u32, s, 10) catch null;
}

fn cmdListKeys(ctx: *common.Context) !u8 {
    const v = try common.kalshi.account.listApiKeys(ctx.client, ctx.arena);
    try common.printJson(v, ctx.stdout);
    return 0;
}

fn cmdCreateKey(ctx: *common.Context) !u8 {
    const path = ctx.flagValue("--public_key_file") orelse {
        try ctx.stderr.print("error: --public_key_file=PATH is required\n", .{});
        return 2;
    };
    const pem = common.readFileTrimmed(ctx.io, ctx.arena, path) catch |err| {
        try ctx.stderr.print("error: failed to read {s}: {s}\n", .{ path, @errorName(err) });
        return 2;
    };
    const v = try common.kalshi.account.createApiKey(ctx.client, ctx.arena, pem);
    try common.printJson(v, ctx.stdout);
    return 0;
}

fn cmdGenerateKey(ctx: *common.Context) !u8 {
    const v = try common.kalshi.account.generateApiKey(ctx.client, ctx.arena);
    try common.printJson(v, ctx.stdout);
    return 0;
}

fn cmdDeleteKey(ctx: *common.Context) !u8 {
    const key_id = ctx.positional(0) orelse {
        try ctx.stderr.print("error: KEY_ID positional argument required\n", .{});
        return 2;
    };
    const v = try common.kalshi.account.deleteApiKey(ctx.client, ctx.arena, key_id);
    try common.printJson(v, ctx.stdout);
    return 0;
}

fn cmdLimits(ctx: *common.Context) !u8 {
    const v = try common.kalshi.account.limits(ctx.client, ctx.arena);
    try common.printJson(v, ctx.stdout);
    return 0;
}

fn cmdIncentives(ctx: *common.Context) !u8 {
    var opts: common.kalshi.account.IncentiveOptions = .{};
    if (ctx.flagValue("--status")) |v| opts.status = v;
    if (ctx.flagValue("--type")) |v| opts.@"type" = v;
    const v = try common.kalshi.account.listIncentivePrograms(ctx.client, ctx.arena, opts);
    try common.printJson(v, ctx.stdout);
    return 0;
}

fn cmdFcmOrders(ctx: *common.Context) !u8 {
    var opts: common.kalshi.account.FcmOrdersOptions = .{};
    if (ctx.flagValue("--subtrader_id")) |v| opts.subtrader_id = v;
    if (ctx.flagValue("--limit")) |v| opts.limit = parseU32(v);
    const v = try common.kalshi.account.listFcmOrders(ctx.client, ctx.arena, opts);
    try common.printJson(v, ctx.stdout);
    return 0;
}

fn cmdFcmPositions(ctx: *common.Context) !u8 {
    var opts: common.kalshi.account.FcmPositionsOptions = .{};
    if (ctx.flagValue("--subtrader_id")) |v| opts.subtrader_id = v;
    const v = try common.kalshi.account.listFcmPositions(ctx.client, ctx.arena, opts);
    try common.printJson(v, ctx.stdout);
    return 0;
}

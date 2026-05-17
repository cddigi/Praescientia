//! praescientia-portfolio — port of scripts/kalshi_portfolio.jl.
//!
//! Subcommands:
//!   balance               GET  /portfolio/balance
//!   positions             GET  /portfolio/positions    [--ticker, --event_ticker, --limit]
//!   settlements           GET  /portfolio/settlements  [--limit]
//!   fills                 GET  /portfolio/fills        [--ticker, --min_ts, --max_ts, --limit]
//!   resting_value         GET  /portfolio/orders/resting_value
//!   subaccounts_balances  GET  /portfolio/subaccounts/balances
//!   subaccount_transfers  GET  /portfolio/subaccounts/transfers [--limit]
//!   netting               GET  /portfolio/subaccounts/{id}/netting   (--subaccount_id)
//!   create_subaccount     POST /portfolio/subaccounts               (--name)
//!   transfer              POST /portfolio/subaccounts/transfers     (--from --to --amount)
//!   set_netting           PUT  /portfolio/subaccounts/{id}/netting  (--subaccount_id --netting_enabled)

const std = @import("std");
const common = @import("common");

pub fn main(init: std.process.Init) !u8 {
    return common.runMain(init, "praescientia-portfolio", &.{
        .{ .name = "balance", .description = "Account balance & portfolio value", .run = cmdBalance },
        .{ .name = "positions", .description = "Market positions", .run = cmdPositions },
        .{ .name = "settlements", .description = "Settlement history", .run = cmdSettlements },
        .{ .name = "fills", .description = "All fills", .run = cmdFills },
        .{ .name = "resting_value", .description = "Total resting order value", .run = cmdRestingValue },
        .{ .name = "subaccounts_balances", .description = "All subaccount balances", .run = cmdSubaccountsBalances },
        .{ .name = "subaccount_transfers", .description = "List subaccount transfers", .run = cmdSubaccountTransfers },
        .{ .name = "netting", .description = "Get netting settings for a subaccount", .run = cmdGetNetting },
        .{ .name = "create_subaccount", .description = "Create a subaccount", .run = cmdCreateSubaccount },
        .{ .name = "transfer", .description = "Transfer funds between subaccounts", .run = cmdTransfer },
        .{ .name = "set_netting", .description = "Update netting setting for a subaccount", .run = cmdSetNetting },
    });
}

fn parseU32(s: []const u8) ?u32 {
    return std.fmt.parseInt(u32, s, 10) catch null;
}

fn parseI64(s: []const u8) ?i64 {
    return std.fmt.parseInt(i64, s, 10) catch null;
}

fn cmdBalance(ctx: *common.Context) !u8 {
    const v = try common.kalshi.portfolio.balance(ctx.client, ctx.arena);
    try common.printJson(v, ctx.stdout);
    return 0;
}

fn cmdPositions(ctx: *common.Context) !u8 {
    var opts: common.kalshi.portfolio.ListOptions = .{};
    if (ctx.flagValue("--ticker")) |v| opts.ticker = v;
    if (ctx.flagValue("--event_ticker")) |v| opts.event_ticker = v;
    if (ctx.flagValue("--limit")) |v| opts.limit = parseU32(v);
    const result = try common.kalshi.portfolio.positions(ctx.client, ctx.arena, opts);
    try common.printJson(result, ctx.stdout);
    return 0;
}

fn cmdSettlements(ctx: *common.Context) !u8 {
    var opts: common.kalshi.portfolio.ListOptions = .{};
    if (ctx.flagValue("--limit")) |v| opts.limit = parseU32(v);
    const result = try common.kalshi.portfolio.settlements(ctx.client, ctx.arena, opts);
    try common.printJson(result, ctx.stdout);
    return 0;
}

fn cmdFills(ctx: *common.Context) !u8 {
    var opts: common.kalshi.portfolio.ListOptions = .{};
    if (ctx.flagValue("--ticker")) |v| opts.ticker = v;
    if (ctx.flagValue("--min_ts")) |v| opts.min_ts = parseI64(v);
    if (ctx.flagValue("--max_ts")) |v| opts.max_ts = parseI64(v);
    if (ctx.flagValue("--limit")) |v| opts.limit = parseU32(v);
    const result = try common.kalshi.portfolio.fills(ctx.client, ctx.arena, opts);
    try common.printJson(result, ctx.stdout);
    return 0;
}

fn cmdRestingValue(ctx: *common.Context) !u8 {
    const v = try common.kalshi.portfolio.restingValue(ctx.client, ctx.arena);
    try common.printJson(v, ctx.stdout);
    return 0;
}

fn cmdSubaccountsBalances(ctx: *common.Context) !u8 {
    const v = try common.kalshi.portfolio.subaccountsBalances(ctx.client, ctx.arena);
    try common.printJson(v, ctx.stdout);
    return 0;
}

fn cmdSubaccountTransfers(ctx: *common.Context) !u8 {
    var opts: common.kalshi.portfolio.SubaccountTransfersOptions = .{};
    if (ctx.flagValue("--limit")) |v| opts.limit = parseU32(v);
    const v = try common.kalshi.portfolio.listSubaccountTransfers(ctx.client, ctx.arena, opts);
    try common.printJson(v, ctx.stdout);
    return 0;
}

fn cmdGetNetting(ctx: *common.Context) !u8 {
    const sub_id = ctx.flagValue("--subaccount_id") orelse {
        try ctx.stderr.print("error: --subaccount_id is required\n", .{});
        return 2;
    };
    const v = try common.kalshi.portfolio.getNetting(ctx.client, ctx.arena, sub_id);
    try common.printJson(v, ctx.stdout);
    return 0;
}

fn cmdCreateSubaccount(ctx: *common.Context) !u8 {
    const name = ctx.flagValue("--name") orelse {
        try ctx.stderr.print("error: --name is required\n", .{});
        return 2;
    };
    const v = try common.kalshi.portfolio.createSubaccount(ctx.client, ctx.arena, name);
    try common.printJson(v, ctx.stdout);
    return 0;
}

fn cmdTransfer(ctx: *common.Context) !u8 {
    const from_id = ctx.flagValue("--from") orelse {
        try ctx.stderr.print("error: --from is required\n", .{});
        return 2;
    };
    const to_id = ctx.flagValue("--to") orelse {
        try ctx.stderr.print("error: --to is required\n", .{});
        return 2;
    };
    const amount_str = ctx.flagValue("--amount") orelse {
        try ctx.stderr.print("error: --amount is required (in cents)\n", .{});
        return 2;
    };
    const amount = parseI64(amount_str) orelse {
        try ctx.stderr.print("error: --amount must be an integer\n", .{});
        return 2;
    };
    const v = try common.kalshi.portfolio.transferBetweenSubaccounts(ctx.client, ctx.arena, from_id, to_id, amount);
    try common.printJson(v, ctx.stdout);
    return 0;
}

fn cmdSetNetting(ctx: *common.Context) !u8 {
    const sub_id = ctx.flagValue("--subaccount_id") orelse {
        try ctx.stderr.print("error: --subaccount_id is required\n", .{});
        return 2;
    };
    const enabled_str = ctx.flagValue("--netting_enabled") orelse {
        try ctx.stderr.print("error: --netting_enabled is required (true|false)\n", .{});
        return 2;
    };
    const enabled = std.ascii.eqlIgnoreCase(enabled_str, "true");
    const v = try common.kalshi.portfolio.setNetting(ctx.client, ctx.arena, sub_id, enabled);
    try common.printJson(v, ctx.stdout);
    return 0;
}

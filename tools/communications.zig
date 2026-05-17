//! praescientia-communications — port of scripts/kalshi_communications.jl.
//!
//! Subcommands:
//!   comms_id              GET  /communications/id
//!   list_rfqs             GET  /communications/rfqs
//!   create_rfq            POST /communications/rfqs
//!   get_rfq RFQ_ID        GET  /communications/rfqs/{id}
//!   delete_rfq RFQ_ID     DELETE /communications/rfqs/{id}
//!   list_quotes           GET  /communications/quotes
//!   create_quote          POST /communications/quotes
//!   get_quote QUOTE_ID    GET  /communications/quotes/{id}
//!   delete_quote QUOTE_ID DELETE /communications/quotes/{id}
//!   accept_quote QUOTE_ID PUT  /communications/quotes/{id}/accept
//!   confirm_quote QUOTE_ID PUT /communications/quotes/{id}/confirm

const std = @import("std");
const common = @import("common");

const comms = common.kalshi.communications;

pub fn main(init: std.process.Init) !u8 {
    return common.runMain(init, "praescientia-communications", &.{
        .{ .name = "comms_id", .description = "Get your communications ID", .run = cmdCommsId },
        .{ .name = "list_rfqs", .description = "List RFQs (--status --limit)", .run = cmdListRfqs },
        .{ .name = "create_rfq", .description = "Create RFQ (--ticker --side --count)", .run = cmdCreateRfq },
        .{ .name = "get_rfq", .description = "Get specific RFQ (RFQ_ID)", .run = cmdGetRfq },
        .{ .name = "delete_rfq", .description = "Delete RFQ (RFQ_ID)", .run = cmdDeleteRfq },
        .{ .name = "list_quotes", .description = "List quotes (--status --limit)", .run = cmdListQuotes },
        .{ .name = "create_quote", .description = "Create quote (--rfq_id --price --count)", .run = cmdCreateQuote },
        .{ .name = "get_quote", .description = "Get specific quote (QUOTE_ID)", .run = cmdGetQuote },
        .{ .name = "delete_quote", .description = "Delete quote (QUOTE_ID)", .run = cmdDeleteQuote },
        .{ .name = "accept_quote", .description = "Accept quote (QUOTE_ID)", .run = cmdAcceptQuote },
        .{ .name = "confirm_quote", .description = "Confirm quote (QUOTE_ID)", .run = cmdConfirmQuote },
    });
}

fn parseU32(s: []const u8) !u32 {
    return std.fmt.parseInt(u32, s, 10);
}

fn requireFlag(ctx: *common.Context, flag: []const u8) !?[]const u8 {
    if (ctx.flagValue(flag)) |v| return v;
    try ctx.stderr.print("{s} required\n", .{flag});
    return null;
}

fn requirePositional(ctx: *common.Context, name: []const u8) !?[]const u8 {
    if (ctx.positional(0)) |v| return v;
    try ctx.stderr.print("{s} required\n", .{name});
    return null;
}

fn cmdCommsId(ctx: *common.Context) !u8 {
    const v = try comms.commsId(ctx.client, ctx.arena);
    try common.printJson(v, ctx.stdout);
    return 0;
}

fn cmdListRfqs(ctx: *common.Context) !u8 {
    var opts: comms.ListOptions = .{};
    if (ctx.flagValue("--status")) |s| opts.status = s;
    if (ctx.flagValue("--limit")) |s| opts.limit = try parseU32(s);
    const v = try comms.listRfqs(ctx.client, ctx.arena, opts);
    try common.printJson(v, ctx.stdout);
    return 0;
}

fn cmdCreateRfq(ctx: *common.Context) !u8 {
    const ticker = (try requireFlag(ctx, "--ticker")) orelse return 2;
    const side = (try requireFlag(ctx, "--side")) orelse return 2;
    const count_s = (try requireFlag(ctx, "--count")) orelse return 2;
    const body: comms.CreateRfq = .{
        .ticker = ticker,
        .side = side,
        .count = try parseU32(count_s),
    };
    const v = try comms.createRfq(ctx.client, ctx.arena, body);
    try common.printJson(v, ctx.stdout);
    return 0;
}

fn cmdGetRfq(ctx: *common.Context) !u8 {
    const id = (try requirePositional(ctx, "RFQ_ID")) orelse return 2;
    const v = try comms.getRfq(ctx.client, ctx.arena, id);
    try common.printJson(v, ctx.stdout);
    return 0;
}

fn cmdDeleteRfq(ctx: *common.Context) !u8 {
    const id = (try requirePositional(ctx, "RFQ_ID")) orelse return 2;
    const v = try comms.cancelRfq(ctx.client, ctx.arena, id);
    try common.printJson(v, ctx.stdout);
    return 0;
}

fn cmdListQuotes(ctx: *common.Context) !u8 {
    var opts: comms.ListOptions = .{};
    if (ctx.flagValue("--status")) |s| opts.status = s;
    if (ctx.flagValue("--limit")) |s| opts.limit = try parseU32(s);
    const v = try comms.listQuotes(ctx.client, ctx.arena, opts);
    try common.printJson(v, ctx.stdout);
    return 0;
}

fn cmdCreateQuote(ctx: *common.Context) !u8 {
    const rfq_id = (try requireFlag(ctx, "--rfq_id")) orelse return 2;
    const price_s = (try requireFlag(ctx, "--price")) orelse return 2;
    const count_s = (try requireFlag(ctx, "--count")) orelse return 2;
    const body: comms.CreateQuote = .{
        .rfq_id = rfq_id,
        .price = try parseU32(price_s),
        .count = try parseU32(count_s),
    };
    const v = try comms.createQuote(ctx.client, ctx.arena, body);
    try common.printJson(v, ctx.stdout);
    return 0;
}

fn cmdGetQuote(ctx: *common.Context) !u8 {
    const id = (try requirePositional(ctx, "QUOTE_ID")) orelse return 2;
    const v = try comms.getQuote(ctx.client, ctx.arena, id);
    try common.printJson(v, ctx.stdout);
    return 0;
}

fn cmdDeleteQuote(ctx: *common.Context) !u8 {
    const id = (try requirePositional(ctx, "QUOTE_ID")) orelse return 2;
    const v = try comms.deleteQuote(ctx.client, ctx.arena, id);
    try common.printJson(v, ctx.stdout);
    return 0;
}

fn cmdAcceptQuote(ctx: *common.Context) !u8 {
    const id = (try requirePositional(ctx, "QUOTE_ID")) orelse return 2;
    const v = try comms.acceptQuote(ctx.client, ctx.arena, id);
    try common.printJson(v, ctx.stdout);
    return 0;
}

fn cmdConfirmQuote(ctx: *common.Context) !u8 {
    const id = (try requirePositional(ctx, "QUOTE_ID")) orelse return 2;
    const v = try comms.confirmQuote(ctx.client, ctx.arena, id);
    try common.printJson(v, ctx.stdout);
    return 0;
}

//! praescientia-orders — port of scripts/kalshi_orders.jl.
//!
//! Subcommands:
//!   list             GET    /portfolio/orders
//!   create           POST   /portfolio/orders  (auto-generates client_order_id)
//!   get ORDER_ID     GET    /portfolio/orders/{id}
//!   cancel ORDER_ID  DELETE /portfolio/orders/{id}
//!   amend ORDER_ID   POST   /portfolio/orders/{id}/amend
//!   decrease ORDER_ID POST  /portfolio/orders/{id}/decrease  (--reduce_by)
//!   queue_positions  GET    /portfolio/orders/queue_positions
//!   queue_position ORDER_ID GET /portfolio/orders/{id}/queue_position

const std = @import("std");
const common = @import("common");
const praescientia = @import("praescientia");

pub fn main(init: std.process.Init) !u8 {
    return common.runMain(init, "praescientia-orders", &.{
        .{ .name = "list", .description = "List orders", .run = cmdList },
        .{ .name = "create", .description = "Create a new order", .run = cmdCreate },
        .{ .name = "get", .description = "Get order details", .run = cmdGet },
        .{ .name = "cancel", .description = "Cancel an order", .run = cmdCancel },
        .{ .name = "amend", .description = "Amend price and/or count of an order", .run = cmdAmend },
        .{ .name = "decrease", .description = "Decrease order quantity", .run = cmdDecrease },
        .{ .name = "queue_positions", .description = "Queue positions for all resting orders", .run = cmdQueuePositions },
        .{ .name = "queue_position", .description = "Queue position for a specific order", .run = cmdQueuePosition },
    });
}

fn parseU32(s: []const u8) ?u32 {
    return std.fmt.parseInt(u32, s, 10) catch null;
}

fn parseI64(s: []const u8) ?i64 {
    return std.fmt.parseInt(i64, s, 10) catch null;
}

fn generateClientOrderId(arena: std.mem.Allocator) ![]const u8 {
    var buf: [praescientia.txlog.tx_id_len]u8 = undefined;
    praescientia.txlog.generateTxId(&buf);
    return arena.dupe(u8, buf[0..]);
}

fn cmdList(ctx: *common.Context) !u8 {
    var opts: common.kalshi.orders.ListOptions = .{};
    if (ctx.flagValue("--ticker")) |v| opts.ticker = v;
    if (ctx.flagValue("--event_ticker")) |v| opts.event_ticker = v;
    if (ctx.flagValue("--status")) |v| opts.status = v;
    if (ctx.flagValue("--limit")) |v| opts.limit = parseU32(v);
    const result = try common.kalshi.orders.list(ctx.client, ctx.arena, opts);
    try common.printJson(result, ctx.stdout);
    return 0;
}

fn cmdCreate(ctx: *common.Context) !u8 {
    const ticker = ctx.flagValue("--ticker") orelse {
        try ctx.stderr.print("error: --ticker is required\n", .{});
        return 2;
    };
    const side = ctx.flagValue("--side") orelse {
        try ctx.stderr.print("error: --side is required (yes|no)\n", .{});
        return 2;
    };
    const count_str = ctx.flagValue("--count") orelse {
        try ctx.stderr.print("error: --count is required\n", .{});
        return 2;
    };
    const count = parseU32(count_str) orelse {
        try ctx.stderr.print("error: --count must be a non-negative integer\n", .{});
        return 2;
    };

    const order_type: []const u8 = ctx.flagValue("--type") orelse "limit";
    const action: []const u8 = ctx.flagValue("--action") orelse "buy";
    const client_order_id = ctx.flagValue("--client-order-id") orelse
        try generateClientOrderId(ctx.arena);

    var order: common.kalshi.orders.CreateOrder = .{
        .ticker = ticker,
        .client_order_id = client_order_id,
        .side = side,
        .action = action,
        .@"type" = order_type,
        .count = count,
    };
    if (ctx.flagValue("--yes_price")) |v| order.yes_price = parseU32(v);
    if (ctx.flagValue("--no_price")) |v| order.no_price = parseU32(v);

    const result = try common.kalshi.orders.create(ctx.client, ctx.arena, order);
    try common.printJson(result, ctx.stdout);
    return 0;
}

fn cmdGet(ctx: *common.Context) !u8 {
    const order_id = ctx.positional(0) orelse {
        try ctx.stderr.print("error: ORDER_ID positional argument required\n", .{});
        return 2;
    };
    const v = try common.kalshi.orders.get(ctx.client, ctx.arena, order_id);
    try common.printJson(v, ctx.stdout);
    return 0;
}

fn cmdCancel(ctx: *common.Context) !u8 {
    const order_id = ctx.positional(0) orelse {
        try ctx.stderr.print("error: ORDER_ID positional argument required\n", .{});
        return 2;
    };
    const v = try common.kalshi.orders.cancel(ctx.client, ctx.arena, order_id);
    try common.printJson(v, ctx.stdout);
    return 0;
}

fn cmdAmend(ctx: *common.Context) !u8 {
    const order_id = ctx.positional(0) orelse {
        try ctx.stderr.print("error: ORDER_ID positional argument required\n", .{});
        return 2;
    };
    const price_opt: ?u32 = if (ctx.flagValue("--price")) |v| parseU32(v) else null;
    const count_opt: ?u32 = if (ctx.flagValue("--count")) |v| parseU32(v) else null;
    if (price_opt == null and count_opt == null) {
        try ctx.stderr.print("error: at least one of --price or --count is required\n", .{});
        return 2;
    }

    var body: common.kalshi.orders.AmendOrder = .{
        .client_order_id = try generateClientOrderId(ctx.arena),
        .count = count_opt,
        .yes_price = price_opt,
    };
    _ = &body;

    const v = try common.kalshi.orders.amend(ctx.client, ctx.arena, order_id, body);
    try common.printJson(v, ctx.stdout);
    return 0;
}

fn cmdDecrease(ctx: *common.Context) !u8 {
    const order_id = ctx.positional(0) orelse {
        try ctx.stderr.print("error: ORDER_ID positional argument required\n", .{});
        return 2;
    };
    const reduce_str = ctx.flagValue("--reduce_by") orelse {
        try ctx.stderr.print("error: --reduce_by is required\n", .{});
        return 2;
    };
    const reduce_by = parseU32(reduce_str) orelse {
        try ctx.stderr.print("error: --reduce_by must be a non-negative integer\n", .{});
        return 2;
    };
    const v = try common.kalshi.orders.decrease(ctx.client, ctx.arena, order_id, reduce_by);
    try common.printJson(v, ctx.stdout);
    return 0;
}

fn cmdQueuePositions(ctx: *common.Context) !u8 {
    const v = try common.kalshi.orders.queuePositions(ctx.client, ctx.arena);
    try common.printJson(v, ctx.stdout);
    return 0;
}

fn cmdQueuePosition(ctx: *common.Context) !u8 {
    const order_id = ctx.positional(0) orelse {
        try ctx.stderr.print("error: ORDER_ID positional argument required\n", .{});
        return 2;
    };
    const v = try common.kalshi.orders.queuePosition(ctx.client, ctx.arena, order_id);
    try common.printJson(v, ctx.stdout);
    return 0;
}

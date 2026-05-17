//! Kalshi `/portfolio/orders*` endpoints — read, place, cancel, amend.
//!
//! All write paths require an idempotency key (`client_order_id`). The
//! `test_conn` smoke harness only calls the read endpoints; placing real
//! orders is gated behind a separate one-off tool to avoid accidental
//! demo-state mutations.

const std = @import("std");
const client_mod = @import("client.zig");

const Allocator = std.mem.Allocator;
const Client = client_mod.Client;
const QueryParam = client_mod.QueryParam;

pub const OrdersList = struct {
    cursor: []const u8 = "",
    orders: []std.json.Value = &.{},
};

pub const OrderResponse = struct {
    order: std.json.Value,
};

pub const ListOptions = struct {
    limit: ?u32 = null,
    cursor: ?[]const u8 = null,
    ticker: ?[]const u8 = null,
    event_ticker: ?[]const u8 = null,
    status: ?[]const u8 = null,
    min_ts: ?i64 = null,
    max_ts: ?i64 = null,
};

/// Body schema for POST /portfolio/orders. `type` is a Zig keyword; the field
/// is declared as `@"type"` and std.json reflects on the identifier, so the
/// emitted JSON correctly uses `"type"`.
pub const CreateOrder = struct {
    ticker: []const u8,
    client_order_id: []const u8,
    side: []const u8, // "yes" | "no"
    action: []const u8, // "buy" | "sell"
    @"type": []const u8, // "limit" | "market"
    count: u32,
    yes_price: ?u32 = null,
    no_price: ?u32 = null,
    expiration_ts: ?i64 = null,
    sell_position_floor: ?u32 = null,
    buy_max_cost: ?u32 = null,
};

pub const AmendOrder = struct {
    client_order_id: []const u8,
    count: ?u32 = null,
    yes_price: ?u32 = null,
    no_price: ?u32 = null,
};

/// GET /portfolio/orders
pub fn list(client: *Client, arena: Allocator, opts: ListOptions) !OrdersList {
    if (!client.hasCredentials()) return error.MissingCredentials;
    var q: std.array_list.Managed(QueryParam) = .init(arena);
    if (opts.limit) |v| try q.append(.{ .key = "limit", .value = try std.fmt.allocPrint(arena, "{d}", .{v}) });
    if (opts.cursor) |v| try q.append(.{ .key = "cursor", .value = v });
    if (opts.ticker) |v| try q.append(.{ .key = "ticker", .value = v });
    if (opts.event_ticker) |v| try q.append(.{ .key = "event_ticker", .value = v });
    if (opts.status) |v| try q.append(.{ .key = "status", .value = v });
    if (opts.min_ts) |v| try q.append(.{ .key = "min_ts", .value = try std.fmt.allocPrint(arena, "{d}", .{v}) });
    if (opts.max_ts) |v| try q.append(.{ .key = "max_ts", .value = try std.fmt.allocPrint(arena, "{d}", .{v}) });

    const resp = try client.request(arena, .{ .path = "/portfolio/orders", .query = q.items });
    if (!resp.isSuccess()) return error.HttpStatus;
    return resp.parseInto(OrdersList, arena);
}

/// GET /portfolio/orders/{order_id}
pub fn get(client: *Client, arena: Allocator, order_id: []const u8) !std.json.Value {
    if (!client.hasCredentials()) return error.MissingCredentials;
    const path = try std.fmt.allocPrint(arena, "/portfolio/orders/{s}", .{order_id});
    const resp = try client.request(arena, .{ .path = path });
    if (!resp.isSuccess()) return error.HttpStatus;
    return std.json.parseFromSliceLeaky(std.json.Value, arena, resp.body, .{});
}

/// POST /portfolio/orders — place a new order.
pub fn create(client: *Client, arena: Allocator, order: CreateOrder) !std.json.Value {
    if (!client.hasCredentials()) return error.MissingCredentials;
    var aw: std.Io.Writer.Allocating = .init(arena);
    try std.json.Stringify.value(order, .{ .whitespace = .minified, .emit_null_optional_fields = false }, &aw.writer);
    const body = aw.written();
    const resp = try client.request(arena, .{
        .path = "/portfolio/orders",
        .method = .POST,
        .body = body,
    });
    if (!resp.isSuccess()) return error.HttpStatus;
    return std.json.parseFromSliceLeaky(std.json.Value, arena, resp.body, .{});
}

/// DELETE /portfolio/orders/{order_id}
pub fn cancel(client: *Client, arena: Allocator, order_id: []const u8) !std.json.Value {
    if (!client.hasCredentials()) return error.MissingCredentials;
    const path = try std.fmt.allocPrint(arena, "/portfolio/orders/{s}", .{order_id});
    const resp = try client.request(arena, .{ .path = path, .method = .DELETE });
    if (!resp.isSuccess()) return error.HttpStatus;
    return std.json.parseFromSliceLeaky(std.json.Value, arena, resp.body, .{});
}

/// POST /portfolio/orders/{order_id}/amend
pub fn amend(client: *Client, arena: Allocator, order_id: []const u8, body_struct: AmendOrder) !std.json.Value {
    if (!client.hasCredentials()) return error.MissingCredentials;
    var aw: std.Io.Writer.Allocating = .init(arena);
    try std.json.Stringify.value(body_struct, .{ .whitespace = .minified, .emit_null_optional_fields = false }, &aw.writer);
    const path = try std.fmt.allocPrint(arena, "/portfolio/orders/{s}/amend", .{order_id});
    const resp = try client.request(arena, .{
        .path = path,
        .method = .POST,
        .body = aw.written(),
    });
    if (!resp.isSuccess()) return error.HttpStatus;
    return std.json.parseFromSliceLeaky(std.json.Value, arena, resp.body, .{});
}

const fixture_list = @embedFile("testdata/orders_list.json");

test "parses /portfolio/orders list fixture" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const parsed = try std.json.parseFromSliceLeaky(OrdersList, a, fixture_list, .{ .ignore_unknown_fields = true });
    try std.testing.expectEqual(@as(usize, 0), parsed.orders.len);
}

test "CreateOrder serializes with type/yes_price/null elision" {
    const a = std.testing.allocator;
    const order: CreateOrder = .{
        .ticker = "DEMO-T1",
        .client_order_id = "idem-001",
        .side = "yes",
        .action = "buy",
        .@"type" = "limit",
        .count = 10,
        .yes_price = 50,
    };
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try std.json.Stringify.value(order, .{ .whitespace = .minified, .emit_null_optional_fields = false }, &aw.writer);
    // Field order tracks Zig struct declaration order.
    try std.testing.expectEqualStrings(
        "{\"ticker\":\"DEMO-T1\",\"client_order_id\":\"idem-001\",\"side\":\"yes\",\"action\":\"buy\",\"type\":\"limit\",\"count\":10,\"yes_price\":50}",
        aw.written(),
    );
}

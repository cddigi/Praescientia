//! Kalshi RFQ / quote workflow.

const std = @import("std");
const client_mod = @import("client.zig");

const Allocator = std.mem.Allocator;
const Client = client_mod.Client;
const QueryParam = client_mod.QueryParam;

pub const RfqList = struct {
    cursor: []const u8 = "",
    rfqs: []std.json.Value = &.{},
};

pub const ListOptions = struct {
    limit: ?u32 = null,
    cursor: ?[]const u8 = null,
    status: ?[]const u8 = null,
};

/// Body schema for POST /communications/rfqs.
pub const CreateRfq = struct {
    ticker: []const u8,
    side: []const u8, // "yes" | "no"
    count: u32,
    expiration_ts: ?i64 = null,
};

/// Body schema for POST /communications/quotes.
pub const CreateQuote = struct {
    rfq_id: []const u8,
    price: u32, // cents
    count: u32,
    side: ?[]const u8 = null,
    expiration_ts: ?i64 = null,
};

/// GET /communications/id — logged-in user's communications ID.
pub fn commsId(client: *Client, arena: Allocator) !std.json.Value {
    if (!client.hasCredentials()) return error.MissingCredentials;
    const resp = try client.request(arena, .{ .path = "/communications/id" });
    if (!resp.isSuccess()) return error.HttpStatus;
    return std.json.parseFromSliceLeaky(std.json.Value, arena, resp.body, .{});
}

/// GET /communications/rfqs
pub fn listRfqs(client: *Client, arena: Allocator, opts: ListOptions) !RfqList {
    if (!client.hasCredentials()) return error.MissingCredentials;
    var q: std.array_list.Managed(QueryParam) = .init(arena);
    if (opts.limit) |v| try q.append(.{ .key = "limit", .value = try std.fmt.allocPrint(arena, "{d}", .{v}) });
    if (opts.cursor) |v| try q.append(.{ .key = "cursor", .value = v });
    if (opts.status) |v| try q.append(.{ .key = "status", .value = v });
    const resp = try client.request(arena, .{ .path = "/communications/rfqs", .query = q.items });
    if (!resp.isSuccess()) return error.HttpStatus;
    return resp.parseInto(RfqList, arena);
}

/// POST /communications/rfqs — create a new RFQ.
pub fn createRfq(client: *Client, arena: Allocator, body_struct: CreateRfq) !std.json.Value {
    if (!client.hasCredentials()) return error.MissingCredentials;
    var aw: std.Io.Writer.Allocating = .init(arena);
    try std.json.Stringify.value(body_struct, .{ .whitespace = .minified, .emit_null_optional_fields = false }, &aw.writer);
    const resp = try client.request(arena, .{
        .path = "/communications/rfqs",
        .method = .POST,
        .body = aw.written(),
    });
    if (!resp.isSuccess()) return error.HttpStatus;
    return std.json.parseFromSliceLeaky(std.json.Value, arena, resp.body, .{});
}

/// GET /communications/rfqs/{rfq_id}
pub fn getRfq(client: *Client, arena: Allocator, rfq_id: []const u8) !std.json.Value {
    if (!client.hasCredentials()) return error.MissingCredentials;
    const path = try std.fmt.allocPrint(arena, "/communications/rfqs/{s}", .{rfq_id});
    const resp = try client.request(arena, .{ .path = path });
    if (!resp.isSuccess()) return error.HttpStatus;
    return std.json.parseFromSliceLeaky(std.json.Value, arena, resp.body, .{});
}

/// DELETE /communications/rfqs/{rfq_id}
pub fn cancelRfq(client: *Client, arena: Allocator, rfq_id: []const u8) !std.json.Value {
    if (!client.hasCredentials()) return error.MissingCredentials;
    const path = try std.fmt.allocPrint(arena, "/communications/rfqs/{s}", .{rfq_id});
    const resp = try client.request(arena, .{ .path = path, .method = .DELETE });
    if (!resp.isSuccess()) return error.HttpStatus;
    return std.json.parseFromSliceLeaky(std.json.Value, arena, resp.body, .{});
}

/// GET /communications/quotes
pub fn listQuotes(client: *Client, arena: Allocator, opts: ListOptions) !std.json.Value {
    if (!client.hasCredentials()) return error.MissingCredentials;
    var q: std.array_list.Managed(QueryParam) = .init(arena);
    if (opts.limit) |v| try q.append(.{ .key = "limit", .value = try std.fmt.allocPrint(arena, "{d}", .{v}) });
    if (opts.cursor) |v| try q.append(.{ .key = "cursor", .value = v });
    if (opts.status) |v| try q.append(.{ .key = "status", .value = v });
    const resp = try client.request(arena, .{ .path = "/communications/quotes", .query = q.items });
    if (!resp.isSuccess()) return error.HttpStatus;
    return std.json.parseFromSliceLeaky(std.json.Value, arena, resp.body, .{});
}

/// POST /communications/quotes — create a quote in response to an RFQ.
pub fn createQuote(client: *Client, arena: Allocator, body_struct: CreateQuote) !std.json.Value {
    if (!client.hasCredentials()) return error.MissingCredentials;
    var aw: std.Io.Writer.Allocating = .init(arena);
    try std.json.Stringify.value(body_struct, .{ .whitespace = .minified, .emit_null_optional_fields = false }, &aw.writer);
    const resp = try client.request(arena, .{
        .path = "/communications/quotes",
        .method = .POST,
        .body = aw.written(),
    });
    if (!resp.isSuccess()) return error.HttpStatus;
    return std.json.parseFromSliceLeaky(std.json.Value, arena, resp.body, .{});
}

/// GET /communications/quotes/{quote_id}
pub fn getQuote(client: *Client, arena: Allocator, quote_id: []const u8) !std.json.Value {
    if (!client.hasCredentials()) return error.MissingCredentials;
    const path = try std.fmt.allocPrint(arena, "/communications/quotes/{s}", .{quote_id});
    const resp = try client.request(arena, .{ .path = path });
    if (!resp.isSuccess()) return error.HttpStatus;
    return std.json.parseFromSliceLeaky(std.json.Value, arena, resp.body, .{});
}

/// DELETE /communications/quotes/{quote_id}
pub fn deleteQuote(client: *Client, arena: Allocator, quote_id: []const u8) !std.json.Value {
    if (!client.hasCredentials()) return error.MissingCredentials;
    const path = try std.fmt.allocPrint(arena, "/communications/quotes/{s}", .{quote_id});
    const resp = try client.request(arena, .{ .path = path, .method = .DELETE });
    if (!resp.isSuccess()) return error.HttpStatus;
    return std.json.parseFromSliceLeaky(std.json.Value, arena, resp.body, .{});
}

/// PUT /communications/quotes/{quote_id}/accept
pub fn acceptQuote(client: *Client, arena: Allocator, quote_id: []const u8) !std.json.Value {
    if (!client.hasCredentials()) return error.MissingCredentials;
    const path = try std.fmt.allocPrint(arena, "/communications/quotes/{s}/accept", .{quote_id});
    const resp = try client.request(arena, .{ .path = path, .method = .PUT });
    if (!resp.isSuccess()) return error.HttpStatus;
    return std.json.parseFromSliceLeaky(std.json.Value, arena, resp.body, .{});
}

/// PUT /communications/quotes/{quote_id}/confirm
pub fn confirmQuote(client: *Client, arena: Allocator, quote_id: []const u8) !std.json.Value {
    if (!client.hasCredentials()) return error.MissingCredentials;
    const path = try std.fmt.allocPrint(arena, "/communications/quotes/{s}/confirm", .{quote_id});
    const resp = try client.request(arena, .{ .path = path, .method = .PUT });
    if (!resp.isSuccess()) return error.HttpStatus;
    return std.json.parseFromSliceLeaky(std.json.Value, arena, resp.body, .{});
}

const fixture_rfqs = @embedFile("testdata/communications_rfqs.json");

test "parses /communications/rfqs fixture" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const parsed = try std.json.parseFromSliceLeaky(RfqList, a, fixture_rfqs, .{ .ignore_unknown_fields = true });
    try std.testing.expect(parsed.rfqs.len > 0);
}

test "CreateRfq serializes minified with null elision" {
    const a = std.testing.allocator;
    const body: CreateRfq = .{ .ticker = "DEMO-T1", .side = "yes", .count = 25 };
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try std.json.Stringify.value(body, .{ .whitespace = .minified, .emit_null_optional_fields = false }, &aw.writer);
    try std.testing.expectEqualStrings(
        "{\"ticker\":\"DEMO-T1\",\"side\":\"yes\",\"count\":25}",
        aw.written(),
    );
}

test "CreateQuote serializes minified with null elision" {
    const a = std.testing.allocator;
    const body: CreateQuote = .{ .rfq_id = "RFQ-1", .price = 50, .count = 10 };
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try std.json.Stringify.value(body, .{ .whitespace = .minified, .emit_null_optional_fields = false }, &aw.writer);
    try std.testing.expectEqualStrings(
        "{\"rfq_id\":\"RFQ-1\",\"price\":50,\"count\":10}",
        aw.written(),
    );
}

test {
    _ = commsId;
    _ = createRfq;
    _ = listQuotes;
    _ = createQuote;
    _ = getQuote;
    _ = deleteQuote;
    _ = confirmQuote;
}

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
};

/// GET /communications/rfqs
pub fn listRfqs(client: *Client, arena: Allocator, opts: ListOptions) !RfqList {
    if (!client.hasCredentials()) return error.MissingCredentials;
    var q: std.array_list.Managed(QueryParam) = .init(arena);
    if (opts.limit) |v| try q.append(.{ .key = "limit", .value = try std.fmt.allocPrint(arena, "{d}", .{v}) });
    if (opts.cursor) |v| try q.append(.{ .key = "cursor", .value = v });
    const resp = try client.request(arena, .{ .path = "/communications/rfqs", .query = q.items });
    if (!resp.isSuccess()) return error.HttpStatus;
    return resp.parseInto(RfqList, arena);
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

/// PUT /communications/quotes/{quote_id}/accept
pub fn acceptQuote(client: *Client, arena: Allocator, quote_id: []const u8) !std.json.Value {
    if (!client.hasCredentials()) return error.MissingCredentials;
    const path = try std.fmt.allocPrint(arena, "/communications/quotes/{s}/accept", .{quote_id});
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

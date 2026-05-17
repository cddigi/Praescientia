//! Kalshi `/portfolio/order_groups/*` endpoints — group, reset, trigger, limit.

const std = @import("std");
const client_mod = @import("client.zig");

const Allocator = std.mem.Allocator;
const Client = client_mod.Client;

/// GET /portfolio/order_groups — current demo response is an empty `{}`.
/// Returned as a Value tree because the wire format isn't stable yet.
pub fn list(client: *Client, arena: Allocator) !std.json.Value {
    if (!client.hasCredentials()) return error.MissingCredentials;
    const resp = try client.request(arena, .{ .path = "/portfolio/order_groups" });
    if (!resp.isSuccess()) return error.HttpStatus;
    return std.json.parseFromSliceLeaky(std.json.Value, arena, resp.body, .{});
}

/// GET /portfolio/order_groups/{group_id}
pub fn get(client: *Client, arena: Allocator, group_id: []const u8) !std.json.Value {
    if (!client.hasCredentials()) return error.MissingCredentials;
    const path = try std.fmt.allocPrint(arena, "/portfolio/order_groups/{s}", .{group_id});
    const resp = try client.request(arena, .{ .path = path });
    if (!resp.isSuccess()) return error.HttpStatus;
    return std.json.parseFromSliceLeaky(std.json.Value, arena, resp.body, .{});
}

/// DELETE /portfolio/order_groups/{group_id}
pub fn delete_(client: *Client, arena: Allocator, group_id: []const u8) !std.json.Value {
    if (!client.hasCredentials()) return error.MissingCredentials;
    const path = try std.fmt.allocPrint(arena, "/portfolio/order_groups/{s}", .{group_id});
    const resp = try client.request(arena, .{ .path = path, .method = .DELETE });
    if (!resp.isSuccess()) return error.HttpStatus;
    return std.json.parseFromSliceLeaky(std.json.Value, arena, resp.body, .{});
}

/// PUT /portfolio/order_groups/{group_id}/reset
pub fn reset(client: *Client, arena: Allocator, group_id: []const u8) !std.json.Value {
    if (!client.hasCredentials()) return error.MissingCredentials;
    const path = try std.fmt.allocPrint(arena, "/portfolio/order_groups/{s}/reset", .{group_id});
    const resp = try client.request(arena, .{ .path = path, .method = .PUT });
    if (!resp.isSuccess()) return error.HttpStatus;
    return std.json.parseFromSliceLeaky(std.json.Value, arena, resp.body, .{});
}

/// PUT /portfolio/order_groups/{group_id}/trigger
pub fn trigger(client: *Client, arena: Allocator, group_id: []const u8) !std.json.Value {
    if (!client.hasCredentials()) return error.MissingCredentials;
    const path = try std.fmt.allocPrint(arena, "/portfolio/order_groups/{s}/trigger", .{group_id});
    const resp = try client.request(arena, .{ .path = path, .method = .PUT });
    if (!resp.isSuccess()) return error.HttpStatus;
    return std.json.parseFromSliceLeaky(std.json.Value, arena, resp.body, .{});
}

/// POST /portfolio/order_groups/create — create a group with a contract limit.
pub fn create(client: *Client, arena: Allocator, max_contracts: u32) !std.json.Value {
    if (!client.hasCredentials()) return error.MissingCredentials;
    const body = try std.fmt.allocPrint(arena, "{{\"max_contracts\":{d}}}", .{max_contracts});
    const resp = try client.request(arena, .{
        .path = "/portfolio/order_groups/create",
        .method = .POST,
        .body = body,
    });
    if (!resp.isSuccess()) return error.HttpStatus;
    return std.json.parseFromSliceLeaky(std.json.Value, arena, resp.body, .{});
}

/// PUT /portfolio/order_groups/{group_id}/limit — update contract limit.
pub fn setLimit(client: *Client, arena: Allocator, group_id: []const u8, max_contracts: u32) !std.json.Value {
    if (!client.hasCredentials()) return error.MissingCredentials;
    const path = try std.fmt.allocPrint(arena, "/portfolio/order_groups/{s}/limit", .{group_id});
    const body = try std.fmt.allocPrint(arena, "{{\"max_contracts\":{d}}}", .{max_contracts});
    const resp = try client.request(arena, .{ .path = path, .method = .PUT, .body = body });
    if (!resp.isSuccess()) return error.HttpStatus;
    return std.json.parseFromSliceLeaky(std.json.Value, arena, resp.body, .{});
}

const fixture_list = @embedFile("testdata/order_groups_list.json");

test "parses /portfolio/order_groups fixture (empty)" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v = try std.json.parseFromSliceLeaky(std.json.Value, a, fixture_list, .{});
    // Demo currently returns `{}` — an object with no keys.
    try std.testing.expectEqual(@as(usize, 0), v.object.count());
}

test {
    _ = create;
    _ = setLimit;
}

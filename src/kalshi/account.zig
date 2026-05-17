//! Kalshi `/account/*` and `/api_keys` endpoints. All require authentication.

const std = @import("std");
const client_mod = @import("client.zig");

const Allocator = std.mem.Allocator;
const Client = client_mod.Client;

pub const RateBucket = struct {
    bucket_capacity: i64 = 0,
    refill_rate: i64 = 0,
};

pub const Limits = struct {
    read: RateBucket = .{},
    write: RateBucket = .{},
    usage_tier: []const u8 = "",
};

pub const ApiKey = struct {
    api_key_id: []const u8,
    name: []const u8 = "",
    scopes: []const []const u8 = &.{},
};

pub const ApiKeyList = struct {
    api_keys: []ApiKey,
};

/// GET /account/limits — rate-limit buckets and tier.
pub fn limits(client: *Client, arena: Allocator) !Limits {
    if (!client.hasCredentials()) return error.MissingCredentials;
    const resp = try client.request(arena, .{ .path = "/account/limits" });
    if (!resp.isSuccess()) return error.HttpStatus;
    return resp.parseInto(Limits, arena);
}

/// GET /api_keys — list of all API keys on the account.
pub fn listApiKeys(client: *Client, arena: Allocator) !ApiKeyList {
    if (!client.hasCredentials()) return error.MissingCredentials;
    const resp = try client.request(arena, .{ .path = "/api_keys" });
    if (!resp.isSuccess()) return error.HttpStatus;
    return resp.parseInto(ApiKeyList, arena);
}

/// DELETE /api_keys/{id}
pub fn deleteApiKey(client: *Client, arena: Allocator, api_key_id: []const u8) !std.json.Value {
    if (!client.hasCredentials()) return error.MissingCredentials;
    const path = try std.fmt.allocPrint(arena, "/api_keys/{s}", .{api_key_id});
    const resp = try client.request(arena, .{ .path = path, .method = .DELETE });
    if (!resp.isSuccess()) return error.HttpStatus;
    return std.json.parseFromSliceLeaky(std.json.Value, arena, resp.body, .{});
}

const fixture_limits = @embedFile("testdata/account_limits.json");
const fixture_keys = @embedFile("testdata/account_api_keys.json");

test "parses /account/limits fixture" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const parsed = try std.json.parseFromSliceLeaky(Limits, a, fixture_limits, .{ .ignore_unknown_fields = true });
    try std.testing.expect(parsed.read.bucket_capacity > 0);
    try std.testing.expect(parsed.write.bucket_capacity > 0);
    try std.testing.expect(parsed.usage_tier.len > 0);
}

test "parses /api_keys fixture" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const parsed = try std.json.parseFromSliceLeaky(ApiKeyList, a, fixture_keys, .{ .ignore_unknown_fields = true });
    try std.testing.expect(parsed.api_keys.len > 0);
    try std.testing.expect(parsed.api_keys[0].api_key_id.len > 0);
}

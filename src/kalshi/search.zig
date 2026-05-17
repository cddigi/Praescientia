//! Kalshi search-related endpoints.
//!
//! The demo environment 404s `/search/*` and `/structured_targets`; the wrappers
//! are present so live consumers have the full surface. `series(client, arena, ticker)`
//! is the safe live-callable read.

const std = @import("std");
const client_mod = @import("client.zig");

const Allocator = std.mem.Allocator;
const Client = client_mod.Client;

/// GET /series/{series_ticker} — series-level metadata.
pub fn series(client: *Client, arena: Allocator, series_ticker: []const u8) !std.json.Value {
    const path = try std.fmt.allocPrint(arena, "/series/{s}", .{series_ticker});
    const resp = try client.request(arena, .{ .path = path });
    if (!resp.isSuccess()) return error.HttpStatus;
    return std.json.parseFromSliceLeaky(std.json.Value, arena, resp.body, .{});
}

/// GET /search/tags_by_categories — live-only.
pub fn tagsByCategories(client: *Client, arena: Allocator) !std.json.Value {
    const resp = try client.request(arena, .{ .path = "/search/tags_by_categories" });
    if (!resp.isSuccess()) return error.HttpStatus;
    return std.json.parseFromSliceLeaky(std.json.Value, arena, resp.body, .{});
}

/// GET /search/filters_by_sport — live-only.
pub fn filtersBySport(client: *Client, arena: Allocator) !std.json.Value {
    const resp = try client.request(arena, .{ .path = "/search/filters_by_sport" });
    if (!resp.isSuccess()) return error.HttpStatus;
    return std.json.parseFromSliceLeaky(std.json.Value, arena, resp.body, .{});
}

/// GET /structured_targets — live-only.
pub fn structuredTargets(client: *Client, arena: Allocator) !std.json.Value {
    const resp = try client.request(arena, .{ .path = "/structured_targets" });
    if (!resp.isSuccess()) return error.HttpStatus;
    return std.json.parseFromSliceLeaky(std.json.Value, arena, resp.body, .{});
}

test {
    // Surface compile-tested only; no fixtures captured because /search/* and
    // /structured_targets 404 in the demo environment at fixture-capture time.
    _ = series;
    _ = tagsByCategories;
    _ = filtersBySport;
    _ = structuredTargets;
}

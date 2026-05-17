//! Kalshi `/events/*` endpoints.

const std = @import("std");
const client_mod = @import("client.zig");
const markets_mod = @import("markets.zig");

const Allocator = std.mem.Allocator;
const Client = client_mod.Client;
const QueryParam = client_mod.QueryParam;

pub const Event = struct {
    event_ticker: []const u8,
    series_ticker: []const u8 = "",
    title: []const u8 = "",
    sub_title: ?[]const u8 = null,
    category: []const u8 = "",
    mutually_exclusive: bool = false,
    strike_period: ?[]const u8 = null,
    collateral_return_type: ?[]const u8 = null,
    available_on_brokers: bool = false,
};

pub const EventList = struct {
    events: []Event,
    cursor: ?[]const u8 = null,
};

/// Single-event response — Kalshi wraps in an `event` key plus a `markets` array.
pub const EventDetail = struct {
    event: Event,
    markets: []markets_mod.Market = &.{},
};

pub const ListOptions = struct {
    limit: ?u32 = null,
    cursor: ?[]const u8 = null,
    status: ?[]const u8 = null,
    series_ticker: ?[]const u8 = null,
    with_nested_markets: ?bool = null,
};

/// GET /events
pub fn list(client: *Client, arena: Allocator, opts: ListOptions) !EventList {
    var query: std.array_list.Managed(QueryParam) = .init(arena);
    if (opts.limit) |v| try query.append(.{ .key = "limit", .value = try std.fmt.allocPrint(arena, "{d}", .{v}) });
    if (opts.cursor) |v| try query.append(.{ .key = "cursor", .value = v });
    if (opts.status) |v| try query.append(.{ .key = "status", .value = v });
    if (opts.series_ticker) |v| try query.append(.{ .key = "series_ticker", .value = v });
    if (opts.with_nested_markets) |v| try query.append(.{ .key = "with_nested_markets", .value = if (v) "true" else "false" });

    const resp = try client.request(arena, .{ .path = "/events", .query = query.items });
    if (!resp.isSuccess()) return error.HttpStatus;
    return resp.parseInto(EventList, arena);
}

/// GET /events/{ticker}
pub fn get(client: *Client, arena: Allocator, event_ticker: []const u8) !EventDetail {
    const path = try std.fmt.allocPrint(arena, "/events/{s}", .{event_ticker});
    const resp = try client.request(arena, .{ .path = path });
    if (!resp.isSuccess()) return error.HttpStatus;
    return resp.parseInto(EventDetail, arena);
}

pub const MultivariateOptions = struct {
    limit: ?u32 = null,
    cursor: ?[]const u8 = null,
};

/// GET /multivariate_events — multivariate combo events.
pub fn listMultivariate(client: *Client, arena: Allocator, opts: MultivariateOptions) !std.json.Value {
    var q: std.array_list.Managed(QueryParam) = .init(arena);
    if (opts.limit) |v| try q.append(.{ .key = "limit", .value = try std.fmt.allocPrint(arena, "{d}", .{v}) });
    if (opts.cursor) |v| try q.append(.{ .key = "cursor", .value = v });

    const resp = try client.request(arena, .{ .path = "/multivariate_events", .query = q.items });
    if (!resp.isSuccess()) return error.HttpStatus;
    return std.json.parseFromSliceLeaky(std.json.Value, arena, resp.body, .{});
}

/// GET /events/{event_ticker}/metadata
pub fn metadata(client: *Client, arena: Allocator, event_ticker: []const u8) !std.json.Value {
    const path = try std.fmt.allocPrint(arena, "/events/{s}/metadata", .{event_ticker});
    const resp = try client.request(arena, .{ .path = path });
    if (!resp.isSuccess()) return error.HttpStatus;
    return std.json.parseFromSliceLeaky(std.json.Value, arena, resp.body, .{});
}

pub const CandlesticksOptions = struct {
    period_interval: ?u32 = null,
    start_ts: ?i64 = null,
    end_ts: ?i64 = null,
};

/// GET /series/{series_ticker}/events/{event_ticker}/candlesticks
pub fn candlesticks(
    client: *Client,
    arena: Allocator,
    series_ticker: []const u8,
    event_ticker: []const u8,
    opts: CandlesticksOptions,
) !std.json.Value {
    var q: std.array_list.Managed(QueryParam) = .init(arena);
    if (opts.period_interval) |v| try q.append(.{ .key = "period_interval", .value = try std.fmt.allocPrint(arena, "{d}", .{v}) });
    if (opts.start_ts) |v| try q.append(.{ .key = "start_ts", .value = try std.fmt.allocPrint(arena, "{d}", .{v}) });
    if (opts.end_ts) |v| try q.append(.{ .key = "end_ts", .value = try std.fmt.allocPrint(arena, "{d}", .{v}) });

    const path = try std.fmt.allocPrint(arena, "/series/{s}/events/{s}/candlesticks", .{ series_ticker, event_ticker });
    const resp = try client.request(arena, .{ .path = path, .query = q.items });
    if (!resp.isSuccess()) return error.HttpStatus;
    return std.json.parseFromSliceLeaky(std.json.Value, arena, resp.body, .{});
}

/// GET /series/{series_ticker}/events/{event_ticker}/forecast
pub fn forecast(
    client: *Client,
    arena: Allocator,
    series_ticker: []const u8,
    event_ticker: []const u8,
) !std.json.Value {
    const path = try std.fmt.allocPrint(arena, "/series/{s}/events/{s}/forecast", .{ series_ticker, event_ticker });
    const resp = try client.request(arena, .{ .path = path });
    if (!resp.isSuccess()) return error.HttpStatus;
    return std.json.parseFromSliceLeaky(std.json.Value, arena, resp.body, .{});
}

/// GET /multivariate_event_collections/{collection_ticker}
pub fn collection(client: *Client, arena: Allocator, collection_ticker: []const u8) !std.json.Value {
    const path = try std.fmt.allocPrint(arena, "/multivariate_event_collections/{s}", .{collection_ticker});
    const resp = try client.request(arena, .{ .path = path });
    if (!resp.isSuccess()) return error.HttpStatus;
    return std.json.parseFromSliceLeaky(std.json.Value, arena, resp.body, .{});
}

const fixture_list = @embedFile("testdata/events_list.json");
const fixture_get = @embedFile("testdata/events_get.json");

test "parses /events list fixture" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const parsed = try std.json.parseFromSliceLeaky(EventList, a, fixture_list, .{ .ignore_unknown_fields = true });
    try std.testing.expect(parsed.events.len > 0);
    try std.testing.expect(parsed.events[0].event_ticker.len > 0);
}

test "parses /events/{ticker} fixture" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const parsed = try std.json.parseFromSliceLeaky(EventDetail, a, fixture_get, .{ .ignore_unknown_fields = true });
    try std.testing.expect(parsed.event.event_ticker.len > 0);
}

test {
    _ = listMultivariate;
    _ = metadata;
    _ = candlesticks;
    _ = forecast;
    _ = collection;
}

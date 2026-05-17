//! Kalshi `/exchange/*` endpoints — exchange-wide status and schedule.
//! All three calls are unauthenticated GETs.

const std = @import("std");
const client_mod = @import("client.zig");

const Allocator = std.mem.Allocator;
const Client = client_mod.Client;

pub const Status = struct {
    exchange_active: bool,
    trading_active: bool,
};

/// GET /exchange/status
pub fn status(client: *Client, arena: Allocator) !Status {
    const resp = try client.request(arena, .{ .path = "/exchange/status" });
    if (!resp.isSuccess()) return error.HttpStatus;
    return resp.parseInto(Status, arena);
}

/// GET /exchange/schedule
///
/// Returns the parsed JSON tree. The schedule shape is large (standard hours
/// per weekday, maintenance windows, validity windows); rather than freeze a
/// struct that breaks every time Kalshi adds a field, callers can drill into
/// `value.object.get("schedule")` etc.
pub fn schedule(client: *Client, arena: Allocator) !std.json.Value {
    const resp = try client.request(arena, .{ .path = "/exchange/schedule" });
    if (!resp.isSuccess()) return error.HttpStatus;
    return std.json.parseFromSliceLeaky(std.json.Value, arena, resp.body, .{});
}

/// GET /exchange/announcements
pub fn announcements(client: *Client, arena: Allocator) !std.json.Value {
    const resp = try client.request(arena, .{ .path = "/exchange/announcements" });
    if (!resp.isSuccess()) return error.HttpStatus;
    return std.json.parseFromSliceLeaky(std.json.Value, arena, resp.body, .{});
}

const fixture_status = @embedFile("testdata/exchange_status.json");
const fixture_schedule = @embedFile("testdata/exchange_schedule.json");
const fixture_announcements = @embedFile("testdata/exchange_announcements.json");

test "parses /exchange/status fixture" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const parsed = try std.json.parseFromSliceLeaky(Status, a, fixture_status, .{ .ignore_unknown_fields = true });
    try std.testing.expect(parsed.exchange_active);
    try std.testing.expect(parsed.trading_active);
}

test "parses /exchange/schedule fixture into a Value tree" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const v = try std.json.parseFromSliceLeaky(std.json.Value, a, fixture_schedule, .{});
    const root = v.object.get("schedule") orelse return error.MissingSchedule;
    _ = root.object.get("standard_hours") orelse return error.MissingStandardHours;
    _ = root.object.get("maintenance_windows") orelse return error.MissingMaintenance;
}

test "parses /exchange/announcements fixture" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const v = try std.json.parseFromSliceLeaky(std.json.Value, a, fixture_announcements, .{});
    const list = v.object.get("announcements") orelse return error.MissingField;
    try std.testing.expectEqual(@as(std.json.Value, .{ .array = list.array }).array.items.len, list.array.items.len);
}

//! Kalshi live-data + milestones endpoints.

const std = @import("std");
const client_mod = @import("client.zig");

const Allocator = std.mem.Allocator;
const Client = client_mod.Client;
const QueryParam = client_mod.QueryParam;

pub const MilestonesList = struct {
    cursor: []const u8 = "",
    milestones: []std.json.Value = &.{},
};

pub const ListOptions = struct {
    limit: ?u32 = null,
    cursor: ?[]const u8 = null,
};

/// GET /milestones — current and upcoming live-data milestones.
pub fn listMilestones(client: *Client, arena: Allocator, opts: ListOptions) !MilestonesList {
    var q: std.array_list.Managed(QueryParam) = .init(arena);
    if (opts.limit) |v| try q.append(.{ .key = "limit", .value = try std.fmt.allocPrint(arena, "{d}", .{v}) });
    if (opts.cursor) |v| try q.append(.{ .key = "cursor", .value = v });
    const resp = try client.request(arena, .{ .path = "/milestones", .query = q.items });
    if (!resp.isSuccess()) return error.HttpStatus;
    return resp.parseInto(MilestonesList, arena);
}

/// GET /milestones/{milestone_id}
pub fn getMilestone(client: *Client, arena: Allocator, milestone_id: []const u8) !std.json.Value {
    const path = try std.fmt.allocPrint(arena, "/milestones/{s}", .{milestone_id});
    const resp = try client.request(arena, .{ .path = path });
    if (!resp.isSuccess()) return error.HttpStatus;
    return std.json.parseFromSliceLeaky(std.json.Value, arena, resp.body, .{});
}

/// GET /live_data/milestone/{milestone_id}
pub fn liveData(client: *Client, arena: Allocator, milestone_id: []const u8) !std.json.Value {
    const path = try std.fmt.allocPrint(arena, "/live_data/milestone/{s}", .{milestone_id});
    const resp = try client.request(arena, .{ .path = path });
    if (!resp.isSuccess()) return error.HttpStatus;
    return std.json.parseFromSliceLeaky(std.json.Value, arena, resp.body, .{});
}

/// GET /live_data/milestone/{milestone_id}/game_stats
pub fn gameStats(client: *Client, arena: Allocator, milestone_id: []const u8) !std.json.Value {
    const path = try std.fmt.allocPrint(arena, "/live_data/milestone/{s}/game_stats", .{milestone_id});
    const resp = try client.request(arena, .{ .path = path });
    if (!resp.isSuccess()) return error.HttpStatus;
    return std.json.parseFromSliceLeaky(std.json.Value, arena, resp.body, .{});
}

const fixture_milestones = @embedFile("testdata/live_data_milestones.json");

test "parses /milestones fixture" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const parsed = try std.json.parseFromSliceLeaky(MilestonesList, a, fixture_milestones, .{ .ignore_unknown_fields = true });
    try std.testing.expect(parsed.milestones.len > 0);
}

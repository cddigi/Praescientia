//! Dashboard HTTP handlers — one function per route in `kalshi_server.jl`.
//!
//! Every API route returns a Julia-compatible envelope:
//!   `{"success": true, "data": <kalshi-response>, "timestamp": "<ISO-8601 UTC>"}`
//! Errors get `{"success": false, "error": "<msg>", "timestamp": ...}`.
//!
//! Path params like `{ticker}` are captured into `ctx.params[0..param_count]`
//! by the simple segment-matching router in `dispatch`.

const std = @import("std");
const praescientia = @import("praescientia");

pub const kalshi = praescientia.kalshi;
pub const Client = kalshi.client.Client;

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const max_path_params = 4;
pub const dashboard_html = @embedFile("dashboard.html");

pub const RequestCtx = struct {
    arena: Allocator,
    io: Io,
    client: *Client,
    request: *std.http.Server.Request,
    /// Path without query string; matches one of the `Route.pattern`s.
    path: []const u8,
    /// Raw query string (without the `?`). May be empty.
    query: []const u8,
    /// Captured path placeholders in declaration order.
    params: [max_path_params][]const u8,
    param_count: usize,

    pub fn param(self: *const RequestCtx, i: usize) []const u8 {
        std.debug.assert(i < self.param_count);
        return self.params[i];
    }

    /// `?k=v&k=v` lookup. Returns null if missing.
    pub fn queryParam(self: *const RequestCtx, key: []const u8) ?[]const u8 {
        var it = std.mem.splitScalar(u8, self.query, '&');
        while (it.next()) |pair| {
            const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
            if (std.mem.eql(u8, pair[0..eq], key)) return pair[eq + 1 ..];
        }
        return null;
    }
};

pub const Handler = *const fn (ctx: *RequestCtx) anyerror!void;

pub const Route = struct {
    method: std.http.Method,
    /// `{name}` segments capture path params. Literal routes must precede
    /// parametric ones with the same prefix (e.g. /markets/trades before
    /// /markets/{ticker}) — `dispatch` walks the table top to bottom.
    pattern: []const u8,
    handler: Handler,
};

pub const routes = [_]Route{
    // Dashboard
    .{ .method = .GET, .pattern = "/", .handler = serveDashboard },
    // Exchange
    .{ .method = .GET, .pattern = "/api/kalshi/exchange/status", .handler = exchangeStatus },
    .{ .method = .GET, .pattern = "/api/kalshi/exchange/schedule", .handler = exchangeSchedule },
    .{ .method = .GET, .pattern = "/api/kalshi/exchange/announcements", .handler = exchangeAnnouncements },
    // Markets — literal routes before parametric
    .{ .method = .GET, .pattern = "/api/kalshi/markets/trades", .handler = marketsTrades },
    .{ .method = .GET, .pattern = "/api/kalshi/markets", .handler = marketsList },
    .{ .method = .GET, .pattern = "/api/kalshi/markets/{ticker}/orderbook", .handler = marketsOrderbook },
    .{ .method = .GET, .pattern = "/api/kalshi/markets/{ticker}", .handler = marketsGet },
    // Events
    .{ .method = .GET, .pattern = "/api/kalshi/events", .handler = eventsList },
    .{ .method = .GET, .pattern = "/api/kalshi/events/{ticker}", .handler = eventsGet },
    // Portfolio
    .{ .method = .GET, .pattern = "/api/kalshi/portfolio/balance", .handler = portfolioBalance },
    .{ .method = .GET, .pattern = "/api/kalshi/portfolio/positions", .handler = portfolioPositions },
    .{ .method = .GET, .pattern = "/api/kalshi/portfolio/settlements", .handler = portfolioSettlements },
    .{ .method = .GET, .pattern = "/api/kalshi/portfolio/fills", .handler = portfolioFills },
    // Orders
    .{ .method = .GET, .pattern = "/api/kalshi/orders", .handler = ordersList },
    .{ .method = .POST, .pattern = "/api/kalshi/orders", .handler = ordersCreate },
    .{ .method = .DELETE, .pattern = "/api/kalshi/orders/{order_id}", .handler = ordersCancel },
    // Search / Series
    .{ .method = .GET, .pattern = "/api/kalshi/search/tags", .handler = searchTags },
    .{ .method = .GET, .pattern = "/api/kalshi/series/{ticker}", .handler = seriesGet },
};

/// Look up the request method + path against `routes`. Returns null on miss.
pub fn match(method: std.http.Method, path: []const u8, params_out: *[max_path_params][]const u8) ?struct { route: Route, param_count: usize } {
    for (&routes) |route| {
        if (route.method != method) continue;
        if (matchPattern(route.pattern, path, params_out)) |count| {
            return .{ .route = route, .param_count = count };
        }
    }
    return null;
}

fn matchPattern(pattern: []const u8, path: []const u8, params_out: *[max_path_params][]const u8) ?usize {
    var p_it = std.mem.splitScalar(u8, pattern, '/');
    var t_it = std.mem.splitScalar(u8, path, '/');
    var count: usize = 0;
    while (true) {
        const p_seg = p_it.next();
        const t_seg = t_it.next();
        if (p_seg == null and t_seg == null) return count;
        if (p_seg == null or t_seg == null) return null;
        if (p_seg.?.len >= 2 and p_seg.?[0] == '{' and p_seg.?[p_seg.?.len - 1] == '}') {
            if (count >= max_path_params) return null;
            params_out[count] = t_seg.?;
            count += 1;
        } else if (!std.mem.eql(u8, p_seg.?, t_seg.?)) {
            return null;
        }
    }
}

// ----- Handlers --------------------------------------------------------------

fn serveDashboard(ctx: *RequestCtx) !void {
    try ctx.request.respond(dashboard_html, .{
        .status = .ok,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "text/html; charset=utf-8" },
            .{ .name = "access-control-allow-origin", .value = "*" },
        },
        .keep_alive = true,
    });
}

fn exchangeStatus(ctx: *RequestCtx) !void {
    return proxyGet(ctx, "/exchange/status");
}

fn exchangeSchedule(ctx: *RequestCtx) !void {
    return proxyGet(ctx, "/exchange/schedule");
}

fn exchangeAnnouncements(ctx: *RequestCtx) !void {
    return proxyGet(ctx, "/exchange/announcements");
}

fn marketsList(ctx: *RequestCtx) !void {
    return proxyGetWithQuery(ctx, "/markets", &.{ "status", "series_ticker", "event_ticker", "limit", "cursor" });
}

fn marketsTrades(ctx: *RequestCtx) !void {
    return proxyGetWithQuery(ctx, "/markets/trades", &.{ "ticker", "limit", "cursor" });
}

fn marketsGet(ctx: *RequestCtx) !void {
    const path = try std.fmt.allocPrint(ctx.arena, "/markets/{s}", .{ctx.param(0)});
    return proxyGet(ctx, path);
}

fn marketsOrderbook(ctx: *RequestCtx) !void {
    const path = try std.fmt.allocPrint(ctx.arena, "/markets/{s}/orderbook", .{ctx.param(0)});
    return proxyGet(ctx, path);
}

fn eventsList(ctx: *RequestCtx) !void {
    return proxyGetWithQuery(ctx, "/events", &.{ "status", "series_ticker", "limit", "cursor", "with_nested_markets" });
}

fn eventsGet(ctx: *RequestCtx) !void {
    const path = try std.fmt.allocPrint(ctx.arena, "/events/{s}", .{ctx.param(0)});
    return proxyGetWithQuery(ctx, path, &.{"with_nested_markets"});
}

fn portfolioBalance(ctx: *RequestCtx) !void {
    return proxyGet(ctx, "/portfolio/balance");
}

fn portfolioPositions(ctx: *RequestCtx) !void {
    return proxyGetWithQuery(ctx, "/portfolio/positions", &.{ "ticker", "event_ticker", "settlement_status", "limit", "cursor" });
}

fn portfolioSettlements(ctx: *RequestCtx) !void {
    return proxyGetWithQuery(ctx, "/portfolio/settlements", &.{ "limit", "cursor" });
}

fn portfolioFills(ctx: *RequestCtx) !void {
    return proxyGetWithQuery(ctx, "/portfolio/fills", &.{ "ticker", "limit", "cursor" });
}

fn ordersList(ctx: *RequestCtx) !void {
    return proxyGetWithQuery(ctx, "/portfolio/orders", &.{ "ticker", "event_ticker", "status", "limit", "cursor" });
}

fn ordersCreate(ctx: *RequestCtx) !void {
    // Pass the request body through to Kalshi as-is.
    var body_buf: [16 * 1024]u8 = undefined;
    const body_reader = ctx.request.readerExpectContinue(&body_buf) catch |e|
        return respondError(ctx, @errorName(e), .bad_request);
    var collected: std.array_list.Managed(u8) = .init(ctx.arena);
    while (true) {
        const chunk = body_reader.peek(1) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return respondError(ctx, @errorName(err), .bad_request),
        };
        if (chunk.len == 0) break;
        try collected.appendSlice(chunk);
        body_reader.toss(chunk.len);
    }
    return proxyRequest(ctx, .POST, "/portfolio/orders", collected.items);
}

fn ordersCancel(ctx: *RequestCtx) !void {
    const path = try std.fmt.allocPrint(ctx.arena, "/portfolio/orders/{s}", .{ctx.param(0)});
    return proxyRequest(ctx, .DELETE, path, null);
}

fn searchTags(ctx: *RequestCtx) !void {
    return proxyGet(ctx, "/search/tags_by_categories");
}

fn seriesGet(ctx: *RequestCtx) !void {
    const path = try std.fmt.allocPrint(ctx.arena, "/series/{s}", .{ctx.param(0)});
    return proxyGet(ctx, path);
}

// ----- Proxy helpers ---------------------------------------------------------

fn proxyGet(ctx: *RequestCtx, kalshi_path: []const u8) !void {
    return proxyRequest(ctx, .GET, kalshi_path, null);
}

fn proxyGetWithQuery(ctx: *RequestCtx, kalshi_path: []const u8, allowed: []const []const u8) !void {
    var qp: std.array_list.Managed(kalshi.client.QueryParam) = .init(ctx.arena);
    for (allowed) |key| {
        if (ctx.queryParam(key)) |v| try qp.append(.{ .key = key, .value = v });
    }
    const resp = ctx.client.request(ctx.arena, .{
        .path = kalshi_path,
        .method = .GET,
        .query = qp.items,
    }) catch |e| return respondError(ctx, @errorName(e), .internal_server_error);
    return respondFromKalshi(ctx, resp);
}

fn proxyRequest(ctx: *RequestCtx, method: std.http.Method, kalshi_path: []const u8, body: ?[]const u8) !void {
    const resp = ctx.client.request(ctx.arena, .{
        .path = kalshi_path,
        .method = method,
        .body = body,
    }) catch |e| return respondError(ctx, @errorName(e), .internal_server_error);
    return respondFromKalshi(ctx, resp);
}

fn respondFromKalshi(ctx: *RequestCtx, kalshi_resp: kalshi.client.Response) !void {
    if (!kalshi_resp.isSuccess()) {
        const status_enum: std.http.Status = @enumFromInt(kalshi_resp.status);
        return respondErrorRaw(ctx, kalshi_resp.body, status_enum);
    }
    return respondOk(ctx, kalshi_resp.body);
}

fn respondOk(ctx: *RequestCtx, kalshi_body: []const u8) !void {
    var body: std.array_list.Managed(u8) = .init(ctx.arena);
    try body.appendSlice("{\"success\":true,\"data\":");
    if (kalshi_body.len == 0) {
        try body.appendSlice("null");
    } else {
        try body.appendSlice(kalshi_body);
    }
    try body.appendSlice(",\"timestamp\":\"");
    try appendIso8601Now(&body);
    try body.appendSlice("\"}");
    try ctx.request.respond(body.items, .{
        .status = .ok,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/json" },
            .{ .name = "access-control-allow-origin", .value = "*" },
        },
        .keep_alive = true,
    });
}

fn respondError(ctx: *RequestCtx, msg: []const u8, status: std.http.Status) !void {
    return respondErrorRaw(ctx, msg, status);
}

fn respondErrorRaw(ctx: *RequestCtx, msg: []const u8, status: std.http.Status) !void {
    var body: std.array_list.Managed(u8) = .init(ctx.arena);
    try body.appendSlice("{\"success\":false,\"error\":");
    try writeJsonString(&body, msg);
    try body.appendSlice(",\"timestamp\":\"");
    try appendIso8601Now(&body);
    try body.appendSlice("\"}");
    try ctx.request.respond(body.items, .{
        .status = status,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/json" },
            .{ .name = "access-control-allow-origin", .value = "*" },
        },
        .keep_alive = true,
    });
}

fn writeJsonString(buf: *std.array_list.Managed(u8), s: []const u8) !void {
    try buf.append('"');
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice("\\\""),
            '\\' => try buf.appendSlice("\\\\"),
            '\n' => try buf.appendSlice("\\n"),
            '\r' => try buf.appendSlice("\\r"),
            '\t' => try buf.appendSlice("\\t"),
            0x00...0x08, 0x0b, 0x0c, 0x0e...0x1f => try buf.print("\\u{x:0>4}", .{c}),
            else => try buf.append(c),
        }
    }
    try buf.append('"');
}

fn appendIso8601Now(buf: *std.array_list.Managed(u8)) !void {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.REALTIME, &ts);
    // Convert seconds-since-epoch into Y-M-D H:M:S UTC via Howard Hinnant's
    // civil-from-days algorithm (operates on days, then carves off the seconds-of-day).
    const seconds: i64 = @intCast(ts.sec);
    const sec_of_day_signed: i64 = @mod(seconds, 86400);
    const sec_of_day: u32 = @intCast(sec_of_day_signed);
    // Days since 1970-01-01, then shift epoch to 0000-03-01 (Hinnant's algorithm).
    const z_days: i64 = @divFloor(seconds, 86400) + 719468;
    const era: i64 = @divFloor(z_days, 146097);
    const doe: u32 = @intCast(z_days - era * 146097); // [0, 146096]
    const yoe: u32 = @divTrunc(doe - @divTrunc(doe, 1460) + @divTrunc(doe, 36524) - @divTrunc(doe, 146096), 365);
    const y: i64 = @as(i64, yoe) + era * 400;
    const doy: u32 = doe - (365 * yoe + @divTrunc(yoe, 4) - @divTrunc(yoe, 100));
    const mp: u32 = @divTrunc(5 * doy + 2, 153);
    const d: u32 = doy - @divTrunc(153 * mp + 2, 5) + 1;
    const m: u32 = if (mp < 10) mp + 3 else mp - 9;
    const year_signed: i64 = if (m <= 2) y + 1 else y;
    const year: u32 = @intCast(year_signed);
    const hh: u32 = sec_of_day / 3600;
    const mm: u32 = (sec_of_day % 3600) / 60;
    const ss: u32 = sec_of_day % 60;
    try buf.print("{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{ year, m, d, hh, mm, ss });
}

// ----- Tests -----------------------------------------------------------------

test "matchPattern: literal hit" {
    var params: [max_path_params][]const u8 = undefined;
    const n = matchPattern("/api/kalshi/exchange/status", "/api/kalshi/exchange/status", &params);
    try std.testing.expectEqual(@as(?usize, 0), n);
}

test "matchPattern: literal miss" {
    var params: [max_path_params][]const u8 = undefined;
    const n = matchPattern("/api/kalshi/exchange/status", "/api/kalshi/exchange/schedule", &params);
    try std.testing.expectEqual(@as(?usize, null), n);
}

test "matchPattern: single placeholder" {
    var params: [max_path_params][]const u8 = undefined;
    const n = matchPattern("/api/kalshi/markets/{ticker}", "/api/kalshi/markets/KXBTC-26", &params).?;
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqualStrings("KXBTC-26", params[0]);
}

test "matchPattern: placeholder + literal suffix" {
    var params: [max_path_params][]const u8 = undefined;
    const n = matchPattern("/api/kalshi/markets/{ticker}/orderbook", "/api/kalshi/markets/KXBTC-26/orderbook", &params).?;
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqualStrings("KXBTC-26", params[0]);
}

test "matchPattern: trailing-segment mismatch" {
    var params: [max_path_params][]const u8 = undefined;
    const n = matchPattern("/api/kalshi/markets/{ticker}", "/api/kalshi/markets/KXBTC-26/orderbook", &params);
    try std.testing.expectEqual(@as(?usize, null), n);
}

test "match: routes top-to-bottom, literal /markets/trades wins over /markets/{ticker}" {
    var params: [max_path_params][]const u8 = undefined;
    const hit = match(.GET, "/api/kalshi/markets/trades", &params).?;
    try std.testing.expectEqualStrings("/api/kalshi/markets/trades", hit.route.pattern);
}

test "match: method mismatch returns null" {
    var params: [max_path_params][]const u8 = undefined;
    try std.testing.expectEqual(@as(?@TypeOf(match(.GET, "/", &params).?), null), match(.POST, "/", &params));
}

test "match: every Julia route in the docstring has a Zig handler" {
    const julia_routes = [_]struct { method: std.http.Method, path: []const u8 }{
        .{ .method = .GET, .path = "/" },
        .{ .method = .GET, .path = "/api/kalshi/exchange/status" },
        .{ .method = .GET, .path = "/api/kalshi/exchange/schedule" },
        .{ .method = .GET, .path = "/api/kalshi/exchange/announcements" },
        .{ .method = .GET, .path = "/api/kalshi/markets" },
        .{ .method = .GET, .path = "/api/kalshi/markets/trades" },
        .{ .method = .GET, .path = "/api/kalshi/markets/SOME" },
        .{ .method = .GET, .path = "/api/kalshi/markets/SOME/orderbook" },
        .{ .method = .GET, .path = "/api/kalshi/events" },
        .{ .method = .GET, .path = "/api/kalshi/events/SOME" },
        .{ .method = .GET, .path = "/api/kalshi/portfolio/balance" },
        .{ .method = .GET, .path = "/api/kalshi/portfolio/positions" },
        .{ .method = .GET, .path = "/api/kalshi/portfolio/settlements" },
        .{ .method = .GET, .path = "/api/kalshi/portfolio/fills" },
        .{ .method = .GET, .path = "/api/kalshi/orders" },
        .{ .method = .POST, .path = "/api/kalshi/orders" },
        .{ .method = .DELETE, .path = "/api/kalshi/orders/SOME" },
        .{ .method = .GET, .path = "/api/kalshi/search/tags" },
        .{ .method = .GET, .path = "/api/kalshi/series/SOME" },
    };
    var params: [max_path_params][]const u8 = undefined;
    for (julia_routes) |r| {
        if (match(r.method, r.path, &params) == null) {
            std.debug.print("missing route: {s} {s}\n", .{ @tagName(r.method), r.path });
            return error.MissingRoute;
        }
    }
}

test "appendIso8601Now produces YYYY-MM-DDTHH:MM:SSZ" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var buf: std.array_list.Managed(u8) = .init(arena.allocator());
    try appendIso8601Now(&buf);
    // Expected length: "YYYY-MM-DDTHH:MM:SSZ" = 20 chars.
    try std.testing.expectEqual(@as(usize, 20), buf.items.len);
    try std.testing.expect(buf.items[4] == '-');
    try std.testing.expect(buf.items[7] == '-');
    try std.testing.expect(buf.items[10] == 'T');
    try std.testing.expect(buf.items[13] == ':');
    try std.testing.expect(buf.items[16] == ':');
    try std.testing.expect(buf.items[19] == 'Z');
}

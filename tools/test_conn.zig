//! End-to-end demo API smoke check.
//!
//! Hits every Kalshi endpoint implemented in `src/kalshi/*.zig` against the
//! live demo (or live) API and asserts each returns a 2xx. Loads credentials
//! from `.secret/kalshi_api_key_{id,private}.txt` when needed; public
//! endpoints work without them.
//!
//! Exit codes:
//!   0  every endpoint OK
//!   1  one or more endpoints failed
//!   2  argument / config error
//!
//! Usage:
//!   praescientia-test-conn [--env=demo|live] [--verbose] [--capture-dir=PATH]
//!
//! `--capture-dir` writes each successful response body to
//! `<PATH>/<endpoint>.zig.json`, for use by scripts/parity_check.sh.

const std = @import("std");
const praescientia = @import("praescientia");
const kalshi = praescientia.kalshi;

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    const arena_alloc = init.arena.allocator();

    var stderr_buf: [4096]u8 = undefined;
    var stderr_w = std.Io.File.stderr().writer(io, &stderr_buf);
    const stderr = &stderr_w.interface;
    defer stderr.flush() catch {};

    var stdout_buf: [4096]u8 = undefined;
    var stdout_w = std.Io.File.stdout().writer(io, &stdout_buf);
    const stdout = &stdout_w.interface;
    defer stdout.flush() catch {};

    const argv = try init.minimal.args.toSlice(arena_alloc);

    var env: kalshi.client.Env = .demo;
    var verbose = false;
    var capture_dir: ?[]const u8 = null;
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "--env=demo")) {
            env = .demo;
        } else if (std.mem.eql(u8, a, "--env=live")) {
            env = .live;
        } else if (std.mem.eql(u8, a, "--verbose") or std.mem.eql(u8, a, "-v")) {
            verbose = true;
        } else if (std.mem.startsWith(u8, a, "--capture-dir=")) {
            capture_dir = a["--capture-dir=".len..];
        } else if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            try stderr.print(
                \\test-conn — smoke-check Kalshi demo/live endpoints
                \\
                \\Options:
                \\  --env=demo (default) | --env=live
                \\  --verbose / -v
                \\
                \\
            , .{});
            return 0;
        } else {
            try stderr.print("unknown argument: {s}\n", .{a});
            return 2;
        }
    }

    // Credentials are optional for the public endpoints we cover today;
    // missing files are a warning, not a fatal.
    const key_id = readFileTrimmed(io, gpa, ".secret/kalshi_api_key_id.txt") catch null;
    defer if (key_id) |k| gpa.free(k);
    const pem = readFileTrimmed(io, gpa, ".secret/kalshi_api_key_private.txt") catch null;
    defer if (pem) |p| gpa.free(p);

    if (verbose) {
        try stderr.print("env:         {s}\n", .{@tagName(env)});
        try stderr.print("credentials: {s}\n", .{if (key_id != null and pem != null) "yes" else "no (public-only)"});
    }

    var client = kalshi.client.Client.init(gpa, io, .{
        .env = env,
        .key_id = key_id,
        .private_key_pem = pem,
    });
    defer client.deinit();

    var failed: u32 = 0;
    var passed: u32 = 0;

    const checks = [_]struct { name: []const u8, fn_ptr: CheckFn }{
        .{ .name = "exchange.status", .fn_ptr = checkExchangeStatus },
        .{ .name = "exchange.schedule", .fn_ptr = checkExchangeSchedule },
        .{ .name = "exchange.announcements", .fn_ptr = checkExchangeAnnouncements },
        .{ .name = "markets.list", .fn_ptr = checkMarketsList },
        .{ .name = "markets.get", .fn_ptr = checkMarketsGet },
        .{ .name = "markets.orderbook", .fn_ptr = checkMarketsOrderbook },
        .{ .name = "events.list", .fn_ptr = checkEventsList },
        .{ .name = "events.get", .fn_ptr = checkEventsGet },
        .{ .name = "portfolio.balance", .fn_ptr = checkPortfolioBalance },
        .{ .name = "portfolio.positions", .fn_ptr = checkPortfolioPositions },
        .{ .name = "portfolio.settlements", .fn_ptr = checkPortfolioSettlements },
        .{ .name = "portfolio.fills", .fn_ptr = checkPortfolioFills },
        .{ .name = "orders.list", .fn_ptr = checkOrdersList },
        .{ .name = "historical.cutoff", .fn_ptr = checkHistoricalCutoff },
        .{ .name = "historical.marketTrades", .fn_ptr = checkHistoricalMarketTrades },
        .{ .name = "account.limits", .fn_ptr = checkAccountLimits },
        .{ .name = "account.listApiKeys", .fn_ptr = checkAccountApiKeys },
        .{ .name = "communications.listRfqs", .fn_ptr = checkCommunicationsRfqs },
        .{ .name = "order_groups.list", .fn_ptr = checkOrderGroupsList },
        .{ .name = "live_data.listMilestones", .fn_ptr = checkLiveDataMilestones },
    };

    for (checks) |c| {
        const f = try runCheck(stdout, gpa, &client, c.name, c.fn_ptr, capture_dir, io);
        if (f == 0) passed += 1 else failed += 1;
    }

    try stdout.print("\n{d} passed, {d} failed\n", .{ passed, failed });
    return if (failed == 0) 0 else 1;
}

const CheckFn = *const fn (arena: std.mem.Allocator, client: *kalshi.client.Client) anyerror!void;
const CaptureFn = *const fn (arena: std.mem.Allocator, client: *kalshi.client.Client) anyerror![]const u8;

fn runCheck(
    out: *std.Io.Writer,
    gpa: std.mem.Allocator,
    client: *kalshi.client.Client,
    name: []const u8,
    check: CheckFn,
    capture_dir: ?[]const u8,
    io: std.Io,
) !u32 {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    if (check(a, client)) |_| {
        try out.print("  OK   {s}\n", .{name});
        if (capture_dir) |dir| try captureRaw(io, a, client, name, dir);
        return 0;
    } else |err| {
        try out.print("  FAIL {s}  ({s})\n", .{ name, @errorName(err) });
        return 1;
    }
}

/// Re-issues the endpoint as a raw HTTP request and writes the response body
/// to `<dir>/<name>.zig.json`. Used by scripts/parity_check.sh. The caller
/// must have already created `<dir>` (parity_check.sh does `mkdir -p`).
fn captureRaw(io: std.Io, arena: std.mem.Allocator, client: *kalshi.client.Client, name: []const u8, dir: []const u8) !void {
    const path = endpointPath(name) orelse return;
    const resp = try client.request(arena, .{ .path = path });
    if (!resp.isSuccess()) return;

    const full_path = try std.fmt.allocPrint(arena, "{s}/{s}.zig.json", .{ dir, name });
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = full_path,
        .data = resp.body,
        .flags = .{ .truncate = true },
    });
}

/// Maps endpoint names back to URL paths for capture mode. Endpoints needing
/// runtime ticker discovery (markets.get, markets.orderbook, events.get) are
/// omitted; capture for those is comparison-unfriendly anyway.
fn endpointPath(name: []const u8) ?[]const u8 {
    const pairs = [_]struct { []const u8, []const u8 }{
        .{ "exchange.status", "/exchange/status" },
        .{ "exchange.schedule", "/exchange/schedule" },
        .{ "exchange.announcements", "/exchange/announcements" },
        .{ "markets.list", "/markets?limit=2" },
        .{ "events.list", "/events?limit=2" },
        .{ "portfolio.balance", "/portfolio/balance" },
        .{ "portfolio.positions", "/portfolio/positions?limit=2" },
        .{ "portfolio.settlements", "/portfolio/settlements?limit=2" },
        .{ "portfolio.fills", "/portfolio/fills?limit=2" },
        .{ "orders.list", "/portfolio/orders?limit=2" },
        .{ "historical.cutoff", "/historical/cutoff" },
        .{ "historical.marketTrades", "/markets/trades?limit=2" },
        .{ "account.limits", "/account/limits" },
        .{ "account.listApiKeys", "/api_keys" },
        .{ "communications.listRfqs", "/communications/rfqs?limit=2" },
        .{ "order_groups.list", "/portfolio/order_groups" },
        .{ "live_data.listMilestones", "/milestones?limit=2" },
    };
    for (pairs) |p| if (std.mem.eql(u8, p[0], name)) return p[1];
    return null;
}

fn checkExchangeStatus(arena: std.mem.Allocator, client: *kalshi.client.Client) anyerror!void {
    const s = try kalshi.exchange.status(client, arena);
    // exchange_active flips at maintenance; the only invariant is that we
    // got *some* boolean back, which the type system already gives us.
    _ = s;
}

fn checkExchangeSchedule(arena: std.mem.Allocator, client: *kalshi.client.Client) anyerror!void {
    const v = try kalshi.exchange.schedule(client, arena);
    _ = v.object.get("schedule") orelse return error.MissingSchedule;
}

fn checkExchangeAnnouncements(arena: std.mem.Allocator, client: *kalshi.client.Client) anyerror!void {
    const v = try kalshi.exchange.announcements(client, arena);
    _ = v.object.get("announcements") orelse return error.MissingAnnouncements;
}

fn checkMarketsList(arena: std.mem.Allocator, client: *kalshi.client.Client) anyerror!void {
    const r = try kalshi.markets.list(client, arena, .{ .limit = 1 });
    if (r.markets.len == 0) return error.EmptyMarkets;
}

fn checkMarketsGet(arena: std.mem.Allocator, client: *kalshi.client.Client) anyerror!void {
    const r = try kalshi.markets.list(client, arena, .{ .limit = 1 });
    if (r.markets.len == 0) return error.EmptyMarkets;
    const m = try kalshi.markets.get(client, arena, r.markets[0].ticker);
    if (m.ticker.len == 0) return error.EmptyTicker;
}

fn checkMarketsOrderbook(arena: std.mem.Allocator, client: *kalshi.client.Client) anyerror!void {
    const r = try kalshi.markets.list(client, arena, .{ .limit = 1 });
    if (r.markets.len == 0) return error.EmptyMarkets;
    const v = try kalshi.markets.orderbook(client, arena, r.markets[0].ticker);
    _ = v.object.get("orderbook_fp") orelse return error.MissingOrderbookFp;
}

fn checkEventsList(arena: std.mem.Allocator, client: *kalshi.client.Client) anyerror!void {
    const r = try kalshi.events.list(client, arena, .{ .limit = 1 });
    if (r.events.len == 0) return error.EmptyEvents;
}

fn checkEventsGet(arena: std.mem.Allocator, client: *kalshi.client.Client) anyerror!void {
    const r = try kalshi.events.list(client, arena, .{ .limit = 1 });
    if (r.events.len == 0) return error.EmptyEvents;
    const d = try kalshi.events.get(client, arena, r.events[0].event_ticker);
    if (d.event.event_ticker.len == 0) return error.EmptyTicker;
}

fn checkPortfolioBalance(arena: std.mem.Allocator, client: *kalshi.client.Client) anyerror!void {
    if (!client.hasCredentials()) return error.SkippedNoCredentials;
    _ = try kalshi.portfolio.balance(client, arena);
}

fn checkPortfolioPositions(arena: std.mem.Allocator, client: *kalshi.client.Client) anyerror!void {
    if (!client.hasCredentials()) return error.SkippedNoCredentials;
    _ = try kalshi.portfolio.positions(client, arena, .{ .limit = 1 });
}

fn checkPortfolioSettlements(arena: std.mem.Allocator, client: *kalshi.client.Client) anyerror!void {
    if (!client.hasCredentials()) return error.SkippedNoCredentials;
    _ = try kalshi.portfolio.settlements(client, arena, .{ .limit = 1 });
}

fn checkPortfolioFills(arena: std.mem.Allocator, client: *kalshi.client.Client) anyerror!void {
    if (!client.hasCredentials()) return error.SkippedNoCredentials;
    _ = try kalshi.portfolio.fills(client, arena, .{ .limit = 1 });
}

fn checkOrdersList(arena: std.mem.Allocator, client: *kalshi.client.Client) anyerror!void {
    if (!client.hasCredentials()) return error.SkippedNoCredentials;
    _ = try kalshi.orders.list(client, arena, .{ .limit = 1 });
}

fn checkHistoricalCutoff(arena: std.mem.Allocator, client: *kalshi.client.Client) anyerror!void {
    if (!client.hasCredentials()) return error.SkippedNoCredentials;
    _ = try kalshi.historical.cutoff(client, arena);
}

fn checkHistoricalMarketTrades(arena: std.mem.Allocator, client: *kalshi.client.Client) anyerror!void {
    _ = try kalshi.historical.marketTrades(client, arena, .{ .limit = 1 });
}

fn checkAccountLimits(arena: std.mem.Allocator, client: *kalshi.client.Client) anyerror!void {
    if (!client.hasCredentials()) return error.SkippedNoCredentials;
    _ = try kalshi.account.limits(client, arena);
}

fn checkAccountApiKeys(arena: std.mem.Allocator, client: *kalshi.client.Client) anyerror!void {
    if (!client.hasCredentials()) return error.SkippedNoCredentials;
    _ = try kalshi.account.listApiKeys(client, arena);
}

fn checkCommunicationsRfqs(arena: std.mem.Allocator, client: *kalshi.client.Client) anyerror!void {
    if (!client.hasCredentials()) return error.SkippedNoCredentials;
    _ = try kalshi.communications.listRfqs(client, arena, .{ .limit = 1 });
}

fn checkOrderGroupsList(arena: std.mem.Allocator, client: *kalshi.client.Client) anyerror!void {
    if (!client.hasCredentials()) return error.SkippedNoCredentials;
    _ = try kalshi.order_groups.list(client, arena);
}

fn checkLiveDataMilestones(arena: std.mem.Allocator, client: *kalshi.client.Client) anyerror!void {
    _ = try kalshi.live_data.listMilestones(client, arena, .{ .limit = 1 });
}

fn readFileTrimmed(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    var read_buf: [4096]u8 = undefined;
    var reader = file.reader(io, &read_buf);
    var list: std.array_list.Managed(u8) = .init(allocator);
    errdefer list.deinit();
    while (true) {
        const chunk = reader.interface.peek(1) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (chunk.len == 0) break;
        try list.appendSlice(chunk);
        reader.interface.toss(chunk.len);
    }
    const raw = try list.toOwnedSlice();
    const trimmed = std.mem.trim(u8, raw, " \r\n\t");
    // Preserve only the trimmed portion; shrink via dupe + free.
    const out = try allocator.dupe(u8, trimmed);
    allocator.free(raw);
    return out;
}

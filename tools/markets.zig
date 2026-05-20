//! praescientia-markets — port of scripts/kalshi_markets.jl.
//!
//! Subcommands:
//!   list                                      GET /markets
//!   get TICKER                                GET /markets/{ticker}
//!   trades                                    GET /markets/trades
//!   candlesticks SERIES_TICKER MARKET_TICKER  GET /series/{s}/markets/{m}/candlesticks
//!   orderbook TICKER                          GET /markets/{ticker}/orderbook
//!   orderbooks T1,T2,...                      POST /markets/orderbooks
//!   candidates                                Layer-1 screener output for the
//!                                             market-screener agent

const std = @import("std");
const common = @import("common");
const praescientia = @import("praescientia");

pub fn main(init: std.process.Init) !u8 {
    return common.runMain(init, "praescientia-markets", &.{
        .{ .name = "list", .description = "List markets", .run = cmdList },
        .{ .name = "get", .description = "Get a market by ticker", .run = cmdGet },
        .{ .name = "trades", .description = "Paginated trades across markets", .run = cmdTrades },
        .{ .name = "candlesticks", .description = "Live market candlesticks", .run = cmdCandlesticks },
        .{ .name = "orderbook", .description = "Order book for a single market", .run = cmdOrderbook },
        .{ .name = "orderbooks", .description = "Order books for multiple markets", .run = cmdOrderbooks },
        .{ .name = "candidates", .description = "Emit layer-1-gated screener candidates", .run = cmdCandidates },
    });
}

fn parseU32(s: ?[]const u8) ?u32 {
    if (s) |v| return std.fmt.parseInt(u32, v, 10) catch null;
    return null;
}

fn parseI64(s: ?[]const u8) ?i64 {
    if (s) |v| return std.fmt.parseInt(i64, v, 10) catch null;
    return null;
}

fn cmdList(ctx: *common.Context) !u8 {
    const opts: common.kalshi.markets.ListOptions = .{
        .limit = parseU32(ctx.flagValue("--limit")),
        .series_ticker = ctx.flagValue("--series_ticker"),
        .event_ticker = ctx.flagValue("--event_ticker"),
        .status = ctx.flagValue("--status"),
    };
    const v = try common.kalshi.markets.list(ctx.client, ctx.arena, opts);
    try common.printJson(v, ctx.stdout);
    return 0;
}

fn cmdGet(ctx: *common.Context) !u8 {
    const ticker = ctx.positional(0) orelse {
        try ctx.stderr.print("usage: get TICKER\n", .{});
        return 2;
    };
    const v = try common.kalshi.markets.get(ctx.client, ctx.arena, ticker);
    try common.printJson(v, ctx.stdout);
    return 0;
}

fn cmdTrades(ctx: *common.Context) !u8 {
    const opts: common.kalshi.markets.TradesOptions = .{
        .limit = parseU32(ctx.flagValue("--limit")),
        .ticker = ctx.flagValue("--ticker"),
        .min_ts = parseI64(ctx.flagValue("--min_ts")),
        .max_ts = parseI64(ctx.flagValue("--max_ts")),
    };
    const v = try common.kalshi.markets.trades(ctx.client, ctx.arena, opts);
    try common.printJson(v, ctx.stdout);
    return 0;
}

fn cmdCandlesticks(ctx: *common.Context) !u8 {
    const series_ticker = ctx.positional(0) orelse {
        try ctx.stderr.print("usage: candlesticks SERIES_TICKER MARKET_TICKER\n", .{});
        return 2;
    };
    const market_ticker = ctx.positional(1) orelse {
        try ctx.stderr.print("usage: candlesticks SERIES_TICKER MARKET_TICKER\n", .{});
        return 2;
    };
    const opts: common.kalshi.markets.CandlesticksOptions = .{
        .period_interval = parseU32(ctx.flagValue("--period_interval")),
        .start_ts = parseI64(ctx.flagValue("--start_ts")),
        .end_ts = parseI64(ctx.flagValue("--end_ts")),
    };
    const v = try common.kalshi.markets.candlesticks(ctx.client, ctx.arena, series_ticker, market_ticker, opts);
    try common.printJson(v, ctx.stdout);
    return 0;
}

fn cmdOrderbook(ctx: *common.Context) !u8 {
    const ticker = ctx.positional(0) orelse {
        try ctx.stderr.print("usage: orderbook TICKER\n", .{});
        return 2;
    };
    const v = try common.kalshi.markets.orderbook(ctx.client, ctx.arena, ticker);
    try common.printJson(v, ctx.stdout);
    return 0;
}

fn cmdOrderbooks(ctx: *common.Context) !u8 {
    const csv = ctx.positional(0) orelse {
        try ctx.stderr.print("usage: orderbooks TICKER1,TICKER2,...\n", .{});
        return 2;
    };
    var list: std.array_list.Managed([]const u8) = .init(ctx.arena);
    var it = std.mem.splitScalar(u8, csv, ',');
    while (it.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " ");
        if (trimmed.len > 0) try list.append(trimmed);
    }
    const v = try common.kalshi.markets.orderbooks(ctx.client, ctx.arena, list.items);
    try common.printJson(v, ctx.stdout);
    return 0;
}

// ---------------------------------------------------------------------------
// candidates — layer-1 screener input
// ---------------------------------------------------------------------------

/// Default per-gate thresholds. Each can be overridden by --flag.
const CandidateDefaults = struct {
    pub const min_volume_fp: f64 = 5.0;
    pub const max_spread_cents: u32 = 10;
    pub const max_candidates: usize = 50;
    pub const list_limit: u32 = 1000;
};

/// One candidate emitted to stdout. Field shape kept stable so the
/// screener-agent prompt can reference fields by name.
const Candidate = struct {
    ticker: []const u8,
    event_ticker: []const u8,
    status: []const u8,
    title: []const u8,
    yes_bid_cents: i32,
    yes_ask_cents: i32,
    no_bid_cents: i32,
    no_ask_cents: i32,
    last_price_cents: i32,
    volume: f64,
    open_interest: f64,
    close_time: []const u8,
};

const GateSummary = struct {
    total_fetched: usize = 0,
    gate_active: usize = 0,
    gate_future_close: usize = 0,
    gate_bid_positive: usize = 0,
    gate_ask_sub_100: usize = 0,
    gate_volume_min: usize = 0,
    gate_spread_max: usize = 0,
    gate_parse: usize = 0,
    gate_dedup: usize = 0,
    passed: usize = 0,
};

const CandidatesOutput = struct {
    scan_id: []const u8,
    scan_ts_ms: i64,
    kb_root: []const u8,
    thresholds: struct {
        min_volume_fp: f64,
        max_spread_cents: u32,
        max_candidates: usize,
    },
    gate_summary: GateSummary,
    candidates: []const Candidate,
};

/// Parse "0.6500" → 65. Returns null when the string is empty or doesn't
/// parse — gate predicates treat that as "no quote".
pub fn dollarStringToWholeCents(s: []const u8) ?i32 {
    if (s.len == 0) return null;
    const cents = praescientia.kb.settlements.dollarStringToCents(s) catch return null;
    if (cents < std.math.minInt(i32) or cents > std.math.maxInt(i32)) return null;
    return @intCast(cents);
}

/// Parse "173558.87" → 173558.87. Returns null when unparseable.
pub fn volumeStringToFloat(s: []const u8) ?f64 {
    if (s.len == 0) return null;
    return std.fmt.parseFloat(f64, s) catch null;
}

/// Pure gate. Returns whether the market passes every layer-1 gate
/// **except** dedup (which needs kb_root state and is checked separately).
pub const GateInputs = struct {
    status: []const u8,
    close_time_iso: []const u8,
    yes_bid_dollars: []const u8,
    yes_ask_dollars: []const u8,
    volume_fp: []const u8,
    now_ms: i64,
    min_volume_fp: f64,
    max_spread_cents: u32,
};

pub const GateOutcome = enum {
    pass,
    rejected_status,
    rejected_close_past,
    rejected_bid_zero,
    rejected_ask_full,
    rejected_volume_min,
    rejected_spread_max,
    rejected_parse,
};

pub fn evaluateGate(input: GateInputs) GateOutcome {
    if (!std.mem.eql(u8, input.status, "active")) return .rejected_status;
    const close_ms = praescientia.kb.settlements.parseIso8601Ms(input.close_time_iso) catch return .rejected_parse;
    if (close_ms <= input.now_ms) return .rejected_close_past;
    const bid = dollarStringToWholeCents(input.yes_bid_dollars) orelse return .rejected_parse;
    if (bid <= 0) return .rejected_bid_zero;
    const ask = dollarStringToWholeCents(input.yes_ask_dollars) orelse return .rejected_parse;
    if (ask >= 100) return .rejected_ask_full;
    if (ask < bid) return .rejected_parse;
    const spread: u32 = @intCast(ask - bid);
    if (spread > input.max_spread_cents) return .rejected_spread_max;
    const vol = volumeStringToFloat(input.volume_fp) orelse return .rejected_parse;
    if (vol < input.min_volume_fp) return .rejected_volume_min;
    return .pass;
}

/// Walk `kb_root/theses/*/manifest.json` and accumulate every ticker in
/// every `market_set`. Returned slice is arena-owned.
fn loadExistingMarketSet(
    arena: std.mem.Allocator,
    io: std.Io,
    kb_root: std.Io.Dir,
) ![]const []const u8 {
    var out: std.array_list.Managed([]const u8) = .init(arena);
    var theses_dir = kb_root.openDir(io, "theses", .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return out.items, // no theses yet — empty dedup set
        else => return err,
    };
    defer theses_dir.close(io);
    var it = theses_dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        var thesis_dir = theses_dir.openDir(io, entry.name, .{}) catch continue;
        defer thesis_dir.close(io);
        const manifest_bytes = thesis_dir.readFileAlloc(io, "manifest.json", arena, .unlimited) catch continue;
        var parsed = std.json.parseFromSlice(std.json.Value, arena, manifest_bytes, .{}) catch continue;
        defer parsed.deinit();
        const root = parsed.value.object;
        const market_set_v = root.get("market_set") orelse continue;
        if (market_set_v != .array) continue;
        for (market_set_v.array.items) |t| {
            if (t != .string) continue;
            try out.append(try arena.dupe(u8, t.string));
        }
    }
    return out.items;
}

fn containsTicker(needles: []const []const u8, ticker: []const u8) bool {
    for (needles) |n| {
        if (std.mem.eql(u8, n, ticker)) return true;
    }
    return false;
}

/// Generate a 26-char ULID-shaped scan_id (timestamp + random) for the
/// candidates output. Re-uses the existing tick ULID generator so the audit
/// surface is consistent across artifact types.
fn generateScanId(arena: std.mem.Allocator) ![]u8 {
    const tick = praescientia.kb.ticks.Tick.init();
    return arena.dupe(u8, tick.id[0..]);
}

fn cmdCandidates(ctx: *common.Context) !u8 {
    const kb_root_path = ctx.flagValue("--kb-root") orelse "./kb";
    const min_volume_fp: f64 = if (ctx.flagValue("--min-volume")) |v|
        (std.fmt.parseFloat(f64, v) catch CandidateDefaults.min_volume_fp)
    else
        CandidateDefaults.min_volume_fp;
    const max_spread_cents: u32 = parseU32(ctx.flagValue("--max-spread-cents")) orelse CandidateDefaults.max_spread_cents;
    const max_candidates_flag: usize = blk: {
        if (ctx.flagValue("--max-candidates")) |v| {
            if (std.fmt.parseInt(usize, v, 10)) |n| break :blk n else |_| {}
        }
        break :blk CandidateDefaults.max_candidates;
    };
    const list_limit: u32 = parseU32(ctx.flagValue("--limit")) orelse CandidateDefaults.list_limit;
    const max_pages: u32 = parseU32(ctx.flagValue("--max-pages")) orelse 10;

    var kb_root = std.Io.Dir.cwd().openDir(ctx.io, kb_root_path, .{ .iterate = true }) catch |err| {
        try ctx.stderr.print("open kb-root {s}: {t}\n", .{ kb_root_path, err });
        return 1;
    };
    defer kb_root.close(ctx.io);

    const existing = loadExistingMarketSet(ctx.arena, ctx.io, kb_root) catch |err| {
        try ctx.stderr.print("load existing theses: {t}\n", .{err});
        return 1;
    };

    const now_ms: i64 = @intCast(@divFloor(std.Io.Clock.real.now(ctx.io).nanoseconds, 1_000_000));

    var passed: std.array_list.Managed(Candidate) = .init(ctx.arena);
    var summary: GateSummary = .{};

    var cursor: ?[]const u8 = null;
    var pages_walked: u32 = 0;
    while (pages_walked < max_pages and passed.items.len < max_candidates_flag) : (pages_walked += 1) {
        const opts: common.kalshi.markets.ListOptions = .{ .limit = list_limit, .cursor = cursor, .status = "open" };
        const page = try common.kalshi.markets.list(ctx.client, ctx.arena, opts);
        summary.total_fetched += page.markets.len;

        for (page.markets) |m| {
            const outcome = evaluateGate(.{
                .status = m.status,
                .close_time_iso = m.close_time,
                .yes_bid_dollars = m.yes_bid_dollars,
                .yes_ask_dollars = m.yes_ask_dollars,
                .volume_fp = m.volume_fp,
                .now_ms = now_ms,
                .min_volume_fp = min_volume_fp,
                .max_spread_cents = max_spread_cents,
            });
            switch (outcome) {
                .rejected_status => summary.gate_active += 1,
                .rejected_close_past => summary.gate_future_close += 1,
                .rejected_bid_zero => summary.gate_bid_positive += 1,
                .rejected_ask_full => summary.gate_ask_sub_100 += 1,
                .rejected_volume_min => summary.gate_volume_min += 1,
                .rejected_spread_max => summary.gate_spread_max += 1,
                .rejected_parse => summary.gate_parse += 1,
                .pass => {
                    if (containsTicker(existing, m.ticker)) {
                        summary.gate_dedup += 1;
                        continue;
                    }
                    if (passed.items.len >= max_candidates_flag) continue;
                    try passed.append(.{
                        .ticker = m.ticker,
                        .event_ticker = m.event_ticker,
                        .status = m.status,
                        .title = m.title,
                        .yes_bid_cents = dollarStringToWholeCents(m.yes_bid_dollars) orelse 0,
                        .yes_ask_cents = dollarStringToWholeCents(m.yes_ask_dollars) orelse 100,
                        .no_bid_cents = dollarStringToWholeCents(m.no_bid_dollars) orelse 0,
                        .no_ask_cents = dollarStringToWholeCents(m.no_ask_dollars) orelse 100,
                        .last_price_cents = dollarStringToWholeCents(m.last_price_dollars) orelse 0,
                        .volume = volumeStringToFloat(m.volume_fp) orelse 0,
                        .open_interest = volumeStringToFloat(m.open_interest_fp) orelse 0,
                        .close_time = m.close_time,
                    });
                    summary.passed += 1;
                },
            }
        }
        const next = page.cursor orelse break;
        if (next.len == 0) break;
        cursor = next;
    }

    const scan_id = try generateScanId(ctx.arena);
    const out: CandidatesOutput = .{
        .scan_id = scan_id,
        .scan_ts_ms = now_ms,
        .kb_root = kb_root_path,
        .thresholds = .{
            .min_volume_fp = min_volume_fp,
            .max_spread_cents = max_spread_cents,
            .max_candidates = max_candidates_flag,
        },
        .gate_summary = summary,
        .candidates = passed.items,
    };
    try common.printJson(out, ctx.stdout);
    return 0;
}

// ---------------------------------------------------------------------------
// Tests — pure-helper coverage. The CLI side is exercised by the smoke script
// (scripts/screener_smoke.sh) since it needs a live Kalshi client.
// ---------------------------------------------------------------------------

test "dollarStringToWholeCents — typical values" {
    try std.testing.expectEqual(@as(?i32, 65), dollarStringToWholeCents("0.6500"));
    try std.testing.expectEqual(@as(?i32, 0), dollarStringToWholeCents("0.0000"));
    try std.testing.expectEqual(@as(?i32, 100), dollarStringToWholeCents("1.0000"));
    try std.testing.expectEqual(@as(?i32, 11), dollarStringToWholeCents("0.1100"));
    try std.testing.expectEqual(@as(?i32, null), dollarStringToWholeCents(""));
    try std.testing.expectEqual(@as(?i32, null), dollarStringToWholeCents("not-a-number"));
}

test "volumeStringToFloat — typical values" {
    try std.testing.expectApproxEqAbs(@as(f64, 173558.87), volumeStringToFloat("173558.87").?, 0.01);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), volumeStringToFloat("0.00").?, 0.001);
    try std.testing.expectEqual(@as(?f64, null), volumeStringToFloat(""));
}

test "evaluateGate — passing case" {
    const out = evaluateGate(.{
        .status = "active",
        .close_time_iso = "2099-12-31T00:00:00Z",
        .yes_bid_dollars = "0.6400",
        .yes_ask_dollars = "0.6500",
        .volume_fp = "100.00",
        .now_ms = 1779252726000,
        .min_volume_fp = 5.0,
        .max_spread_cents = 10,
    });
    try std.testing.expectEqual(GateOutcome.pass, out);
}

test "evaluateGate — rejects non-active status" {
    const out = evaluateGate(.{
        .status = "finalized",
        .close_time_iso = "2099-12-31T00:00:00Z",
        .yes_bid_dollars = "0.6400",
        .yes_ask_dollars = "0.6500",
        .volume_fp = "100.00",
        .now_ms = 1779252726000,
        .min_volume_fp = 5.0,
        .max_spread_cents = 10,
    });
    try std.testing.expectEqual(GateOutcome.rejected_status, out);
}

test "evaluateGate — rejects past close_time" {
    const out = evaluateGate(.{
        .status = "active",
        .close_time_iso = "2020-01-01T00:00:00Z",
        .yes_bid_dollars = "0.6400",
        .yes_ask_dollars = "0.6500",
        .volume_fp = "100.00",
        .now_ms = 1779252726000,
        .min_volume_fp = 5.0,
        .max_spread_cents = 10,
    });
    try std.testing.expectEqual(GateOutcome.rejected_close_past, out);
}

test "evaluateGate — rejects zero bid" {
    const out = evaluateGate(.{
        .status = "active",
        .close_time_iso = "2099-12-31T00:00:00Z",
        .yes_bid_dollars = "0.0000",
        .yes_ask_dollars = "0.5000",
        .volume_fp = "100.00",
        .now_ms = 1779252726000,
        .min_volume_fp = 5.0,
        .max_spread_cents = 50,
    });
    try std.testing.expectEqual(GateOutcome.rejected_bid_zero, out);
}

test "evaluateGate — rejects full ask (100c)" {
    const out = evaluateGate(.{
        .status = "active",
        .close_time_iso = "2099-12-31T00:00:00Z",
        .yes_bid_dollars = "0.5000",
        .yes_ask_dollars = "1.0000",
        .volume_fp = "100.00",
        .now_ms = 1779252726000,
        .min_volume_fp = 5.0,
        .max_spread_cents = 50,
    });
    try std.testing.expectEqual(GateOutcome.rejected_ask_full, out);
}

test "evaluateGate — rejects insufficient volume" {
    const out = evaluateGate(.{
        .status = "active",
        .close_time_iso = "2099-12-31T00:00:00Z",
        .yes_bid_dollars = "0.5000",
        .yes_ask_dollars = "0.5500",
        .volume_fp = "3.00",
        .now_ms = 1779252726000,
        .min_volume_fp = 5.0,
        .max_spread_cents = 10,
    });
    try std.testing.expectEqual(GateOutcome.rejected_volume_min, out);
}

test "evaluateGate — rejects wide spread" {
    const out = evaluateGate(.{
        .status = "active",
        .close_time_iso = "2099-12-31T00:00:00Z",
        .yes_bid_dollars = "0.3000",
        .yes_ask_dollars = "0.5500",
        .volume_fp = "100.00",
        .now_ms = 1779252726000,
        .min_volume_fp = 5.0,
        .max_spread_cents = 10,
    });
    try std.testing.expectEqual(GateOutcome.rejected_spread_max, out);
}

test "containsTicker — match and no-match" {
    const set = [_][]const u8{ "KX-A", "KX-B", "KX-C" };
    try std.testing.expect(containsTicker(&set, "KX-A"));
    try std.testing.expect(containsTicker(&set, "KX-C"));
    try std.testing.expect(!containsTicker(&set, "KX-D"));
    try std.testing.expect(!containsTicker(&[_][]const u8{}, "KX-A"));
}

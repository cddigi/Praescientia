//! praescientia-poll-markets — iterate every market under `--kb-root` and
//! refresh its reality chain from the Kalshi API; then recompute every thesis
//! aggregate. One-shot per invocation; the outer scheduling loop (cron, tmux,
//! `while sleep`) is the operator's problem.
//!
//! Subcommands:
//!   run                                                   Poll once. (default)

const std = @import("std");
const common = @import("common");
const praescientia = @import("praescientia");

const ingest = praescientia.kb.ingest;
const rollup = praescientia.kb.rollup;
const markets_mod = praescientia.kalshi.markets;
const init_mod = praescientia.kb.init;
const metrics = praescientia.kb.metrics;

pub fn main(init: std.process.Init) !u8 {
    return common.runMain(init, "praescientia-poll-markets", &.{
        .{ .name = "run", .description = "Poll every market under --kb-root and recompute theses", .run = cmdRun },
    });
}

fn cmdRun(ctx: *common.Context) !u8 {
    const kb_root_path = ctx.flagValue("--kb-root") orelse "./kb";
    var kb_root = std.Io.Dir.cwd().openDir(ctx.io, kb_root_path, .{ .iterate = true }) catch |err| {
        try ctx.stderr.print("open {s}: {t}\n", .{ kb_root_path, err });
        return 1;
    };
    defer kb_root.close(ctx.io);

    const summary = pollAll(ctx, kb_root) catch |err| {
        try ctx.stderr.print("poll failed: {t}\n", .{err});
        return 1;
    };

    try ctx.stdout.print(
        "polled {d} markets, recomputed {d} theses, {d} errors\n",
        .{ summary.markets, summary.theses, summary.errors },
    );
    // Exit 0 if anything succeeded; 1 if every iteration failed (cron-friendly).
    if (summary.markets == 0 and summary.theses == 0 and summary.errors > 0) return 1;
    return 0;
}

pub const PollSummary = struct {
    markets: usize,
    theses: usize,
    errors: usize,
};

/// Production poll. Walks `kb_root/markets/`, fetches market snapshots in a
/// single batch via the `/markets?tickers=CSV` endpoint (much faster than
/// N sequential `/markets/{ticker}` calls — for N=30 we go from ~18min to
/// a single HTTP request), writes through `kbHookMarket`, then walks
/// `kb_root/theses/` and runs `recomputeThesisReality` on each.
///
/// Per the design: each iteration is failure-isolated — a bad market or bad
/// thesis logs to stderr and the loop continues. Returns counts so the
/// caller can decide on an exit code.
///
/// Falls back to per-ticker sequential fetches if the batch call fails
/// (preserves the failure-isolation guarantee).
pub fn pollAll(ctx: *common.Context, kb_root: std.Io.Dir) !PollSummary {
    var summary: PollSummary = .{ .markets = 0, .theses = 0, .errors = 0 };

    // The rollup registry is module-level state; each fresh process starts
    // empty. Register the v1 rollups here so `recomputeThesisReality` can
    // resolve `manifest.rollup_fn` for every thesis we visit. Reset to
    // `.empty` first so the function is idempotent across repeated calls
    // (StringHashMapUnmanaged.deinit leaves the map `undefined`, which would
    // crash a second registerAll if pollAll gets called twice in-process —
    // foreshadowing daemon mode).
    rollup.registry = .empty;
    try rollup.registerAll(ctx.gpa);
    defer rollup.registry.deinit(ctx.gpa);

    var markets_dir = try kb_root.openDir(ctx.io, "markets", .{ .iterate = true });
    defer markets_dir.close(ctx.io);

    // Phase 1: collect all tickers from disk.
    var tickers_list: std.array_list.Managed([]const u8) = .init(ctx.arena);
    var it = markets_dir.iterate();
    while (try it.next(ctx.io)) |entry| {
        if (entry.kind != .directory) continue;
        const ticker = ctx.arena.dupe(u8, entry.name) catch |err| {
            try ctx.stderr.print("  ! {s}: alloc failed ({t})\n", .{ entry.name, err });
            summary.errors += 1;
            continue;
        };
        try tickers_list.append(ticker);
    }

    if (tickers_list.items.len == 0) {
        // No markets registered yet — skip to thesis loop.
        return runThesisLoop(ctx, kb_root, &summary);
    }

    const ts_ms: u64 = @intCast(@divFloor(std.Io.Clock.real.now(ctx.io).nanoseconds, 1_000_000));

    // Phase 2: batch fetch. Build a CSV of all tickers and call the list
    // endpoint with the `tickers=` filter. One HTTP roundtrip instead of N.
    const tickers_csv = std.mem.join(ctx.arena, ",", tickers_list.items) catch "";
    const batch_limit: u32 = @intCast(@min(tickers_list.items.len * 2, 1000));

    const batch_ok = batchPollAndApply(ctx, kb_root, tickers_list.items, tickers_csv, batch_limit, ts_ms, &summary) catch |err| blk: {
        try ctx.stderr.print("  ! batch fetch failed ({t}); falling back to per-ticker sequential\n", .{err});
        break :blk false;
    };

    // Phase 2b: sequential fallback for any tickers the batch missed
    // (or all of them if the batch call failed outright).
    if (!batch_ok) {
        for (tickers_list.items) |ticker| {
            const market = common.kalshi.markets.get(ctx.client, ctx.arena, ticker) catch |err| {
                try ctx.stderr.print("  ! {s}: fetch failed ({t})\n", .{ ticker, err });
                summary.errors += 1;
                continue;
            };
            const snap = toSnapshot(&market, ts_ms);
            common.kalshi.markets.kbHookMarket(ctx.gpa, ctx.io, kb_root, ticker, snap) catch |err| {
                try ctx.stderr.print("  ! {s}: kb write failed ({t})\n", .{ ticker, err });
                summary.errors += 1;
                continue;
            };
            summary.markets += 1;
        }
    }

    return runThesisLoop(ctx, kb_root, &summary);
}

/// Batch path: one HTTP call to `/markets?tickers=CSV`, then iterate the
/// response and call `kbHookMarket` per market. Returns true on success
/// (all expected tickers were found and applied), false if the response
/// was missing tickers we expected (caller falls back to sequential).
fn batchPollAndApply(
    ctx: *common.Context,
    kb_root: std.Io.Dir,
    expected_tickers: []const []const u8,
    tickers_csv: []const u8,
    limit: u32,
    ts_ms: u64,
    summary: *PollSummary,
) !bool {
    const list_resp = try common.kalshi.markets.list(ctx.client, ctx.arena, .{
        .limit = limit,
        .tickers = tickers_csv,
    });

    // Build a ticker → Market lookup for O(1) access.
    var by_ticker = std.StringHashMap(*const markets_mod.Market).init(ctx.gpa);
    defer by_ticker.deinit();
    for (list_resp.markets) |*m| {
        try by_ticker.put(m.ticker, m);
    }

    var missing: usize = 0;
    for (expected_tickers) |ticker| {
        const market_ptr = by_ticker.get(ticker) orelse {
            missing += 1;
            continue;
        };
        const snap = toSnapshot(market_ptr, ts_ms);
        common.kalshi.markets.kbHookMarket(ctx.gpa, ctx.io, kb_root, ticker, snap) catch |err| {
            try ctx.stderr.print("  ! {s}: kb write failed ({t})\n", .{ ticker, err });
            summary.errors += 1;
            continue;
        };
        summary.markets += 1;
    }

    if (missing > 0) {
        try ctx.stderr.print(
            "  ! batch fetch returned {d}/{d} tickers; falling back for missing\n",
            .{ expected_tickers.len - missing, expected_tickers.len },
        );
        // Partial success — caller decides whether to fall back for the rest.
        // We return true if at least one applied successfully; full re-fetch
        // would double-apply the successful ones, so prefer sequential
        // fill-in for just the missing set.
        for (expected_tickers) |ticker| {
            if (by_ticker.get(ticker) != null) continue;
            const market = common.kalshi.markets.get(ctx.client, ctx.arena, ticker) catch |err| {
                try ctx.stderr.print("  ! {s}: fallback fetch failed ({t})\n", .{ ticker, err });
                summary.errors += 1;
                continue;
            };
            const snap = toSnapshot(&market, ts_ms);
            common.kalshi.markets.kbHookMarket(ctx.gpa, ctx.io, kb_root, ticker, snap) catch |err| {
                try ctx.stderr.print("  ! {s}: kb write failed ({t})\n", .{ ticker, err });
                summary.errors += 1;
                continue;
            };
            summary.markets += 1;
        }
    }

    return true;
}

fn runThesisLoop(ctx: *common.Context, kb_root: std.Io.Dir, summary: *PollSummary) !PollSummary {
    var theses_dir = try kb_root.openDir(ctx.io, "theses", .{ .iterate = true });
    defer theses_dir.close(ctx.io);
    var t_it = theses_dir.iterate();
    while (try t_it.next(ctx.io)) |entry| {
        if (entry.kind != .directory) continue;
        const thesis_id = ctx.arena.dupe(u8, entry.name) catch |err| {
            try ctx.stderr.print("  ! thesis {s}: alloc failed ({t})\n", .{ entry.name, err });
            summary.errors += 1;
            continue;
        };
        _ = ingest.recomputeThesisReality(ctx.gpa, ctx.io, kb_root, thesis_id) catch |err| {
            try ctx.stderr.print("  ! thesis {s}: recompute failed ({t})\n", .{ thesis_id, err });
            summary.errors += 1;
            continue;
        };
        summary.theses += 1;
    }
    return summary.*;
}

/// Callback shape used by `pollerForTest` so the iteration logic can be
/// exercised without spinning up a real `Client`. The production `pollAll`
/// wraps `pollerForTest` semantics with a closure over the live client.
pub const SnapFn = *const fn (ticker: []const u8) ingest.MarketSnapshot;

/// Walk `kb_root/markets/` and call `kbHookMarket` on every subdirectory using
/// the supplied snapshot callback. Test seam — production `pollAll` (next
/// task) inlines the Kalshi client call here.
pub fn pollerForTest(
    allocator: std.mem.Allocator,
    io: std.Io,
    kb_root: std.Io.Dir,
    snap_fn: SnapFn,
) !void {
    var markets_dir = try kb_root.openDir(io, "markets", .{ .iterate = true });
    defer markets_dir.close(io);
    var it = markets_dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        const snap = snap_fn(entry.name);
        try markets_mod.kbHookMarket(allocator, io, kb_root, entry.name, snap);
    }
}

fn sampleSnapFn(_: []const u8) ingest.MarketSnapshot {
    return .{
        .ts_ms = 1,
        .yes_bid_cents = 50,
        .yes_ask_cents = 51,
        .volume = 100,
        .last_trade_cents = null,
    };
}

/// Convert a Kalshi dollar-string ("0.5000", "1.0000", "") to cents. Empty
/// strings become 0 — Kalshi returns "" for fields that aren't applicable
/// (e.g. no last trade yet).
fn dollarsToCents(s: []const u8) u32 {
    if (s.len == 0) return 0;
    var int_part: u32 = 0;
    var frac_part: u32 = 0;
    var frac_digits: u32 = 0;
    var saw_dot = false;
    for (s) |c| {
        if (c == '.') {
            saw_dot = true;
            continue;
        }
        if (c < '0' or c > '9') return 0;
        const d: u32 = c - '0';
        if (!saw_dot) {
            int_part = int_part * 10 + d;
        } else if (frac_digits < 2) {
            frac_part = frac_part * 10 + d;
            frac_digits += 1;
        }
        // Extra fractional digits beyond 2 are silently truncated (Kalshi
        // ticks to whole cents in `linear_cent` markets).
    }
    while (frac_digits < 2) : (frac_digits += 1) frac_part *= 10;
    return int_part * 100 + frac_part;
}

/// Parse a Kalshi volume-fp string ("123.00", "1500", "") to a whole-unit count.
/// Volume is contracts, integer; fractional part is dropped.
fn volumeFpToInt(s: []const u8) u64 {
    if (s.len == 0) return 0;
    var v: u64 = 0;
    for (s) |c| {
        if (c == '.') break;
        if (c < '0' or c > '9') return v;
        v = v * 10 + (c - '0');
    }
    return v;
}

/// Build a MarketSnapshot from a Kalshi `Market` and a wall-clock ts.
pub fn toSnapshot(m: *const markets_mod.Market, ts_ms: u64) ingest.MarketSnapshot {
    const last_cents = if (m.last_price_dollars.len == 0) null else @as(?u32, dollarsToCents(m.last_price_dollars));
    return .{
        .ts_ms = ts_ms,
        .yes_bid_cents = dollarsToCents(m.yes_bid_dollars),
        .yes_ask_cents = dollarsToCents(m.yes_ask_dollars),
        .volume = volumeFpToInt(m.volume_fp),
        .last_trade_cents = last_cents,
    };
}

test "toSnapshot maps dollar-strings into cents" {
    const m: markets_mod.Market = .{
        .ticker = "KXTEST",
        .yes_bid_dollars = "0.5000",
        .yes_ask_dollars = "0.5100",
        .last_price_dollars = "0.4800",
        .volume_fp = "1500.00",
    };
    const snap = toSnapshot(&m, 1234);
    try std.testing.expectEqual(@as(u64, 1234), snap.ts_ms);
    try std.testing.expectEqual(@as(u32, 50), snap.yes_bid_cents);
    try std.testing.expectEqual(@as(u32, 51), snap.yes_ask_cents);
    try std.testing.expectEqual(@as(u64, 1500), snap.volume);
    try std.testing.expectEqual(@as(?u32, 48), snap.last_trade_cents);
}

test "toSnapshot leaves last_trade null when last_price_dollars is empty" {
    const m: markets_mod.Market = .{
        .ticker = "KXTEST",
        .yes_bid_dollars = "0.0000",
        .yes_ask_dollars = "0.0000",
        .last_price_dollars = "",
        .volume_fp = "0.00",
    };
    const snap = toSnapshot(&m, 0);
    try std.testing.expectEqual(@as(?u32, null), snap.last_trade_cents);
    try std.testing.expectEqual(@as(u32, 0), snap.yes_bid_cents);
    try std.testing.expectEqual(@as(u64, 0), snap.volume);
}

test "dollarsToCents truncates beyond 2 fractional digits" {
    try std.testing.expectEqual(@as(u32, 50), dollarsToCents("0.5000"));
    try std.testing.expectEqual(@as(u32, 100), dollarsToCents("1.0000"));
    try std.testing.expectEqual(@as(u32, 50), dollarsToCents("0.5"));
    try std.testing.expectEqual(@as(u32, 12345), dollarsToCents("123.45"));
}

test "pollerForTest bumps chain_appends for every market in kb_root" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;

    // initTree(with_sample=true) lays down one market ("SAMPLE") and one thesis ("sample").
    try init_mod.initTree(io, tmp.dir, true);

    metrics.resetAll();
    try pollerForTest(std.testing.allocator, io, tmp.dir, sampleSnapFn);

    const v = metrics.chain_appends[@intFromEnum(metrics.ChainKind.market_reality)].load(.monotonic);
    try std.testing.expectEqual(@as(u64, 1), v);
}

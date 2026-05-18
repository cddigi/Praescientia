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
const markets_mod = praescientia.kalshi.markets;
const init_mod = praescientia.kb.init;
const metrics = praescientia.kb.metrics;

pub fn main(init: std.process.Init) !u8 {
    return common.runMain(init, "praescientia-poll-markets", &.{
        .{ .name = "run", .description = "Poll every market under --kb-root and recompute theses", .run = cmdRun },
    });
}

fn cmdRun(ctx: *common.Context) !u8 {
    try ctx.stdout.print("stub: poll-markets\n", .{});
    return 0;
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

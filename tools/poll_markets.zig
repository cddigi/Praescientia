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

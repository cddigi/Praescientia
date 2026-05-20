//! praescientia-game-state — classify Kalshi sports tickers into GamePhase
//! and recommend polling intervals.
//!
//! Subcommands:
//!   classify --ticker=T [--status=S] [--now=ISO|now]
//!     Emit {ticker, sport, phase, interval_seconds, info} JSON for one ticker.
//!     --status defaults to "active". --now defaults to system now (UTC ms).
//!   inspect --kb-root=PATH [--ticker-only]
//!     For each thesis in kb/theses/*/, classify its market_set[0] and
//!     emit a one-row-per-thesis table or JSON array.

const std = @import("std");
const common = @import("common");
const praescientia = @import("praescientia");

const game_state = praescientia.kb.game_state;
const markets_mod = praescientia.kalshi.markets;

pub fn main(init: std.process.Init) !u8 {
    return common.runMain(init, "praescientia-game-state", &.{
        .{ .name = "classify", .description = "Classify one ticker into a GamePhase + interval", .run = cmdClassify },
        .{ .name = "inspect", .description = "Classify every thesis in kb/theses/", .run = cmdInspect },
    });
}

fn parseNowMs(ctx: *common.Context) i64 {
    if (ctx.flagValue("--now")) |v| {
        if (std.mem.eql(u8, v, "now")) {
            return @intCast(@divFloor(std.Io.Clock.real.now(ctx.io).nanoseconds, 1_000_000));
        }
        if (std.fmt.parseInt(i64, v, 10)) |ms| return ms else |_| {}
        // Accept ISO-8601 too (best-effort)
        if (praescientia.kb.settlements.parseIso8601Ms(v)) |ms| return ms else |_| {}
    }
    return @intCast(@divFloor(std.Io.Clock.real.now(ctx.io).nanoseconds, 1_000_000));
}

const ClassifyOutput = struct {
    ticker: []const u8,
    sport: []const u8,
    phase: []const u8,
    interval_seconds: u32,
    now_ms: i64,
    info: struct {
        game_date_iso: ?[]const u8,
        game_time_iso: ?[]const u8,
        team_codes: [2]?[]const u8,
        duration_min: u32,
    },
};

fn classifyOne(ctx: *common.Context, ticker: []const u8, status: []const u8, now_ms: i64) ClassifyOutput {
    const info = game_state.parseTicker(ticker);
    const market: markets_mod.Market = .{ .ticker = ticker, .status = status, .close_time = "" };
    const phase = game_state.classify(market, now_ms);
    const interval = game_state.pollInterval(phase);
    _ = ctx;
    return .{
        .ticker = ticker,
        .sport = info.sport.label(),
        .phase = phase.label(),
        .interval_seconds = @intFromEnum(interval),
        .now_ms = now_ms,
        .info = .{
            .game_date_iso = info.game_date_iso,
            .game_time_iso = info.game_time_iso,
            .team_codes = info.team_codes,
            .duration_min = game_state.typicalGameDurationMin(info.sport),
        },
    };
}

fn cmdClassify(ctx: *common.Context) !u8 {
    const ticker = ctx.flagValue("--ticker") orelse ctx.positional(0) orelse {
        try ctx.stderr.print("usage: classify --ticker=TICKER [--status=active] [--now=NOW_MS|ISO|now]\n", .{});
        return 2;
    };
    const status = ctx.flagValue("--status") orelse "active";
    const now_ms = parseNowMs(ctx);

    const out = classifyOne(ctx, ticker, status, now_ms);
    try common.printJson(out, ctx.stdout);
    return 0;
}

fn cmdInspect(ctx: *common.Context) !u8 {
    const kb_root_path = ctx.flagValue("--kb-root") orelse "./kb";
    const now_ms = parseNowMs(ctx);

    var kb_root = std.Io.Dir.cwd().openDir(ctx.io, kb_root_path, .{ .iterate = true }) catch |err| {
        try ctx.stderr.print("open kb-root {s}: {t}\n", .{ kb_root_path, err });
        return 1;
    };
    defer kb_root.close(ctx.io);

    var theses_dir = kb_root.openDir(ctx.io, "theses", .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => {
            try ctx.stdout.print("[]\n", .{});
            return 0;
        },
        else => return err,
    };
    defer theses_dir.close(ctx.io);

    try ctx.stdout.print("[\n", .{});
    var first = true;
    var it = theses_dir.iterate();
    while (try it.next(ctx.io)) |entry| {
        if (entry.kind != .directory) continue;

        var thesis_dir = theses_dir.openDir(ctx.io, entry.name, .{}) catch continue;
        defer thesis_dir.close(ctx.io);

        const manifest_bytes = thesis_dir.readFileAlloc(ctx.io, "manifest.json", ctx.arena, .unlimited) catch continue;
        var parsed = std.json.parseFromSlice(std.json.Value, ctx.arena, manifest_bytes, .{}) catch continue;
        defer parsed.deinit();
        const root = parsed.value.object;
        const market_set_v = root.get("market_set") orelse continue;
        if (market_set_v != .array or market_set_v.array.items.len == 0) continue;
        const t_v = market_set_v.array.items[0];
        if (t_v != .string) continue;
        const ticker = try ctx.arena.dupe(u8, t_v.string);

        const thesis_id = try ctx.arena.dupe(u8, entry.name);
        const out = classifyOne(ctx, ticker, "active", now_ms);

        if (!first) try ctx.stdout.print(",\n", .{});
        first = false;
        try ctx.stdout.print(
            "  {{\"thesis_id\":\"{s}\",\"ticker\":\"{s}\",\"sport\":\"{s}\",\"phase\":\"{s}\",\"interval_seconds\":{d}}}",
            .{ thesis_id, out.ticker, out.sport, out.phase, out.interval_seconds },
        );
    }
    try ctx.stdout.print("\n]\n", .{});
    return 0;
}

// ---------------------------------------------------------------------------
// Tests — pure dispatch helpers (the full CLI is exercised by the smoke).
// ---------------------------------------------------------------------------

test "classifyOne — finalized status overrides date math" {
    const phase = game_state.classify(.{
        .ticker = "KXNBASPREAD-26MAY21CLENYK-NYK2",
        .status = "finalized",
        .close_time = "",
    }, 1_000_000_000_000);
    try std.testing.expectEqual(game_state.GamePhase.finalized, phase);
}

test "classifyOne — unknown ticker gets standard interval" {
    const interval = game_state.pollInterval(.unknown);
    try std.testing.expectEqual(@as(u32, 300), @intFromEnum(interval));
}

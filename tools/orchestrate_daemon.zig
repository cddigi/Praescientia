//! praescientia-orchestrate-daemon — long-running tick scheduler.
//!
//! Owns the wall-clock loop for the autonomous prediction agent. At each
//! tick, the daemon will (eventually) spawn `claude -p '/praescientia-
//! orchestrate --kb-root=... --max-ticks=1'` to execute one tick body via
//! Claude Code. This skeleton commit lays down the scheduling + signal
//! handling + lifecycle event log; the actual claude-spawn is wired in a
//! follow-up.
//!
//! Why a Zig daemon vs. a long-lived Claude Code session: a Zig process is
//! cheap, restarts cleanly, owns SIGINT/SIGTERM properly, and survives
//! Claude Code restarts/upgrades. The skill model remains valid for
//! interactive use; this daemon is for unattended operation.
//!
//! Flags:
//!   --kb-root=PATH       (default ./kb) Knowledge base root passed through to claude.
//!   --interval=DUR       (default 300s) Seconds between tick starts. Forms: 30s, 5m, 1h.
//!   --max-ticks=N        (optional)     Stop after N ticks. Useful for smoke runs.
//!   --dry-run            (optional)     Pass --dry-run to the per-tick claude invocation.
//!
//! Signals:
//!   SIGINT / SIGTERM     Set a shutdown flag. Daemon finishes the in-flight
//!                        tick (or short sleep) then exits cleanly.

const std = @import("std");
const common = @import("common");

/// Global atomic flag set by the signal handler. Checked by the main
/// loop between log lines and at every 1-second sleep slice so shutdown
/// latency stays under a second.
var shutdown_requested = std.atomic.Value(bool).init(false);

fn signalHandler(_: std.posix.SIG) callconv(.c) void {
    shutdown_requested.store(true, .seq_cst);
}

pub fn main(init: std.process.Init) !u8 {
    return common.runMain(init, "praescientia-orchestrate-daemon", &.{
        .{ .name = "run", .description = "Run the tick scheduler loop", .run = cmdRun },
    });
}

fn cmdRun(ctx: *common.Context) !u8 {
    const kb_root = ctx.flagValue("--kb-root") orelse "./kb";
    const interval_str = ctx.flagValue("--interval") orelse "300s";
    const max_ticks_str = ctx.flagValue("--max-ticks");
    const dry_run = ctx.flagValue("--dry-run") != null or hasBareFlag(ctx, "--dry-run");

    const interval_seconds = parseDuration(interval_str) catch {
        try ctx.stderr.print(
            "error: --interval must be of the form Ns / Nm / Nh; got '{s}'\n",
            .{interval_str},
        );
        return 2;
    };
    if (interval_seconds < 1) {
        try ctx.stderr.print("error: --interval must be at least 1s\n", .{});
        return 2;
    }

    const max_ticks: ?u32 = if (max_ticks_str) |s|
        std.fmt.parseInt(u32, s, 10) catch {
            try ctx.stderr.print("error: --max-ticks must be a positive integer\n", .{});
            return 2;
        }
    else
        null;
    if (max_ticks) |m| if (m == 0) {
        try ctx.stderr.print("error: --max-ticks must be >= 1\n", .{});
        return 2;
    };

    try installSignalHandlers();

    try ctx.stdout.print(
        "[startup] praescientia-orchestrate-daemon kb_root={s} interval={d}s max_ticks={?d} dry_run={}\n",
        .{ kb_root, interval_seconds, max_ticks, dry_run },
    );
    try ctx.stdout.flush();

    var tick_count: u32 = 0;
    while (!shutdown_requested.load(.seq_cst)) {
        tick_count += 1;
        if (max_ticks) |max| if (tick_count > max) {
            tick_count -= 1; // rewind so the post-loop log is accurate
            break;
        };

        try runTickStubbed(ctx, tick_count, max_ticks, kb_root, dry_run);
        if (shutdown_requested.load(.seq_cst)) break;

        // Terminal tick — skip sleep, exit cleanly.
        if (max_ticks) |max| if (tick_count >= max) break;

        try sleepInterruptible(ctx, interval_seconds, tick_count, max_ticks);
    }

    if (shutdown_requested.load(.seq_cst)) {
        try ctx.stdout.print(
            "[shutdown] signal received after {d} tick(s); exiting cleanly\n",
            .{tick_count},
        );
    } else {
        try ctx.stdout.print(
            "[shutdown] max_ticks reached after {d} tick(s); exiting\n",
            .{tick_count},
        );
    }
    try ctx.stdout.flush();
    return 0;
}

/// One stubbed tick. Logs each step boundary so the operator can see the
/// scheduling working before the AI dispatch is wired. Real implementation
/// (follow-up PR) will spawn `claude -p '/praescientia-orchestrate ...'`
/// and capture/log the response in place of the dispatch-stub line.
fn runTickStubbed(
    ctx: *common.Context,
    n: u32,
    max: ?u32,
    kb_root: []const u8,
    dry_run: bool,
) !void {
    try logTick(ctx, n, max, "starting");

    // Per tick.md §3 lifecycle. Each step is currently a log-only
    // placeholder; subprocess wiring lands in the follow-up.
    try logTickStep(ctx, n, max, 0, "pre-step: kill/paused/breaker gates (stub)");
    try logTickStep(ctx, n, max, 1, "begin: praescientia-ticks begin --kb-root=... (stub)");
    try logTickStep(ctx, n, max, 4, "poll: praescientia-poll-markets (stub)");
    try logTickStep(ctx, n, max, 5, "settle: praescientia-portfolio settlements (stub)");

    const dr_suffix: []const u8 = if (dry_run) " --dry-run" else "";
    if (max) |m| {
        try ctx.stdout.print(
            "[tick {d}/{d}] step  7: would spawn `claude -p \"/praescientia-orchestrate --kb-root={s} --max-ticks=1{s}\"`\n",
            .{ n, m, kb_root, dr_suffix },
        );
    } else {
        try ctx.stdout.print(
            "[tick {d}] step  7: would spawn `claude -p \"/praescientia-orchestrate --kb-root={s} --max-ticks=1{s}\"`\n",
            .{ n, kb_root, dr_suffix },
        );
    }
    try ctx.stdout.flush();

    try logTickStep(ctx, n, max, 10, "finish: praescientia-ticks finish (stub)");
    try logTickStep(ctx, n, max, 11, "summary: global commentary write (stub)");
    try logTick(ctx, n, max, "complete");
}

/// Note: no wall-clock timestamps in log lines (Zig 0.16 std.time
/// dropped them; the upcoming std.Io.Clock API isn't worth the
/// indirection for a skeleton). Operators can prepend timestamps via
/// `praescientia-orchestrate-daemon ... | ts '[%Y-%m-%d %H:%M:%S]'`
/// or systemd journal logging.
fn logTick(ctx: *common.Context, n: u32, max: ?u32, msg: []const u8) !void {
    if (max) |m| {
        try ctx.stdout.print("[tick {d}/{d}] {s}\n", .{ n, m, msg });
    } else {
        try ctx.stdout.print("[tick {d}] {s}\n", .{ n, msg });
    }
    try ctx.stdout.flush();
}

fn logTickStep(ctx: *common.Context, n: u32, max: ?u32, step: u8, msg: []const u8) !void {
    if (max) |m| {
        try ctx.stdout.print("[tick {d}/{d}] step {d:>2}: {s}\n", .{ n, m, step, msg });
    } else {
        try ctx.stdout.print("[tick {d}] step {d:>2}: {s}\n", .{ n, step, msg });
    }
    try ctx.stdout.flush();
}

/// Sleep `seconds` total but break into 1-second chunks so SIGINT/SIGTERM
/// take effect within a second instead of being deferred for the full
/// interval. Logs the sleep boundary once at the start so the operator
/// can see we're waiting (vs. hung).
fn sleepInterruptible(ctx: *common.Context, seconds: u64, n: u32, max: ?u32) !void {
    if (max) |m| {
        try ctx.stdout.print("[tick {d}/{d}] sleeping {d}s until next tick\n", .{ n, m, seconds });
    } else {
        try ctx.stdout.print("[tick {d}] sleeping {d}s until next tick\n", .{ n, seconds });
    }
    try ctx.stdout.flush();

    var slept: u64 = 0;
    while (slept < seconds and !shutdown_requested.load(.seq_cst)) {
        std.Io.sleep(ctx.io, std.Io.Duration.fromSeconds(1), .awake) catch {};
        slept += 1;
    }
}

fn installSignalHandlers() !void {
    var sa = std.posix.Sigaction{
        .handler = .{ .handler = signalHandler },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &sa, null);
    std.posix.sigaction(std.posix.SIG.TERM, &sa, null);
}

/// Accept `30s`, `5m`, `1h`. Returns seconds.
fn parseDuration(s: []const u8) !u64 {
    if (s.len < 2) return error.InvalidDuration;
    const suffix = s[s.len - 1];
    const num_str = s[0 .. s.len - 1];
    const num = try std.fmt.parseInt(u64, num_str, 10);
    return switch (suffix) {
        's', 'S' => num,
        'm', 'M' => num * 60,
        'h', 'H' => num * 3600,
        else => error.InvalidDuration,
    };
}

/// Look for a bare flag (no `=value`) anywhere in ctx.args. Needed because
/// `common.Context.flagValue` only matches `--name=VALUE` shape.
fn hasBareFlag(ctx: *common.Context, name: []const u8) bool {
    for (ctx.args[1..]) |a| {
        if (std.mem.eql(u8, a, name)) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "parseDuration accepts seconds, minutes, hours" {
    try std.testing.expectEqual(@as(u64, 30), try parseDuration("30s"));
    try std.testing.expectEqual(@as(u64, 300), try parseDuration("5m"));
    try std.testing.expectEqual(@as(u64, 3600), try parseDuration("1h"));
}

test "parseDuration rejects garbage" {
    try std.testing.expectError(error.InvalidDuration, parseDuration("nope"));
    try std.testing.expectError(error.InvalidDuration, parseDuration("5d")); // no 'd' suffix yet
    try std.testing.expectError(error.InvalidDuration, parseDuration("s"));
}

test "parseDuration accepts uppercase suffixes" {
    try std.testing.expectEqual(@as(u64, 60), try parseDuration("60S"));
    try std.testing.expectEqual(@as(u64, 120), try parseDuration("2M"));
}

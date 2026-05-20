//! praescientia-orchestrate-daemon — long-running tick scheduler.
//!
//! Owns the wall-clock loop for the autonomous prediction agent. Each
//! tick spawns `claude -p '/praescientia-orchestrate --kb-root=... --max-ticks=1'`,
//! which runs the full tick.md §3 lifecycle inside its session (begin,
//! poll, settle, fan-out, finish). The daemon's only responsibilities
//! are: signal handling, sentinel gates (KILL / PAUSED), reaping
//! orphan ticks at startup, spawning claude per tick, and sleeping.
//!
//! Earlier versions of this daemon ran begin / poll / settle / finish
//! itself before spawning claude — claude then ran them AGAIN inside
//! its own session, creating duplicate tick state. This version
//! delegates the entire lifecycle to claude.
//!
//! Why a Zig daemon vs. a long-lived Claude Code session: a Zig process
//! is cheap, restarts cleanly, owns SIGINT/SIGTERM properly, and
//! survives Claude Code restarts/upgrades. The skill model remains
//! valid for interactive use; this daemon is for unattended operation.
//!
//! Flags:
//!   --kb-root=PATH       (default ./kb)   Knowledge base root (passed through to claude).
//!   --interval=DUR       (default 300s)   Tick interval. Forms: 30s, 5m, 1h.
//!   --max-ticks=N        (optional)       Stop after N ticks.
//!   --dry-run            (optional)       Pass --dry-run through to claude.
//!   --no-dispatch        (optional)       Skip the claude step (sentinel-gate smoke).
//!
//! Signals:
//!   SIGINT / SIGTERM     Set a shutdown flag. Daemon finishes the
//!                        in-flight tick (or short sleep) then exits.
//!
//! On startup the daemon scans kb/.ticks/ for orphan ticks (a `.pre.json`
//! without a matching `.post.json`) and logs them so an operator knows
//! a prior session was interrupted mid-tick. Recovery itself stays
//! manual (resume semantics live in the orchestrate skill).

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
    const dry_run = hasBareFlag(ctx, "--dry-run");
    const no_dispatch = hasBareFlag(ctx, "--no-dispatch");

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
        "[startup] praescientia-orchestrate-daemon kb_root={s} interval={d}s max_ticks={?d} dry_run={} no_dispatch={}\n",
        .{ kb_root, interval_seconds, max_ticks, dry_run, no_dispatch },
    );
    try ctx.stdout.flush();

    try reapOrphanTicks(ctx, kb_root);

    var tick_count: u32 = 0;
    while (!shutdown_requested.load(.seq_cst)) {
        tick_count += 1;
        if (max_ticks) |max| if (tick_count > max) {
            tick_count -= 1; // rewind so the post-loop log is accurate
            break;
        };

        try runTick(ctx, tick_count, max_ticks, kb_root, dry_run, no_dispatch);
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

/// Run one full tick. The daemon's role is intentionally minimal:
/// check sentinel gates, spawn `claude -p '/praescientia-orchestrate'`,
/// log the first-line summary, exit. The claude subprocess runs the
/// full tick.md §3 lifecycle (begin → poll → settle → fan-out →
/// finish + global summary) inside its session.
///
/// Why so thin: in an earlier iteration the daemon also ran begin /
/// poll / settle / finish itself, then claude did them AGAIN inside
/// its own session. That created duplicate tick state on disk
/// (parallel pre.json/post.json files) and double-counted in any
/// per-tick metrics. Letting claude own the whole lifecycle removes
/// that duplication — the daemon is purely a scheduler.
fn runTick(
    ctx: *common.Context,
    n: u32,
    max: ?u32,
    kb_root: []const u8,
    dry_run: bool,
    no_dispatch: bool,
) !void {
    try logTick(ctx, n, max, "starting");

    // Pre-step 0: KILL / PAUSED sentinel gates. KILL is a hard abort
    // (signal shutdown, skip the dispatch). PAUSED is just logged for
    // visibility — the orchestrator skill enforces the actual
    // skip-execute behavior inside the claude session.
    if (try sentinelExists(ctx, kb_root, "KILL")) {
        try logTickStep(ctx, n, max, 0, "KILL sentinel present — requesting shutdown");
        shutdown_requested.store(true, .seq_cst);
        return;
    }
    if (try sentinelExists(ctx, kb_root, "PAUSED")) {
        try logTickStep(ctx, n, max, 0, "PAUSED sentinel present — orchestrator will skip step 9");
    } else {
        try logTickStep(ctx, n, max, 0, "gates clear (no KILL, no PAUSED)");
    }

    // Dispatch (or skip with --no-dispatch).
    if (no_dispatch) {
        try logTickStep(ctx, n, max, 7, "dispatch SKIPPED (--no-dispatch)");
    } else {
        runDispatch(ctx, n, max, kb_root, dry_run) catch |e| {
            try ctx.stderr.print(
                "[tick {d}] dispatch error: {t} (continuing to next tick)\n",
                .{ n, e },
            );
            try ctx.stderr.flush();
        };
    }

    try logTick(ctx, n, max, "complete");
}

fn runDispatch(
    ctx: *common.Context,
    n: u32,
    max: ?u32,
    kb_root: []const u8,
    dry_run: bool,
) !void {
    const dr: []const u8 = if (dry_run) " --dry-run" else "";
    const slash_cmd = try std.fmt.allocPrint(
        ctx.arena,
        "/praescientia-orchestrate --kb-root={s} --max-ticks=1{s}",
        .{ kb_root, dr },
    );

    if (max) |m| {
        try ctx.stdout.print(
            "[tick {d}/{d}] step  7: spawn claude -p \"{s}\" (may take several minutes)\n",
            .{ n, m, slash_cmd },
        );
    } else {
        try ctx.stdout.print(
            "[tick {d}] step  7: spawn claude -p \"{s}\" (may take several minutes)\n",
            .{ n, slash_cmd },
        );
    }
    try ctx.stdout.flush();

    var av = std.array_list.Managed([]const u8).init(ctx.arena);
    try av.append("claude");
    try av.append("-p");
    try av.append(slash_cmd);

    const r = try runCmd(ctx, av.items);
    if (r.exit != 0) {
        try logTickStep(ctx, n, max, 7, "claude exited non-zero");
        return error.DispatchFailed;
    }
    // Log a one-line summary; the full output is in claude's chain.
    const trimmed = std.mem.trim(u8, r.stdout, " \r\n\t");
    if (trimmed.len == 0) {
        try logTickStep(ctx, n, max, 7, "claude returned no stdout");
    } else {
        const first = firstLine(trimmed);
        try logTickStep(ctx, n, max, 7, "claude dispatch complete; first line follows");
        if (max) |m| {
            try ctx.stdout.print("[tick {d}/{d}]            > {s}\n", .{ n, m, first });
        } else {
            try ctx.stdout.print("[tick {d}]            > {s}\n", .{ n, first });
        }
        try ctx.stdout.flush();
    }
}

// ---------------------------------------------------------------------------
// Subprocess + filesystem helpers
// ---------------------------------------------------------------------------

const RunResult = struct {
    exit: u8,
    stdout: []const u8,
    stderr: []const u8,
};

const max_output_bytes: usize = 16 * 1024 * 1024;

/// Spawn a subprocess, capture stdout + stderr, wait for exit. Allocates
/// stdout/stderr from `ctx.arena` so they live as long as the tick.
fn runCmd(ctx: *common.Context, argv: []const []const u8) !RunResult {
    var child = try std.process.spawn(ctx.io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    });

    var stdout_reader = child.stdout.?.readerStreaming(ctx.io, &.{});
    var stderr_reader = child.stderr.?.readerStreaming(ctx.io, &.{});

    const stdout_bytes = stdout_reader.interface.allocRemaining(
        ctx.arena,
        .limited(max_output_bytes),
    ) catch &[_]u8{};
    const stderr_bytes = stderr_reader.interface.allocRemaining(
        ctx.arena,
        .limited(max_output_bytes),
    ) catch &[_]u8{};

    const term = try child.wait(ctx.io);
    const exit_code: u8 = switch (term) {
        .exited => |c| c,
        .signal => 130, // typical for SIGINT
        .stopped => 137,
        .unknown => 1,
    };

    return .{ .exit = exit_code, .stdout = stdout_bytes, .stderr = stderr_bytes };
}

/// First non-empty line of `s`, trimmed. Used to summarize subprocess
/// output for log lines without dumping the whole stdout buffer.
fn firstLine(s: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, s, '\n')) |nl_pos| {
        return std.mem.trim(u8, s[0..nl_pos], " \r\t");
    }
    return std.mem.trim(u8, s, " \r\n\t");
}

/// Check whether `kb_root/.ticks/<name>` exists. Used for KILL/PAUSED
/// sentinel checks. Missing file is the common case; other errors
/// propagate to the caller.
fn sentinelExists(
    ctx: *common.Context,
    kb_root: []const u8,
    name: []const u8,
) !bool {
    const path = try std.fmt.allocPrint(ctx.arena, "{s}/.ticks/{s}", .{ kb_root, name });
    std.Io.Dir.cwd().access(ctx.io, path, .{}) catch |e| switch (e) {
        error.FileNotFound => return false,
        else => return e,
    };
    return true;
}

/// Scan kb/.ticks/ for orphan ticks (a .pre.json without a matching
/// .post.json). Logs them so the operator knows a prior daemon run was
/// interrupted mid-tick. Recovery itself stays manual for now —
/// resume semantics live in the orchestrate skill.
fn reapOrphanTicks(ctx: *common.Context, kb_root: []const u8) !void {
    const ticks_path = try std.fmt.allocPrint(ctx.arena, "{s}/.ticks", .{kb_root});
    var dir = std.Io.Dir.cwd().openDir(ctx.io, ticks_path, .{ .iterate = true }) catch |e| switch (e) {
        error.FileNotFound => {
            try ctx.stdout.print(
                "[startup] reaper: {s} not present yet (fresh kb)\n",
                .{ticks_path},
            );
            try ctx.stdout.flush();
            return;
        },
        else => return e,
    };
    defer dir.close(ctx.io);

    var orphans: u32 = 0;
    var it = dir.iterate();
    while (try it.next(ctx.io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".pre.json")) continue;
        const tick_id = entry.name[0 .. entry.name.len - ".pre.json".len];
        const post_name = try std.fmt.allocPrint(ctx.arena, "{s}.post.json", .{tick_id});
        dir.access(ctx.io, post_name, .{}) catch |e| switch (e) {
            error.FileNotFound => {
                orphans += 1;
                try ctx.stdout.print(
                    "[startup] reaper: orphan tick {s} (pre.json without post.json — prior run interrupted)\n",
                    .{tick_id},
                );
            },
            else => return e,
        };
    }
    if (orphans == 0) {
        try ctx.stdout.print("[startup] reaper: no orphan ticks found\n", .{});
    } else {
        try ctx.stdout.print(
            "[startup] reaper: {d} orphan tick(s) detected; recovery is manual (see tick.md resume semantics)\n",
            .{orphans},
        );
    }
    try ctx.stdout.flush();
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

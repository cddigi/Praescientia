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
//!   --kb-root=PATH                 (default ./kb)   Knowledge base root (passed through to claude).
//!   --interval=DUR                 (default 300s)   Tick interval (global mode). Forms: 30s, 5m, 1h.
//!   --max-ticks=N                  (optional)       Stop after N ticks.
//!   --dry-run                      (optional)       Pass --dry-run through to claude.
//!   --no-dispatch                  (optional)       Skip the claude step (sentinel-gate smoke).
//!   --per-thesis-cadence           (optional)       OPT-IN. Per-thesis polling cadence
//!                                                   driven by praescientia-game-state classify.
//!                                                   In-game sports get 30s, scheduled get 30min,
//!                                                   unknown/non-sport get --interval default.
//!   --game-state-bin=PATH          (default ./zig-out/bin/praescientia-game-state)
//!                                                   Path to the classifier CLI (only used by
//!                                                   --per-thesis-cadence mode).
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
    const per_thesis = hasBareFlag(ctx, "--per-thesis-cadence");
    const game_state_bin = ctx.flagValue("--game-state-bin") orelse "./zig-out/bin/praescientia-game-state";

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
        "[startup] praescientia-orchestrate-daemon kb_root={s} interval={d}s max_ticks={?d} dry_run={} no_dispatch={} per_thesis={}\n",
        .{ kb_root, interval_seconds, max_ticks, dry_run, no_dispatch, per_thesis },
    );
    try ctx.stdout.flush();

    try reapOrphanTicks(ctx, kb_root);

    if (per_thesis) {
        return runLoopPerThesis(ctx, kb_root, interval_seconds, max_ticks, dry_run, no_dispatch, game_state_bin);
    }

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
// Per-thesis cadence loop (--per-thesis-cadence opt-in)
// ---------------------------------------------------------------------------

/// One row from `praescientia-game-state inspect` output, parsed into
/// a schedule entry. `next_tick_ms` is the absolute Unix ms when this
/// thesis should be dispatched next.
const ScheduleEntry = struct {
    thesis_id: []const u8,
    ticker: []const u8,
    phase: []const u8,
    interval_seconds: u32,
    next_tick_ms: i64,
};

fn nowMs(io: std.Io) i64 {
    return @intCast(@divFloor(std.Io.Clock.real.now(io).nanoseconds, 1_000_000));
}

/// Spawn `praescientia-game-state inspect --kb-root=PATH --now=NOW_MS`
/// and parse the JSON array into ScheduleEntry rows. Each entry's
/// `next_tick_ms` is initialized to `now_ms + interval` so a fresh
/// daemon picks every thesis up on the first sweep.
///
/// Returned slice is arena-allocated; caller's arena owns it.
fn loadSchedule(
    ctx: *common.Context,
    kb_root: []const u8,
    game_state_bin: []const u8,
    now_ms: i64,
) ![]ScheduleEntry {
    const now_str = try std.fmt.allocPrint(ctx.arena, "{d}", .{now_ms});
    var av = std.array_list.Managed([]const u8).init(ctx.arena);
    try av.append(game_state_bin);
    try av.append("inspect");
    try av.append(try std.fmt.allocPrint(ctx.arena, "--kb-root={s}", .{kb_root}));
    try av.append(try std.fmt.allocPrint(ctx.arena, "--now={s}", .{now_str}));
    const r = try runCmd(ctx, av.items);
    if (r.exit != 0) {
        try ctx.stderr.print(
            "[schedule] game-state inspect exit={d}: {s}\n",
            .{ r.exit, r.stderr },
        );
        return error.GameStateInspectFailed;
    }

    var parsed = try std.json.parseFromSlice(std.json.Value, ctx.arena, r.stdout, .{});
    defer parsed.deinit();
    if (parsed.value != .array) return error.GameStateInspectFailed;

    var out: std.array_list.Managed(ScheduleEntry) = .init(ctx.arena);
    for (parsed.value.array.items) |item| {
        if (item != .object) continue;
        const obj = item.object;
        const thesis_id_v = obj.get("thesis_id") orelse continue;
        const ticker_v = obj.get("ticker") orelse continue;
        const phase_v = obj.get("phase") orelse continue;
        const interval_v = obj.get("interval_seconds") orelse continue;
        if (thesis_id_v != .string or ticker_v != .string or
            phase_v != .string or interval_v != .integer)
        {
            continue;
        }
        const interval: u32 = @intCast(interval_v.integer);
        try out.append(.{
            .thesis_id = try ctx.arena.dupe(u8, thesis_id_v.string),
            .ticker = try ctx.arena.dupe(u8, ticker_v.string),
            .phase = try ctx.arena.dupe(u8, phase_v.string),
            .interval_seconds = interval,
            .next_tick_ms = now_ms + @as(i64, interval) * 1000,
        });
    }
    return out.items;
}

/// Re-classify a single thesis after its tick fired. Returns the new
/// phase + interval. Used to advance `next_tick_ms` after dispatch.
fn classifyOne(
    ctx: *common.Context,
    game_state_bin: []const u8,
    ticker: []const u8,
    now_ms: i64,
) !struct { phase: []const u8, interval_seconds: u32 } {
    var av = std.array_list.Managed([]const u8).init(ctx.arena);
    try av.append(game_state_bin);
    try av.append("classify");
    try av.append(try std.fmt.allocPrint(ctx.arena, "--ticker={s}", .{ticker}));
    try av.append(try std.fmt.allocPrint(ctx.arena, "--now={d}", .{now_ms}));
    const r = try runCmd(ctx, av.items);
    if (r.exit != 0) return error.GameStateClassifyFailed;

    var parsed = try std.json.parseFromSlice(std.json.Value, ctx.arena, r.stdout, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    const phase_v = root.get("phase") orelse return error.GameStateClassifyFailed;
    const interval_v = root.get("interval_seconds") orelse return error.GameStateClassifyFailed;
    if (phase_v != .string or interval_v != .integer) return error.GameStateClassifyFailed;
    return .{
        .phase = try ctx.arena.dupe(u8, phase_v.string),
        .interval_seconds = @intCast(interval_v.integer),
    };
}

/// Spawn `claude -p '/praescientia-orchestrate --kb-root=... --theses=...'`
/// for a comma-separated list of due thesis IDs. Returns the same
/// RunResult shape as the all-theses dispatch.
fn runDispatchTheses(
    ctx: *common.Context,
    n: u32,
    max: ?u32,
    kb_root: []const u8,
    dry_run: bool,
    theses_csv: []const u8,
) !void {
    const dr: []const u8 = if (dry_run) " --dry-run" else "";
    const slash_cmd = try std.fmt.allocPrint(
        ctx.arena,
        "/praescientia-orchestrate --kb-root={s} --max-ticks=1 --theses={s}{s}",
        .{ kb_root, theses_csv, dr },
    );

    if (max) |m| {
        try ctx.stdout.print(
            "[tick {d}/{d}] step  7: spawn claude -p \"{s}\"\n",
            .{ n, m, slash_cmd },
        );
    } else {
        try ctx.stdout.print(
            "[tick {d}] step  7: spawn claude -p \"{s}\"\n",
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

/// Main loop for --per-thesis-cadence mode.
///
/// On each iteration:
///   1. Refresh schedule from disk + game-state CLI (cheap; <500ms typical).
///   2. Check KILL/PAUSED sentinels.
///   3. Find theses whose next_tick_ms <= now.
///   4. If any due, spawn claude with --theses=<csv> (one subprocess).
///   5. Re-classify each fired thesis (phases may have transitioned).
///   6. Sleep until min(next_tick_ms) or until interrupted.
///
/// `default_interval_seconds` is used as the wake-up cap so the daemon
/// never sleeps longer than the operator's expected baseline cadence.
fn runLoopPerThesis(
    ctx: *common.Context,
    kb_root: []const u8,
    default_interval_seconds: u64,
    max_ticks: ?u32,
    dry_run: bool,
    no_dispatch: bool,
    game_state_bin: []const u8,
) !u8 {
    try ctx.stdout.print(
        "[startup] per-thesis cadence enabled (default_interval={d}s, game_state_bin={s})\n",
        .{ default_interval_seconds, game_state_bin },
    );
    try ctx.stdout.flush();

    var tick_count: u32 = 0;
    while (!shutdown_requested.load(.seq_cst)) {
        if (max_ticks) |m| if (tick_count >= m) break;

        const now = nowMs(ctx.io);

        // Step 1: refresh schedule.
        const schedule = loadSchedule(ctx, kb_root, game_state_bin, now) catch |e| {
            try ctx.stderr.print("[schedule] load failed: {t}; sleeping {d}s\n", .{ e, default_interval_seconds });
            try ctx.stderr.flush();
            try sleepInterruptible(ctx, default_interval_seconds, tick_count, max_ticks);
            continue;
        };

        if (schedule.len == 0) {
            try ctx.stdout.print("[schedule] no theses found; sleeping {d}s\n", .{default_interval_seconds});
            try ctx.stdout.flush();
            try sleepInterruptible(ctx, default_interval_seconds, tick_count, max_ticks);
            continue;
        }

        // Sentinel gates.
        if (try sentinelExists(ctx, kb_root, "KILL")) {
            try ctx.stdout.print("[gate] KILL sentinel present — exiting\n", .{});
            shutdown_requested.store(true, .seq_cst);
            break;
        }
        const paused = try sentinelExists(ctx, kb_root, "PAUSED");

        // Step 3: find due theses. With a fresh schedule, every entry's
        // next_tick_ms == now + interval, so the FIRST loop iteration
        // never finds anything due. To make the first iteration useful,
        // bias the initial schedule by setting next_tick_ms to `now` for
        // every entry (one-time bootstrap).
        var due: std.array_list.Managed([]const u8) = .init(ctx.arena);
        for (schedule) |s| {
            if (s.next_tick_ms <= now) {
                try due.append(s.thesis_id);
            }
        }

        // Bootstrap: if this is the first iteration (tick_count==0) and
        // nothing is due, treat all theses as due. This ensures the
        // daemon picks up every thesis at least once on startup.
        if (tick_count == 0 and due.items.len == 0) {
            for (schedule) |s| try due.append(s.thesis_id);
        }

        if (due.items.len == 0) {
            // Count idle iterations as ticks too — otherwise --max-ticks
            // never terminates a daemon with no due theses.
            tick_count += 1;
            // Sleep until the earliest next_tick_ms (capped at default interval).
            var earliest: i64 = now + @as(i64, @intCast(default_interval_seconds)) * 1000;
            for (schedule) |s| {
                if (s.next_tick_ms < earliest) earliest = s.next_tick_ms;
            }
            const sleep_ms: i64 = if (earliest > now) earliest - now else 1000;
            const sleep_s: u64 = @intCast(@divFloor(sleep_ms, 1000));
            const clamped: u64 = if (sleep_s > default_interval_seconds) default_interval_seconds else sleep_s;
            if (clamped > 0) {
                try ctx.stdout.print(
                    "[idle tick {d}] no theses due; sleeping {d}s (earliest next dispatch in {d}s)\n",
                    .{ tick_count, clamped, sleep_s },
                );
                try ctx.stdout.flush();
                try sleepInterruptible(ctx, clamped, tick_count, max_ticks);
            }
            continue;
        }

        // Build the CSV of due thesis IDs.
        var csv_buf: std.array_list.Managed(u8) = .init(ctx.arena);
        for (due.items, 0..) |id, i| {
            if (i > 0) try csv_buf.append(',');
            try csv_buf.appendSlice(id);
        }
        const theses_csv = csv_buf.items;

        tick_count += 1;
        try logTick(ctx, tick_count, max_ticks, "starting per-thesis dispatch");
        try ctx.stdout.print(
            "[tick {d}] due theses ({d}): {s}\n",
            .{ tick_count, due.items.len, theses_csv },
        );
        try ctx.stdout.flush();

        if (paused) {
            try logTickStep(ctx, tick_count, max_ticks, 0, "PAUSED sentinel — orchestrator will skip step 9");
        }

        // Dispatch.
        if (no_dispatch) {
            try logTickStep(ctx, tick_count, max_ticks, 7, "dispatch SKIPPED (--no-dispatch)");
        } else {
            runDispatchTheses(ctx, tick_count, max_ticks, kb_root, dry_run, theses_csv) catch |e| {
                try ctx.stderr.print(
                    "[tick {d}] dispatch error: {t} (continuing)\n",
                    .{ tick_count, e },
                );
                try ctx.stderr.flush();
            };
        }

        // Step 5: re-classify each fired thesis. Phases may transition
        // mid-game (e.g., near_game → in_game when the clock crosses tip).
        // We can't mutate `schedule` in place (it's arena-allocated and
        // re-loaded next iteration anyway), so the re-classification's
        // only purpose here is to compute the immediate sleep delay.
        const post_dispatch_now = nowMs(ctx.io);
        var earliest_next: i64 = post_dispatch_now + @as(i64, @intCast(default_interval_seconds)) * 1000;
        for (due.items) |tid| {
            // Find the schedule entry's ticker.
            const ticker = for (schedule) |s| {
                if (std.mem.eql(u8, s.thesis_id, tid)) break s.ticker;
            } else continue;
            const classified = classifyOne(ctx, game_state_bin, ticker, post_dispatch_now) catch continue;
            const next_ms = post_dispatch_now + @as(i64, classified.interval_seconds) * 1000;
            if (next_ms < earliest_next) earliest_next = next_ms;
            try ctx.stdout.print(
                "[tick {d}] post-dispatch reclass: {s} → phase={s}, next in {d}s\n",
                .{ tick_count, tid, classified.phase, classified.interval_seconds },
            );
        }
        try ctx.stdout.flush();

        try logTick(ctx, tick_count, max_ticks, "complete");

        if (shutdown_requested.load(.seq_cst)) break;
        if (max_ticks) |m| if (tick_count >= m) break;

        // Sleep until the earliest next_tick_ms (capped at default_interval).
        const now2 = nowMs(ctx.io);
        const sleep_ms: i64 = if (earliest_next > now2) earliest_next - now2 else 1000;
        const sleep_s: u64 = @intCast(@divFloor(sleep_ms, 1000));
        const clamped: u64 = blk: {
            if (sleep_s == 0) break :blk 1;
            if (sleep_s > default_interval_seconds) break :blk default_interval_seconds;
            break :blk sleep_s;
        };
        try sleepInterruptible(ctx, clamped, tick_count, max_ticks);
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

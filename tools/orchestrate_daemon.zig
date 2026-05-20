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
        try logSubprocessFailure(ctx, n, max, "claude", r);
        return error.DispatchFailed;
    }
    // Log a one-line summary; the full output is in claude's chain.
    const trimmed = std.mem.trim(u8, r.stdout, " \r\n\t");
    if (trimmed.len == 0) {
        try logTickStep(ctx, n, max, 7, "claude returned no stdout");
        try logStderrTail(ctx, n, max, r.stderr, "claude (zero-stdout)");
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
    const num = std.fmt.parseInt(u64, num_str, 10) catch return error.InvalidDuration;
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
    /// Count of consecutive DispatchFailed events on this thesis. Reset to 0
    /// on any successful dispatch. Used to compute exponential backoff
    /// on `next_tick_ms` — prevents retry storms when claude is failing
    /// systemically.
    consecutive_failures: u8 = 0,
};

/// Compute the next_tick_ms delay for a thesis given its base interval
/// and consecutive-failure count. With 0 failures: returns base. With N
/// failures (N > 0): returns base × 2^min(N, 6), capped at 3600s. This
/// gives a sequence of base, 2×, 4×, 8×, 16×, 32×, 64× (cap) for N=0..6+.
fn backoffSeconds(base_seconds: u32, consecutive_failures: u8) u32 {
    if (consecutive_failures == 0) return base_seconds;
    const shift: u3 = @intCast(@min(@as(u8, 6), consecutive_failures));
    const multiplier: u32 = @as(u32, 1) << shift;
    const candidate: u64 = @as(u64, base_seconds) * multiplier;
    const cap: u64 = 3600;
    return @intCast(@min(candidate, cap));
}

fn nowMs(io: std.Io) i64 {
    return @intCast(@divFloor(std.Io.Clock.real.now(io).nanoseconds, 1_000_000));
}

fn findScheduleIndex(schedule: []const ScheduleEntry, thesis_id: []const u8) ?usize {
    for (schedule, 0..) |s, i| {
        if (std.mem.eql(u8, s.thesis_id, thesis_id)) return i;
    }
    return null;
}

/// Refresh the daemon's persistent schedule against the kb on disk.
///
/// On each iteration:
///   - Existing entries: refresh ticker/phase/interval (in case the
///     thesis manifest changed or the game phase transitioned). PRESERVE
///     `next_tick_ms` so the schedule accumulates state across iterations
///     — without this, the daemon would never re-fire after the bootstrap.
///   - New entries (not in schedule yet): add with `next_tick_ms = now_ms`
///     so they're immediately due on the next loop iteration. This
///     handles both the bootstrap case (empty schedule → all due) and
///     mid-run thesis additions (new thesis materialized → picked up fast).
///   - Entries no longer present on disk: removed.
///
/// Also handles **phase-transition acceleration**: if the new interval
/// would put the next tick sooner than the existing scheduled time
/// (e.g., game tipped during a 30-min sleep, transitioning from
/// `scheduled` → `in_game` and shortening the interval from 1800s to
/// 30s), advance `next_tick_ms` to `now + new_interval_ms`. Without
/// this we'd wait out the old long interval and miss the escalation.
fn refreshSchedule(
    ctx: *common.Context,
    schedule: *std.array_list.Managed(ScheduleEntry),
    kb_root: []const u8,
    game_state_bin: []const u8,
    now_ms: i64,
) !void {
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

    var present_ids: std.array_list.Managed([]const u8) = .init(ctx.arena);

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

        try present_ids.append(thesis_id_v.string);

        if (findScheduleIndex(schedule.items, thesis_id_v.string)) |i| {
            // EXISTING: refresh metadata, preserve next_tick_ms, BUT
            // accelerate if the new interval would advance us sooner.
            schedule.items[i].ticker = try ctx.arena.dupe(u8, ticker_v.string);
            schedule.items[i].phase = try ctx.arena.dupe(u8, phase_v.string);
            schedule.items[i].interval_seconds = interval;
            const candidate_next = now_ms + @as(i64, interval) * 1000;
            if (candidate_next < schedule.items[i].next_tick_ms) {
                schedule.items[i].next_tick_ms = candidate_next;
            }
        } else {
            // NEW: add as immediately-due so the next iteration fires it.
            try schedule.append(.{
                .thesis_id = try ctx.arena.dupe(u8, thesis_id_v.string),
                .ticker = try ctx.arena.dupe(u8, ticker_v.string),
                .phase = try ctx.arena.dupe(u8, phase_v.string),
                .interval_seconds = interval,
                .next_tick_ms = now_ms,
            });
        }
    }

    // Drop entries no longer present on disk.
    var i: usize = 0;
    while (i < schedule.items.len) {
        const existing = schedule.items[i].thesis_id;
        var found = false;
        for (present_ids.items) |pid| {
            if (std.mem.eql(u8, pid, existing)) {
                found = true;
                break;
            }
        }
        if (!found) {
            _ = schedule.orderedRemove(i);
        } else {
            i += 1;
        }
    }
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
        try logSubprocessFailure(ctx, n, max, "claude", r);
        return error.DispatchFailed;
    }
    const trimmed = std.mem.trim(u8, r.stdout, " \r\n\t");
    if (trimmed.len == 0) {
        try logTickStep(ctx, n, max, 7, "claude returned no stdout");
        // Diagnostic: also tail stderr in case there's a clue.
        try logStderrTail(ctx, n, max, r.stderr, "claude (zero-stdout)");
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

/// Log the last ~2KB of a failing subprocess's stderr, plus the exit code.
/// Critical diagnostic when claude exits non-zero — without this we're
/// blind to why dispatches fail.
fn logSubprocessFailure(
    ctx: *common.Context,
    n: u32,
    max: ?u32,
    cmd_label: []const u8,
    r: RunResult,
) !void {
    const prefix = if (max) |m|
        try std.fmt.allocPrint(ctx.arena, "[tick {d}/{d}]", .{ n, m })
    else
        try std.fmt.allocPrint(ctx.arena, "[tick {d}]", .{n});

    try ctx.stderr.print("{s} {s} exit={d} stdout_bytes={d} stderr_bytes={d}\n", .{
        prefix, cmd_label, r.exit, r.stdout.len, r.stderr.len,
    });
    // Tail stderr (last 2KB) so we see the actual error message.
    const stderr_tail = if (r.stderr.len > 2048) r.stderr[r.stderr.len - 2048 ..] else r.stderr;
    if (stderr_tail.len > 0) {
        try ctx.stderr.print("{s} {s} stderr tail (last {d}B):\n", .{ prefix, cmd_label, stderr_tail.len });
        try ctx.stderr.print("---8<---\n{s}\n--->8---\n", .{stderr_tail});
    }
    // Also tail stdout if non-empty (sometimes claude writes errors there too).
    const stdout_tail = if (r.stdout.len > 1024) r.stdout[r.stdout.len - 1024 ..] else r.stdout;
    if (stdout_tail.len > 0) {
        try ctx.stderr.print("{s} {s} stdout tail (last {d}B):\n", .{ prefix, cmd_label, stdout_tail.len });
        try ctx.stderr.print("---8<---\n{s}\n--->8---\n", .{stdout_tail});
    }
    try ctx.stderr.flush();
}

fn logStderrTail(
    ctx: *common.Context,
    n: u32,
    max: ?u32,
    stderr_bytes: []const u8,
    label: []const u8,
) !void {
    if (stderr_bytes.len == 0) return;
    const tail = if (stderr_bytes.len > 512) stderr_bytes[stderr_bytes.len - 512 ..] else stderr_bytes;
    const prefix = if (max) |m|
        try std.fmt.allocPrint(ctx.arena, "[tick {d}/{d}]", .{ n, m })
    else
        try std.fmt.allocPrint(ctx.arena, "[tick {d}]", .{n});
    try ctx.stderr.print("{s} {s} stderr tail:\n{s}\n", .{ prefix, label, tail });
    try ctx.stderr.flush();
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

    // PERSISTENT schedule — accumulates state across iterations. New
    // theses get added with next_tick_ms=now (immediately due). Existing
    // entries preserve their next_tick_ms unless a phase transition
    // would advance them sooner. Removed theses get dropped.
    var schedule: std.array_list.Managed(ScheduleEntry) = .init(ctx.arena);

    var tick_count: u32 = 0;
    while (!shutdown_requested.load(.seq_cst)) {
        if (max_ticks) |m| if (tick_count >= m) break;

        const now = nowMs(ctx.io);

        refreshSchedule(ctx, &schedule, kb_root, game_state_bin, now) catch |e| {
            try ctx.stderr.print("[schedule] refresh failed: {t}; sleeping {d}s\n", .{ e, default_interval_seconds });
            try ctx.stderr.flush();
            try sleepInterruptible(ctx, default_interval_seconds, tick_count, max_ticks);
            continue;
        };

        if (schedule.items.len == 0) {
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

        // Find due theses against the persistent schedule.
        var due: std.array_list.Managed([]const u8) = .init(ctx.arena);
        for (schedule.items) |s| {
            if (s.next_tick_ms <= now) {
                try due.append(s.thesis_id);
            }
        }

        if (due.items.len == 0) {
            // Count idle iterations as ticks too — otherwise --max-ticks
            // never terminates a daemon with no due theses.
            tick_count += 1;
            // Sleep until the earliest next_tick_ms (capped at default interval).
            var earliest: i64 = now + @as(i64, @intCast(default_interval_seconds)) * 1000;
            for (schedule.items) |s| {
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
        var dispatch_failed = false;
        if (no_dispatch) {
            try logTickStep(ctx, tick_count, max_ticks, 7, "dispatch SKIPPED (--no-dispatch)");
        } else {
            runDispatchTheses(ctx, tick_count, max_ticks, kb_root, dry_run, theses_csv) catch |e| {
                try ctx.stderr.print(
                    "[tick {d}] dispatch error: {t} (continuing)\n",
                    .{ tick_count, e },
                );
                try ctx.stderr.flush();
                dispatch_failed = true;
            };
        }

        // Step 5: re-classify each fired thesis and UPDATE the persistent
        // schedule. Phases may transition mid-game (e.g., near_game →
        // in_game when the clock crosses tip). The schedule now persists
        // across iterations, so next iteration's `due` check sees the
        // updated next_tick_ms.
        //
        // BACKOFF: on dispatch_failed, increment consecutive_failures and
        // apply exponential backoff to next_tick_ms — prevents the daemon
        // from hammering claude with failing dispatches every 30s when
        // claude is systemically broken. Reset to 0 on success.
        const post_dispatch_now = nowMs(ctx.io);
        var earliest_next: i64 = post_dispatch_now + @as(i64, @intCast(default_interval_seconds)) * 1000;
        for (due.items) |tid| {
            const idx = findScheduleIndex(schedule.items, tid) orelse continue;
            const ticker = schedule.items[idx].ticker;
            const classified = classifyOne(ctx, game_state_bin, ticker, post_dispatch_now) catch continue;

            // Update failure counter based on dispatch outcome.
            if (dispatch_failed) {
                if (schedule.items[idx].consecutive_failures < 255) {
                    schedule.items[idx].consecutive_failures += 1;
                }
            } else if (!no_dispatch) {
                // Successful real dispatch — reset the counter.
                schedule.items[idx].consecutive_failures = 0;
            }
            // (--no-dispatch leaves the counter unchanged — it's a smoke
            //  test, not a real dispatch attempt.)

            const effective_interval = backoffSeconds(classified.interval_seconds, schedule.items[idx].consecutive_failures);
            const next_ms = post_dispatch_now + @as(i64, effective_interval) * 1000;

            schedule.items[idx].phase = try ctx.arena.dupe(u8, classified.phase);
            schedule.items[idx].interval_seconds = classified.interval_seconds;
            schedule.items[idx].next_tick_ms = next_ms;
            if (next_ms < earliest_next) earliest_next = next_ms;

            if (schedule.items[idx].consecutive_failures > 0) {
                try ctx.stdout.print(
                    "[tick {d}] post-dispatch reclass: {s} → phase={s}, base={d}s, backoff={d}s (fails={d})\n",
                    .{ tick_count, tid, classified.phase, classified.interval_seconds, effective_interval, schedule.items[idx].consecutive_failures },
                );
            } else {
                try ctx.stdout.print(
                    "[tick {d}] post-dispatch reclass: {s} → phase={s}, next in {d}s\n",
                    .{ tick_count, tid, classified.phase, classified.interval_seconds },
                );
            }
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

test "backoffSeconds — zero failures returns base" {
    try std.testing.expectEqual(@as(u32, 30), backoffSeconds(30, 0));
    try std.testing.expectEqual(@as(u32, 300), backoffSeconds(300, 0));
}

test "backoffSeconds — doubles per failure" {
    try std.testing.expectEqual(@as(u32, 60), backoffSeconds(30, 1));
    try std.testing.expectEqual(@as(u32, 120), backoffSeconds(30, 2));
    try std.testing.expectEqual(@as(u32, 240), backoffSeconds(30, 3));
}

test "backoffSeconds — caps at 3600s" {
    // 300 × 64 = 19200, should cap at 3600
    try std.testing.expectEqual(@as(u32, 3600), backoffSeconds(300, 6));
    try std.testing.expectEqual(@as(u32, 3600), backoffSeconds(300, 7));
    try std.testing.expectEqual(@as(u32, 3600), backoffSeconds(300, 200));
}

test "backoffSeconds — short interval stays bounded" {
    // 30 × 64 = 1920, well under cap
    try std.testing.expectEqual(@as(u32, 1920), backoffSeconds(30, 6));
    // 30 × 64 still since shift saturates at 6
    try std.testing.expectEqual(@as(u32, 1920), backoffSeconds(30, 10));
}

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

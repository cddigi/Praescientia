//! praescientia-orchestrate-daemon — long-running tick scheduler.
//!
//! Owns the wall-clock loop for the autonomous prediction agent. At each
//! tick the daemon walks the tick.md §3 lifecycle by spawning the
//! existing `praescientia-*` CLIs as subprocesses, plus one `claude -p
//! '/praescientia-orchestrate ...'` invocation for the AI dispatch step.
//!
//! Why a Zig daemon vs. a long-lived Claude Code session: a Zig process
//! is cheap, restarts cleanly, owns SIGINT/SIGTERM properly, and
//! survives Claude Code restarts/upgrades. The skill model remains
//! valid for interactive use; this daemon is for unattended operation.
//!
//! Flags:
//!   --kb-root=PATH       (default ./kb)           Knowledge base root.
//!   --bin-dir=PATH       (default ./zig-out/bin)  Where to find the praescientia-* CLIs.
//!   --interval=DUR       (default 300s)           Tick interval. Forms: 30s, 5m, 1h.
//!   --max-ticks=N        (optional)               Stop after N ticks.
//!   --dry-run            (optional)               Pass --dry-run through to claude.
//!   --no-dispatch        (optional)               Skip the claude step (lifecycle smoke).
//!
//! Signals:
//!   SIGINT / SIGTERM     Set a shutdown flag. Daemon finishes the
//!                        in-flight tick (or short sleep) then exits.
//!
//! On startup the daemon scans kb/.ticks/ for orphan ticks (a `.pre.json`
//! without a matching `.post.json`) and logs them so an operator knows
//! a prior daemon run was interrupted mid-tick. Recovery itself stays
//! manual for now (resume semantics live in the orchestrate skill).

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
    const bin_dir = ctx.flagValue("--bin-dir") orelse "./zig-out/bin";
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
        "[startup] praescientia-orchestrate-daemon kb_root={s} bin_dir={s} interval={d}s max_ticks={?d} dry_run={} no_dispatch={}\n",
        .{ kb_root, bin_dir, interval_seconds, max_ticks, dry_run, no_dispatch },
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

        try runTick(ctx, tick_count, max_ticks, kb_root, bin_dir, dry_run, no_dispatch);
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

/// Run one full tick. Walks the tick.md §3 lifecycle by spawning the
/// existing CLIs as subprocesses. Each step is best-effort: failures
/// are logged and the tick continues (matches the graceful-degradation
/// pattern documented in tick.md). Returns normally even when a step
/// fails — the daemon's responsibility is keeping the tick clock
/// running; chain integrity is the CLIs' responsibility.
fn runTick(
    ctx: *common.Context,
    n: u32,
    max: ?u32,
    kb_root: []const u8,
    bin_dir: []const u8,
    dry_run: bool,
    no_dispatch: bool,
) !void {
    try logTick(ctx, n, max, "starting");

    // Pre-step 0: KILL / PAUSED sentinel gates. The pause sentinel
    // doesn't stop the tick — it tells the orchestrator skill to skip
    // step 9. The daemon just reports state; orchestrator handles the
    // semantics. KILL is a hard abort.
    if (try sentinelExists(ctx, kb_root, "KILL")) {
        try logTickStep(ctx, n, max, 0, "KILL sentinel present — requesting shutdown");
        shutdown_requested.store(true, .seq_cst);
        return;
    }
    const paused = try sentinelExists(ctx, kb_root, "PAUSED");
    if (paused) {
        try logTickStep(ctx, n, max, 0, "PAUSED sentinel present — orchestrator will skip step 9");
    } else {
        try logTickStep(ctx, n, max, 0, "gates clear (no KILL, no PAUSED)");
    }

    // Step 1: begin. Captures tick_id from stdout.
    const tick_id = runBegin(ctx, n, max, kb_root, bin_dir) catch |e| {
        try logTickStep(ctx, n, max, 1, "begin failed — skipping rest of tick");
        try ctx.stderr.print("  begin error: {t}\n", .{e});
        try ctx.stderr.flush();
        return;
    };

    // Step 4: poll markets. Best-effort.
    runPoll(ctx, n, max, kb_root, bin_dir) catch |e| {
        try ctx.stderr.print(
            "[tick {d}] step 4 poll error: {t} (continuing)\n",
            .{ n, e },
        );
        try ctx.stderr.flush();
    };

    // Step 5: settlements. Best-effort.
    runSettle(ctx, n, max, kb_root, bin_dir) catch |e| {
        try ctx.stderr.print(
            "[tick {d}] step 5 settle error: {t} (continuing)\n",
            .{ n, e },
        );
        try ctx.stderr.flush();
    };

    // Step 7: dispatch via claude -p. The big one. May take minutes.
    if (no_dispatch) {
        try logTickStep(ctx, n, max, 7, "dispatch SKIPPED (--no-dispatch)");
    } else {
        runDispatch(ctx, n, max, kb_root, dry_run) catch |e| {
            try ctx.stderr.print(
                "[tick {d}] step 7 dispatch error: {t} (continuing to step 10)\n",
                .{ n, e },
            );
            try ctx.stderr.flush();
        };
    }

    // Step 10: finish. Writes the post-snapshot.
    runFinish(ctx, n, max, kb_root, bin_dir, &tick_id) catch |e| {
        try ctx.stderr.print(
            "[tick {d}] step 10 finish error: {t}\n",
            .{ n, e },
        );
        try ctx.stderr.flush();
    };

    try logTick(ctx, n, max, "complete");
}

const tick_id_len = 26;
const TickId = [tick_id_len]u8;

fn runBegin(
    ctx: *common.Context,
    n: u32,
    max: ?u32,
    kb_root: []const u8,
    bin_dir: []const u8,
) !TickId {
    const argv = try buildArgv(ctx.arena, &.{
        bin_dir, "/praescientia-ticks",
    }, &.{
        "begin",
        "--kb-root=", kb_root,
    });

    const r = try runCmd(ctx, argv);
    if (r.exit != 0) {
        try logTickStep(ctx, n, max, 1, "begin: non-zero exit");
        return error.BeginFailed;
    }

    // begin prints the 26-char ULID to stdout (followed by newline).
    const out_trimmed = std.mem.trim(u8, r.stdout, " \r\n\t");
    if (out_trimmed.len != tick_id_len) {
        try logTickStep(ctx, n, max, 1, "begin: stdout did not contain a 26-char ULID");
        return error.BadTickId;
    }
    var tick_id: TickId = undefined;
    @memcpy(&tick_id, out_trimmed);

    if (max) |m| {
        try ctx.stdout.print("[tick {d}/{d}] step  1: begin OK tick_id={s}\n", .{ n, m, &tick_id });
    } else {
        try ctx.stdout.print("[tick {d}] step  1: begin OK tick_id={s}\n", .{ n, &tick_id });
    }
    try ctx.stdout.flush();
    return tick_id;
}

fn runPoll(
    ctx: *common.Context,
    n: u32,
    max: ?u32,
    kb_root: []const u8,
    bin_dir: []const u8,
) !void {
    const argv = try buildArgv(ctx.arena, &.{
        bin_dir, "/praescientia-poll-markets",
    }, &.{
        "--kb-root=", kb_root,
        "--demo",
    });

    const r = try runCmd(ctx, argv);
    // poll-markets returns 0 even with per-market errors; the summary is
    // on stdout (e.g. "polled N markets, M errors"). Log the trimmed
    // summary.
    const summary = firstLine(r.stdout);
    try logTickStep(ctx, n, max, 4, summary);
    if (r.exit != 0) return error.PollFailed;
}

fn runSettle(
    ctx: *common.Context,
    n: u32,
    max: ?u32,
    kb_root: []const u8,
    bin_dir: []const u8,
) !void {
    const cursor_path = try std.fmt.allocPrint(
        ctx.arena,
        "{s}/.ticks/.last_settlement.json",
        .{kb_root},
    );
    const since_flag = try std.fmt.allocPrint(
        ctx.arena,
        "--since-cursor-file={s}",
        .{cursor_path},
    );

    // Build the argv manually — settlements is a subcommand, not a
    // path-suffix, so the prefix-join helper doesn't fit.
    var av = std.array_list.Managed([]const u8).init(ctx.arena);
    const bin_path = try std.fmt.allocPrint(ctx.arena, "{s}/praescientia-portfolio", .{bin_dir});
    try av.append(bin_path);
    try av.append("settlements");
    try av.append("--demo");
    try av.append(since_flag);

    const r = try runCmd(ctx, av.items);
    if (r.exit != 0) {
        try logTickStep(ctx, n, max, 5, "settle: non-zero exit (Kalshi may be down; continuing)");
        return;
    }
    // The response is JSON; report empty-page vs. page-received without
    // trying to parse it. Operators read kb/.ticks/.last_settlement.json
    // for substantive content.
    if (std.mem.indexOf(u8, r.stdout, "\"settlements\": []") != null or
        std.mem.indexOf(u8, r.stdout, "\"settlements\":[]") != null)
    {
        try logTickStep(ctx, n, max, 5, "settle: empty page (no new settlements)");
    } else {
        if (max) |m| {
            try ctx.stdout.print(
                "[tick {d}/{d}] step  5: settle: received {d} bytes of response\n",
                .{ n, m, r.stdout.len },
            );
        } else {
            try ctx.stdout.print(
                "[tick {d}] step  5: settle: received {d} bytes of response\n",
                .{ n, r.stdout.len },
            );
        }
        try ctx.stdout.flush();
    }
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

fn runFinish(
    ctx: *common.Context,
    n: u32,
    max: ?u32,
    kb_root: []const u8,
    bin_dir: []const u8,
    tick_id: *const TickId,
) !void {
    const tick_flag = try std.fmt.allocPrint(ctx.arena, "--tick-id={s}", .{tick_id});
    const kb_flag = try std.fmt.allocPrint(ctx.arena, "--kb-root={s}", .{kb_root});
    const bin_path = try std.fmt.allocPrint(ctx.arena, "{s}/praescientia-ticks", .{bin_dir});

    var av = std.array_list.Managed([]const u8).init(ctx.arena);
    try av.append(bin_path);
    try av.append("finish");
    try av.append(kb_flag);
    try av.append(tick_flag);

    const r = try runCmd(ctx, av.items);
    if (r.exit != 0) {
        try logTickStep(ctx, n, max, 10, "finish: non-zero exit");
        return error.FinishFailed;
    }
    const summary = firstLine(r.stderr);
    if (summary.len > 0) {
        try logTickStep(ctx, n, max, 10, summary);
    } else {
        try logTickStep(ctx, n, max, 10, "finish OK (post.json written)");
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

/// Build argv by joining a `prefix` path-parts list and appending `suffix`
/// args. The prefix is joined with no separator (so caller controls slash
/// placement); the suffix args are passed through as-is. Useful for
/// `["bin_dir", "/tool"]` + `["subcommand", "--flag=", "value"]`.
fn buildArgv(
    arena: std.mem.Allocator,
    prefix: []const []const u8,
    suffix: []const []const u8,
) ![]const []const u8 {
    var out = std.array_list.Managed([]const u8).init(arena);
    var joined = std.array_list.Managed(u8).init(arena);
    for (prefix) |p| try joined.appendSlice(p);
    try out.append(try joined.toOwnedSlice());

    // Join consecutive "--flag=" and "value" pairs into a single arg.
    var i: usize = 0;
    while (i < suffix.len) : (i += 1) {
        const a = suffix[i];
        if (std.mem.endsWith(u8, a, "=") and i + 1 < suffix.len) {
            const flag = try std.fmt.allocPrint(arena, "{s}{s}", .{ a, suffix[i + 1] });
            try out.append(flag);
            i += 1;
        } else {
            try out.append(a);
        }
    }
    return out.items;
}

/// Simpler shape — caller passes everything as-is. Kept around for
/// callers that don't want the "--flag=" + "value" join behavior of
/// buildArgv. Currently unused (settle's call site builds its argv
/// directly) but retained for symmetry.
fn buildArgvList(arena: std.mem.Allocator, parts: []const []const u8) ![]const []const u8 {
    var out = std.array_list.Managed([]const u8).init(arena);
    var joined = std.array_list.Managed(u8).init(arena);
    for (parts) |p| try joined.appendSlice(p);
    try out.append(try joined.toOwnedSlice());
    return out.items;
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

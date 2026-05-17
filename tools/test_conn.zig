//! End-to-end demo API smoke check.
//!
//! Hits every Kalshi endpoint implemented in `src/kalshi/*.zig` against the
//! live demo (or live) API and asserts each returns a 2xx. Loads credentials
//! from `.secret/kalshi_api_key_{id,private}.txt` when needed; public
//! endpoints work without them.
//!
//! Exit codes:
//!   0  every endpoint OK
//!   1  one or more endpoints failed
//!   2  argument / config error
//!
//! Usage:
//!   praescientia-test-conn [--env=demo|live] [--verbose]

const std = @import("std");
const praescientia = @import("praescientia");
const kalshi = praescientia.kalshi;

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    const arena_alloc = init.arena.allocator();

    var stderr_buf: [4096]u8 = undefined;
    var stderr_w = std.Io.File.stderr().writer(io, &stderr_buf);
    const stderr = &stderr_w.interface;
    defer stderr.flush() catch {};

    var stdout_buf: [4096]u8 = undefined;
    var stdout_w = std.Io.File.stdout().writer(io, &stdout_buf);
    const stdout = &stdout_w.interface;
    defer stdout.flush() catch {};

    const argv = try init.minimal.args.toSlice(arena_alloc);

    var env: kalshi.client.Env = .demo;
    var verbose = false;
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "--env=demo")) {
            env = .demo;
        } else if (std.mem.eql(u8, a, "--env=live")) {
            env = .live;
        } else if (std.mem.eql(u8, a, "--verbose") or std.mem.eql(u8, a, "-v")) {
            verbose = true;
        } else if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            try stderr.print(
                \\test-conn — smoke-check Kalshi demo/live endpoints
                \\
                \\Options:
                \\  --env=demo (default) | --env=live
                \\  --verbose / -v
                \\
                \\
            , .{});
            return 0;
        } else {
            try stderr.print("unknown argument: {s}\n", .{a});
            return 2;
        }
    }

    // Credentials are optional for the public endpoints we cover today;
    // missing files are a warning, not a fatal.
    const key_id = readFileTrimmed(io, gpa, ".secret/kalshi_api_key_id.txt") catch null;
    defer if (key_id) |k| gpa.free(k);
    const pem = readFileTrimmed(io, gpa, ".secret/kalshi_api_key_private.txt") catch null;
    defer if (pem) |p| gpa.free(p);

    if (verbose) {
        try stderr.print("env:         {s}\n", .{@tagName(env)});
        try stderr.print("credentials: {s}\n", .{if (key_id != null and pem != null) "yes" else "no (public-only)"});
    }

    var client = kalshi.client.Client.init(gpa, io, .{
        .env = env,
        .key_id = key_id,
        .private_key_pem = pem,
    });
    defer client.deinit();

    var failed: u32 = 0;
    var passed: u32 = 0;

    failed += try runCheck(stdout, gpa, &client, "exchange.status", checkExchangeStatus);
    passed += if (failed == 0) 1 else 0;
    failed += try runCheck(stdout, gpa, &client, "exchange.schedule", checkExchangeSchedule);
    passed += if (failed == 0) 1 else 0;
    failed += try runCheck(stdout, gpa, &client, "exchange.announcements", checkExchangeAnnouncements);
    passed += if (failed == 0) 1 else 0;

    try stdout.print("\n{d} passed, {d} failed\n", .{ passed, failed });
    return if (failed == 0) 0 else 1;
}

const CheckFn = *const fn (arena: std.mem.Allocator, client: *kalshi.client.Client) anyerror!void;

fn runCheck(
    out: *std.Io.Writer,
    gpa: std.mem.Allocator,
    client: *kalshi.client.Client,
    name: []const u8,
    check: CheckFn,
) !u32 {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    if (check(arena.allocator(), client)) |_| {
        try out.print("  OK   {s}\n", .{name});
        return 0;
    } else |err| {
        try out.print("  FAIL {s}  ({s})\n", .{ name, @errorName(err) });
        return 1;
    }
}

fn checkExchangeStatus(arena: std.mem.Allocator, client: *kalshi.client.Client) anyerror!void {
    const s = try kalshi.exchange.status(client, arena);
    // exchange_active flips at maintenance; the only invariant is that we
    // got *some* boolean back, which the type system already gives us.
    _ = s;
}

fn checkExchangeSchedule(arena: std.mem.Allocator, client: *kalshi.client.Client) anyerror!void {
    const v = try kalshi.exchange.schedule(client, arena);
    _ = v.object.get("schedule") orelse return error.MissingSchedule;
}

fn checkExchangeAnnouncements(arena: std.mem.Allocator, client: *kalshi.client.Client) anyerror!void {
    const v = try kalshi.exchange.announcements(client, arena);
    _ = v.object.get("announcements") orelse return error.MissingAnnouncements;
}

fn readFileTrimmed(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    var read_buf: [4096]u8 = undefined;
    var reader = file.reader(io, &read_buf);
    var list: std.array_list.Managed(u8) = .init(allocator);
    errdefer list.deinit();
    while (true) {
        const chunk = reader.interface.peek(1) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (chunk.len == 0) break;
        try list.appendSlice(chunk);
        reader.interface.toss(chunk.len);
    }
    const raw = try list.toOwnedSlice();
    const trimmed = std.mem.trim(u8, raw, " \r\n\t");
    // Preserve only the trimmed portion; shrink via dupe + free.
    const out = try allocator.dupe(u8, trimmed);
    allocator.free(raw);
    return out;
}

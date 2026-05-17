//! Shared scaffolding for the `praescientia-*` CLI tools.
//!
//! Every tool's `main` is a 5-line list of subcommands; this module owns:
//!   - global flag parsing (`--demo` default, `--live`, `--verbose`, `--help`)
//!   - credential loading from `.secret/` (optional — public endpoints work without)
//!   - `Client` construction
//!   - stdout / stderr writer setup (Zig 0.16's Io-bound File.Writer)
//!   - pretty-printed JSON output matching Julia's `JSON3.pretty` shape

const std = @import("std");
const praescientia = @import("praescientia");

pub const kalshi = praescientia.kalshi;
pub const Client = kalshi.client.Client;

pub const Context = struct {
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: std.Io,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    /// Subcommand-and-after argv. `args[0]` is the subcommand name.
    args: []const [:0]const u8,
    env: kalshi.client.Env,
    verbose: bool,
    client: *Client,

    /// Lookup `--flag=VALUE` style argument, returning the VALUE or null.
    pub fn flagValue(self: *const Context, name: []const u8) ?[]const u8 {
        const prefix = std.fmt.allocPrint(self.arena, "{s}=", .{name}) catch return null;
        for (self.args[1..]) |a| {
            if (std.mem.startsWith(u8, a, prefix)) return a[prefix.len..];
        }
        return null;
    }

    /// Positional argument at index `i` (0 = first after subcommand).
    pub fn positional(self: *const Context, i: usize) ?[]const u8 {
        var count: usize = 0;
        for (self.args[1..]) |a| {
            if (std.mem.startsWith(u8, a, "--")) continue;
            if (count == i) return a;
            count += 1;
        }
        return null;
    }
};

pub const Subcommand = struct {
    name: []const u8,
    description: []const u8,
    /// Return value is the process exit code.
    run: *const fn (ctx: *Context) anyerror!u8,
};

/// Entry point — call from each tool's `pub fn main(init)`.
pub fn runMain(
    init: std.process.Init,
    program_name: []const u8,
    subcommands: []const Subcommand,
) !u8 {
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

    // First pass: pluck global flags. Build a filtered subcommand-argv.
    var env: kalshi.client.Env = .demo;
    var verbose = false;
    var want_help = false;
    var filtered: std.array_list.Managed([:0]const u8) = .init(arena_alloc);

    for (argv[1..]) |a| {
        if (std.mem.eql(u8, a, "--demo")) {
            env = .demo;
        } else if (std.mem.eql(u8, a, "--live")) {
            env = .live;
        } else if (std.mem.eql(u8, a, "--verbose") or std.mem.eql(u8, a, "-v")) {
            verbose = true;
        } else if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            want_help = true;
        } else {
            try filtered.append(a);
        }
    }

    if (want_help or filtered.items.len == 0) {
        try printUsage(stderr, program_name, subcommands);
        return if (want_help) 0 else 2;
    }

    const cmd_name = filtered.items[0];
    var matched: ?Subcommand = null;
    for (subcommands) |sc| {
        if (std.mem.eql(u8, sc.name, cmd_name)) {
            matched = sc;
            break;
        }
    }
    if (matched == null) {
        try stderr.print("unknown subcommand: {s}\n\n", .{cmd_name});
        try printUsage(stderr, program_name, subcommands);
        return 2;
    }

    // Credentials — optional. Failure to read is silently treated as "no creds".
    const key_id = readFileTrimmed(io, gpa, ".secret/kalshi_api_key_id.txt") catch null;
    defer if (key_id) |k| gpa.free(k);
    const pem = readFileTrimmed(io, gpa, ".secret/kalshi_api_key_private.txt") catch null;
    defer if (pem) |p| gpa.free(p);

    if (verbose) {
        try stderr.print("env:         {s}\n", .{@tagName(env)});
        try stderr.print("credentials: {s}\n", .{if (key_id != null and pem != null) "yes" else "no"});
        try stderr.print("subcommand:  {s}\n", .{cmd_name});
        try stderr.flush();
    }

    var client = Client.init(gpa, io, .{
        .env = env,
        .key_id = key_id,
        .private_key_pem = pem,
    });
    defer client.deinit();

    var ctx: Context = .{
        .gpa = gpa,
        .arena = arena_alloc,
        .io = io,
        .stdout = stdout,
        .stderr = stderr,
        .args = filtered.items,
        .env = env,
        .verbose = verbose,
        .client = &client,
    };
    return matched.?.run(&ctx);
}

fn printUsage(out: *std.Io.Writer, program_name: []const u8, subcommands: []const Subcommand) !void {
    try out.print("Usage: {s} <command> [options]\n\nCommands:\n", .{program_name});
    for (subcommands) |sc| try out.print("  {s:<30}{s}\n", .{ sc.name, sc.description });
    try out.print(
        \\
        \\Global options:
        \\  --demo     Use the Kalshi demo environment (default)
        \\  --live     Use the Kalshi live environment
        \\  --verbose  Print request/response debug info to stderr
        \\  --help     Show this message
        \\
    , .{});
}

/// Pretty-print a Zig value as JSON (2-space indent), trailing newline.
/// Matches the shape of Julia's `JSON3.pretty(JSON3.write(value))`.
pub fn printJson(value: anytype, out: *std.Io.Writer) !void {
    try std.json.Stringify.value(value, .{ .whitespace = .indent_2 }, out);
    try out.print("\n", .{});
}

/// Read a file fully, trim surrounding whitespace, return owned bytes.
pub fn readFileTrimmed(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
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
    const out = try allocator.dupe(u8, trimmed);
    allocator.free(raw);
    return out;
}

test "Context.flagValue extracts --key=value" {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa_state.allocator());
    defer arena.deinit();

    const args = [_][:0]const u8{ "list", "--series_ticker=KXFOO", "--limit=5" };
    var dummy_client: Client = undefined;
    var ctx: Context = .{
        .gpa = gpa_state.allocator(),
        .arena = arena.allocator(),
        .io = undefined,
        .stdout = undefined,
        .stderr = undefined,
        .args = &args,
        .env = .demo,
        .verbose = false,
        .client = &dummy_client,
    };
    try std.testing.expectEqualStrings("KXFOO", ctx.flagValue("--series_ticker").?);
    try std.testing.expectEqualStrings("5", ctx.flagValue("--limit").?);
    try std.testing.expectEqual(@as(?[]const u8, null), ctx.flagValue("--missing"));
}

test "Context.positional skips flags" {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa_state.allocator());
    defer arena.deinit();

    const args = [_][:0]const u8{ "get", "--verbose", "TICKER-1", "--limit=10", "extra" };
    var dummy_client: Client = undefined;
    var ctx: Context = .{
        .gpa = gpa_state.allocator(),
        .arena = arena.allocator(),
        .io = undefined,
        .stdout = undefined,
        .stderr = undefined,
        .args = &args,
        .env = .demo,
        .verbose = false,
        .client = &dummy_client,
    };
    try std.testing.expectEqualStrings("TICKER-1", ctx.positional(0).?);
    try std.testing.expectEqualStrings("extra", ctx.positional(1).?);
    try std.testing.expectEqual(@as(?[]const u8, null), ctx.positional(2));
}

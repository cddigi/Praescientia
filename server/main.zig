//! praescientia-server — single-binary dashboard server.
//!
//! Embeds `web/dashboard.html` via `@embedFile`, listens on TCP, and proxies
//! `/api/kalshi/*` requests through `src/kalshi/*` to the live Kalshi API.
//! Routing + handlers live in `server/handlers.zig`. Concurrency is provided
//! by 0.16's `Io.Threaded` — each accepted connection runs in its own task
//! via `Io.async`.

const std = @import("std");
const handlers = @import("handlers.zig");
const praescientia = @import("praescientia");
const kalshi = praescientia.kalshi;

test {
    // Surface inline tests in handlers.zig.
    _ = handlers;
}

const Allocator = std.mem.Allocator;
const Io = std.Io;

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

    var port: u16 = 8080;
    var env: kalshi.client.Env = .demo;
    var verbose = false;
    var kb_root_path: ?[]const u8 = null;

    for (argv[1..]) |a| {
        if (std.mem.startsWith(u8, a, "--port=")) {
            port = std.fmt.parseInt(u16, a["--port=".len..], 10) catch {
                try stderr.print("invalid --port value: {s}\n", .{a["--port=".len..]});
                return 2;
            };
        } else if (std.mem.startsWith(u8, a, "--kb-root=")) {
            kb_root_path = a["--kb-root=".len..];
        } else if (std.mem.eql(u8, a, "--live")) {
            env = .live;
        } else if (std.mem.eql(u8, a, "--demo")) {
            env = .demo;
        } else if (std.mem.eql(u8, a, "--verbose") or std.mem.eql(u8, a, "-v")) {
            verbose = true;
        } else if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            try stderr.print(
                \\Usage: praescientia-server [--port=N] [--demo|--live] [--kb-root=PATH] [--verbose]
                \\
                \\Defaults: --port=8080 --demo  (kb routes disabled until --kb-root is set)
                \\
                \\Dashboard is served at http://localhost:<port>/.
                \\API routes live under /api/kalshi/* and /api/kb/* (when --kb-root is set).
                \\
            , .{});
            return 0;
        }
    }

    const key_id = readFileTrimmed(io, gpa, ".secret/kalshi_api_key_id.txt") catch null;
    defer if (key_id) |k| gpa.free(k);
    const pem = readFileTrimmed(io, gpa, ".secret/kalshi_api_key_private.txt") catch null;
    defer if (pem) |p| gpa.free(p);

    var client = kalshi.client.Client.init(gpa, io, .{
        .env = env,
        .key_id = key_id,
        .private_key_pem = pem,
    });
    defer client.deinit();

    const bind_addr = std.Io.net.IpAddress{ .ip4 = .{ .bytes = .{ 0, 0, 0, 0 }, .port = port } };
    var listener = bind_addr.listen(io, .{}) catch |e| {
        try stderr.print("failed to listen on 0.0.0.0:{d}: {s}\n", .{ port, @errorName(e) });
        return 1;
    };
    defer listener.socket.close(io);

    try stdout.print(
        \\============================================================
        \\           PRAESCIENTIA — KALSHI DASHBOARD
        \\                Zig std.http.Server
        \\============================================================
        \\  Environment:  {s}
        \\  Server:       http://localhost:{d}
        \\  Dashboard:    http://localhost:{d}/
        \\  Credentials:  {s}
        \\  KB root:      {s}
        \\============================================================
        \\
    , .{
        if (env == .demo) "DEMO" else "LIVE",
        port,
        port,
        if (key_id != null and pem != null) "yes" else "public-only",
        kb_root_path orelse "(disabled)",
    });
    try stdout.flush();

    // Accept loop. Each connection is dispatched to a task via Io.async so
    // long-running Kalshi calls don't block subsequent requests.
    while (true) {
        const stream = listener.accept(io) catch |e| {
            try stderr.print("accept failed: {s}\n", .{@errorName(e)});
            try stderr.flush();
            continue;
        };
        _ = Io.async(io, handleConnection, .{ gpa, io, &client, stream, verbose, kb_root_path });
    }
}

fn handleConnection(
    gpa: Allocator,
    io: Io,
    client: *kalshi.client.Client,
    stream: std.Io.net.Stream,
    verbose: bool,
    kb_root_path: ?[]const u8,
) void {
    defer stream.close(io);

    var read_buf: [16 * 1024]u8 = undefined;
    var write_buf: [16 * 1024]u8 = undefined;
    var stream_reader = stream.reader(io, &read_buf);
    var stream_writer = stream.writer(io, &write_buf);

    var server: std.http.Server = .init(&stream_reader.interface, &stream_writer.interface);

    while (true) {
        var request = server.receiveHead() catch break;
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();

        handleRequest(arena.allocator(), io, client, &request, verbose, kb_root_path) catch |e| {
            if (verbose) std.debug.print("handler error: {s}\n", .{@errorName(e)});
            // Bail on this connection; client will reconnect.
            break;
        };

        if (!request.head.keep_alive) break;
    }
}

fn handleRequest(
    arena: Allocator,
    io: Io,
    client: *kalshi.client.Client,
    request: *std.http.Server.Request,
    verbose: bool,
    kb_root_path: ?[]const u8,
) !void {
    const target = request.head.target;
    const method = request.head.method;
    const path_end = std.mem.indexOfScalar(u8, target, '?') orelse target.len;
    const path = target[0..path_end];
    const query = if (path_end < target.len) target[path_end + 1 ..] else "";

    if (verbose) std.debug.print("{s} {s}\n", .{ @tagName(method), target });

    // Preflight CORS short-circuits before the route table.
    if (method == .OPTIONS) {
        try request.respond("", .{
            .status = .ok,
            .extra_headers = &.{
                .{ .name = "access-control-allow-origin", .value = "*" },
                .{ .name = "access-control-allow-methods", .value = "GET, POST, PUT, DELETE, OPTIONS" },
                .{ .name = "access-control-allow-headers", .value = "Content-Type" },
            },
            .keep_alive = true,
        });
        return;
    }

    var params: [handlers.max_path_params][]const u8 = undefined;
    const hit = handlers.match(method, path, &params) orelse {
        try request.respond("{\"success\":false,\"error\":\"route not found\"}", .{
            .status = .not_found,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "application/json" },
                .{ .name = "access-control-allow-origin", .value = "*" },
            },
            .keep_alive = true,
        });
        return;
    };

    var ctx: handlers.RequestCtx = .{
        .arena = arena,
        .io = io,
        .client = client,
        .request = request,
        .path = path,
        .query = query,
        .params = params,
        .param_count = hit.param_count,
        .kb_root_path = kb_root_path,
    };
    try hit.route.handler(&ctx);
}

fn readFileTrimmed(io: Io, allocator: Allocator, path: []const u8) ![]u8 {
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

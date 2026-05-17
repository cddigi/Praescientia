//! Stage 1 risk-reduction binary.
//!
//! Reads a PEM private key, signs a message with RSA-PSS (SHA-256, MGF1-SHA256,
//! salt = digest length), and prints the base64 signature on stdout.
//!
//! Usage:
//!   signtest [--key PATH] [--message STR | --message-file PATH | --stdin] [--verbose]
//!
//! Defaults:
//!   --key      .secret/kalshi_api_key_private.txt
//!   --message  "1700000000000GET/trade-api/v2/exchange/status"
//!
//! Used to cross-verify Zig signing against Julia's KalshiAuth.rsa_pss_sign and
//! against `openssl pkeyutl -verify -pkeyopt rsa_padding_mode:pss`.

const std = @import("std");
const auth = @import("praescientia").kalshi.auth;

const default_key_path = ".secret/kalshi_api_key_private.txt";
const default_message = "1700000000000GET/trade-api/v2/exchange/status";

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();

    var stderr_buf: [4096]u8 = undefined;
    var stderr_w = std.Io.File.stderr().writer(io, &stderr_buf);
    const stderr = &stderr_w.interface;
    defer stderr.flush() catch {};

    var stdout_buf: [4096]u8 = undefined;
    var stdout_w = std.Io.File.stdout().writer(io, &stdout_buf);
    const stdout = &stdout_w.interface;
    defer stdout.flush() catch {};

    const argv = try init.minimal.args.toSlice(arena);

    var key_path: []const u8 = default_key_path;
    var message: []const u8 = default_message;
    var verbose = false;

    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            try usage(stderr);
            return 0;
        } else if (std.mem.eql(u8, a, "--verbose") or std.mem.eql(u8, a, "-v")) {
            verbose = true;
        } else if (std.mem.eql(u8, a, "--key")) {
            i += 1;
            if (i >= argv.len) {
                try stderr.print("--key requires an argument\n", .{});
                return 2;
            }
            key_path = argv[i];
        } else if (std.mem.eql(u8, a, "--message")) {
            i += 1;
            if (i >= argv.len) {
                try stderr.print("--message requires an argument\n", .{});
                return 2;
            }
            message = argv[i];
        } else if (std.mem.eql(u8, a, "--message-file")) {
            i += 1;
            if (i >= argv.len) {
                try stderr.print("--message-file requires an argument\n", .{});
                return 2;
            }
            message = try readFile(io, arena, argv[i]);
        } else if (std.mem.eql(u8, a, "--stdin")) {
            message = try readStdin(io, arena);
        } else {
            try stderr.print("unknown argument: {s}\n", .{a});
            try usage(stderr);
            return 2;
        }
    }

    const pem = readFile(io, gpa, key_path) catch |err| {
        try stderr.print("failed to read '{s}': {s}\n", .{ key_path, @errorName(err) });
        return 1;
    };
    defer gpa.free(pem);

    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(message, &digest, .{});

    if (verbose) {
        try stderr.print("key:          {s}\n", .{key_path});
        try stderr.print("message_len:  {d}\n", .{message.len});
        try stderr.print("sha256(msg):  ", .{});
        for (digest) |b| try stderr.print("{x:0>2}", .{b});
        try stderr.print("\n", .{});
    }

    const sig_b64 = auth.signDigest(gpa, pem, &digest) catch |err| {
        try stderr.print("sign failed: {s}\n", .{@errorName(err)});
        return 1;
    };
    defer gpa.free(sig_b64);

    try stdout.print("{s}\n", .{sig_b64});
    return 0;
}

fn usage(stderr: *std.Io.Writer) !void {
    try stderr.print(
        \\signtest — RSA-PSS sign a message with a Kalshi private key
        \\
        \\Usage:
        \\  signtest [--key PATH] [--message STR | --message-file PATH | --stdin] [--verbose]
        \\
        \\Defaults:
        \\  --key      {s}
        \\  --message  {s}
        \\
        \\
    , .{ default_key_path, default_message });
}

fn readFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const cwd = std.Io.Dir.cwd();
    var file = try cwd.openFile(io, path, .{});
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
    return list.toOwnedSlice();
}

fn readStdin(io: std.Io, allocator: std.mem.Allocator) ![]u8 {
    var read_buf: [4096]u8 = undefined;
    var reader = std.Io.File.stdin().reader(io, &read_buf);
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
    return list.toOwnedSlice();
}

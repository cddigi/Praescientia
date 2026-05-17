//! Stage 1 risk-reduction verifier.
//!
//! Reads a PEM public key, a message, and a base64 RSA-PSS signature; exits 0
//! if the signature verifies (RSA-SHA256, MGF1-SHA256, salt = digest length).
//!
//! Usage:
//!   verifytest --pubkey PATH --signature PATH [--message STR | --message-file PATH]
//!
//! Used by scripts/cross_verify.sh to confirm OpenSSL-produced signatures
//! (equivalent to Julia's KalshiAuth output) round-trip through Zig.

const std = @import("std");
const auth = @import("praescientia").kalshi.auth;

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

    var pubkey_path: ?[]const u8 = null;
    var sig_path: ?[]const u8 = null;
    var message: []const u8 = "1700000000000GET/trade-api/v2/exchange/status";

    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "--pubkey")) {
            i += 1;
            pubkey_path = argv[i];
        } else if (std.mem.eql(u8, a, "--signature")) {
            i += 1;
            sig_path = argv[i];
        } else if (std.mem.eql(u8, a, "--message")) {
            i += 1;
            message = argv[i];
        } else if (std.mem.eql(u8, a, "--message-file")) {
            i += 1;
            message = try readFile(io, arena, argv[i]);
        } else {
            try stderr.print("unknown argument: {s}\n", .{a});
            return 2;
        }
    }

    const pubkey_p = pubkey_path orelse {
        try stderr.print("--pubkey is required\n", .{});
        return 2;
    };
    const sig_p = sig_path orelse {
        try stderr.print("--signature is required\n", .{});
        return 2;
    };

    const pubkey = try readFile(io, gpa, pubkey_p);
    defer gpa.free(pubkey);

    const sig_b64_raw = try readFile(io, gpa, sig_p);
    defer gpa.free(sig_b64_raw);
    // Strip trailing newline if present.
    const sig_b64 = std.mem.trim(u8, sig_b64_raw, " \r\n\t");

    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(message, &digest, .{});

    const ok = auth.verifyDigest(gpa, pubkey, &digest, sig_b64) catch |err| {
        try stderr.print("verify failed: {s}\n", .{@errorName(err)});
        return 1;
    };

    if (ok) {
        try stdout.print("OK\n", .{});
        return 0;
    } else {
        try stdout.print("FAIL\n", .{});
        return 1;
    }
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

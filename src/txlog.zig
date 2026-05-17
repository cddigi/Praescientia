//! JSONL transaction log with chained hashes — persistent backing for
//! `state_chain.Chain`. Each line is a self-describing tx record; the chain
//! integrity is recoverable from the file alone.
//!
//! Wire format (one record per line):
//!   {"tx_id":"tx_<26-char Crockford ULID>",
//!    "prev_hash":"<64 hex chars>",
//!    "hash":"<64 hex chars>",
//!    "payload":<canonical JSON>}
//!
//! - `hash` is SHA-256 over the canonical JSON bytes of `payload`.
//! - `prev_hash` is the previous record's `hash`. Genesis = 64 zeros.
//! - `tx_id` is "tx_" + a 26-char Crockford-base32 ULID (48-bit ms timestamp
//!   followed by 80 bits of CSPRNG randomness).

const std = @import("std");

const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;
const canonical = @import("canonical_json.zig");
const state_chain = @import("state_chain.zig");

pub const Hash = state_chain.Hash;
pub const hash_len = Sha256.digest_length;
pub const hash_hex_len = hash_len * 2;
pub const tx_id_len = 29; // "tx_" (3) + ULID (26)
pub const zero_hash: Hash = @splat(0);

pub const Tx = struct {
    tx_id: [tx_id_len]u8,
    prev_hash: Hash,
    hash: Hash,
    /// Canonical JSON bytes. TxLog owns this allocation.
    payload: []u8,
};

pub const TxLog = struct {
    allocator: Allocator,
    items: std.array_list.Managed(Tx),

    pub fn init(allocator: Allocator) TxLog {
        return .{ .allocator = allocator, .items = .init(allocator) };
    }

    pub fn deinit(self: *TxLog) void {
        for (self.items.items) |item| self.allocator.free(item.payload);
        self.items.deinit();
    }

    pub fn len(self: *const TxLog) usize {
        return self.items.items.len;
    }

    /// Append a tx. `payload_json` may be any JSON; it is canonicalized before
    /// hashing so that semantically equivalent inputs produce stable hashes.
    pub fn append(self: *TxLog, payload_json: []const u8) !*const Tx {
        const canon = try canonical.encodeSlice(self.allocator, payload_json);
        errdefer self.allocator.free(canon);

        var hash: Hash = undefined;
        Sha256.hash(canon, &hash, .{});

        const prev_hash: Hash = if (self.items.items.len == 0)
            zero_hash
        else
            self.items.items[self.items.items.len - 1].hash;

        var tx_id: [tx_id_len]u8 = undefined;
        generateTxId(&tx_id);

        try self.items.append(.{
            .tx_id = tx_id,
            .prev_hash = prev_hash,
            .hash = hash,
            .payload = canon,
        });
        return &self.items.items[self.items.items.len - 1];
    }

    /// Emit the log as JSONL.
    pub fn writeAll(self: *const TxLog, writer: *std.Io.Writer) !void {
        for (self.items.items) |tx| {
            var prev_hex: [hash_hex_len]u8 = undefined;
            var hash_hex: [hash_hex_len]u8 = undefined;
            _ = std.fmt.bufPrint(&prev_hex, "{x}", .{tx.prev_hash}) catch unreachable;
            _ = std.fmt.bufPrint(&hash_hex, "{x}", .{tx.hash}) catch unreachable;

            try writer.print(
                "{{\"tx_id\":\"{s}\",\"prev_hash\":\"{s}\",\"hash\":\"{s}\",\"payload\":{s}}}\n",
                .{ tx.tx_id, prev_hex, hash_hex, tx.payload },
            );
        }
    }

    /// Parse a JSONL slice into a fresh TxLog, verifying hash/prev_hash chain.
    pub fn parseSlice(allocator: Allocator, jsonl: []const u8) !TxLog {
        var log: TxLog = .init(allocator);
        errdefer log.deinit();

        var prev: Hash = zero_hash;
        var first = true;

        var lines = std.mem.splitScalar(u8, jsonl, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \r\t");
            if (trimmed.len == 0) continue;

            const parsed = try std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{});
            defer parsed.deinit();

            const root = parsed.value;
            const tx_id_str = root.object.get("tx_id").?.string;
            const prev_hash_str = root.object.get("prev_hash").?.string;
            const hash_str = root.object.get("hash").?.string;
            const payload_val = root.object.get("payload").?;

            // Re-canonicalize the payload so we can hash it deterministically.
            var aw: std.Io.Writer.Allocating = .init(allocator);
            errdefer aw.deinit();
            try canonical.encodeValue(payload_val, &aw.writer, allocator);
            const canon = try aw.toOwnedSlice();
            errdefer allocator.free(canon);

            var computed: Hash = undefined;
            Sha256.hash(canon, &computed, .{});

            var stored: Hash = undefined;
            try hexDecode(hash_str, &stored);
            if (!std.mem.eql(u8, &computed, &stored)) return error.HashMismatch;

            var stored_prev: Hash = undefined;
            try hexDecode(prev_hash_str, &stored_prev);
            if (first) {
                if (!std.mem.eql(u8, &stored_prev, &zero_hash)) return error.GenesisPrevHashNonZero;
                first = false;
            } else if (!std.mem.eql(u8, &stored_prev, &prev)) {
                return error.PrevHashBroken;
            }
            prev = stored;

            if (tx_id_str.len != tx_id_len) return error.MalformedTxId;
            var tx_id_buf: [tx_id_len]u8 = undefined;
            @memcpy(&tx_id_buf, tx_id_str);

            try log.items.append(.{
                .tx_id = tx_id_buf,
                .prev_hash = stored_prev,
                .hash = stored,
                .payload = canon,
            });
        }

        return log;
    }

    /// Project this txlog into a state_chain.Chain. Caller owns the chain.
    pub fn toChain(self: *const TxLog, allocator: Allocator) !state_chain.Chain {
        var chain: state_chain.Chain = .init(allocator);
        errdefer chain.deinit();
        for (self.items.items) |tx| try chain.append(tx.payload);
        return chain;
    }
};

const crockford = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";

/// Writes `"tx_"` followed by a 26-char Crockford-base32 ULID into `out`.
/// 48-bit Unix-ms timestamp prefix + 80-bit CSPRNG randomness suffix.
pub fn generateTxId(out: *[tx_id_len]u8) void {
    out[0] = 't';
    out[1] = 'x';
    out[2] = '_';

    var raw: [16]u8 = undefined;
    const ms = millisSinceEpoch();
    raw[0] = @truncate(ms >> 40);
    raw[1] = @truncate(ms >> 32);
    raw[2] = @truncate(ms >> 24);
    raw[3] = @truncate(ms >> 16);
    raw[4] = @truncate(ms >> 8);
    raw[5] = @truncate(ms);
    fillRandom(raw[6..16]);

    var v: u128 = 0;
    for (raw) |b| v = (v << 8) | b;

    var i: usize = 26;
    while (i > 0) {
        i -= 1;
        const idx: usize = @intCast(v & 0x1f);
        out[3 + i] = crockford[idx];
        v >>= 5;
    }
}

/// Fill `out` with cryptographically-secure random bytes. Uses libc's
/// platform-native CSPRNG to avoid Zig 0.16's Io-dependent crypto APIs in a
/// context (tx_id generation) where threading Io through is more friction than
/// it's worth.
fn fillRandom(out: []u8) void {
    const native_os = @import("builtin").os.tag;
    switch (native_os) {
        .driverkit, .ios, .maccatalyst, .macos, .tvos, .visionos, .watchos, .freebsd, .netbsd, .openbsd, .dragonfly, .illumos => {
            std.c.arc4random_buf(out.ptr, out.len);
        },
        .linux, .emscripten => {
            // glibc 2.25+ / musl / Android exposes getentropy(3). Cap at 256 bytes per call.
            const getentropy = struct {
                extern "c" fn getentropy(buffer: [*]u8, size: usize) c_int;
            }.getentropy;
            var off: usize = 0;
            while (off < out.len) {
                const take = @min(out.len - off, @as(usize, 256));
                if (getentropy(out[off..].ptr, take) != 0) @panic("getentropy failed");
                off += take;
            }
        },
        else => @compileError("unsupported platform for fillRandom"),
    }
}

fn millisSinceEpoch() u64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.REALTIME, &ts);
    const sec: i128 = ts.sec;
    const nsec: i128 = ts.nsec;
    const ms: i128 = sec * 1000 + @divTrunc(nsec, 1_000_000);
    return if (ms < 0) 0 else @intCast(ms);
}

fn hexDecode(hex: []const u8, out: *Hash) !void {
    if (hex.len != hash_hex_len) return error.WrongHexLength;
    for (out, 0..) |*byte, i| {
        const hi = try hexNibble(hex[i * 2]);
        const lo = try hexNibble(hex[i * 2 + 1]);
        byte.* = (hi << 4) | lo;
    }
}

fn hexNibble(c: u8) !u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => 10 + c - 'a',
        'A'...'F' => 10 + c - 'A',
        else => error.InvalidHex,
    };
}

test "tx_id has tx_ prefix and is unique" {
    var a: [tx_id_len]u8 = undefined;
    var b: [tx_id_len]u8 = undefined;
    generateTxId(&a);
    generateTxId(&b);

    try std.testing.expectEqualStrings("tx_", a[0..3]);
    try std.testing.expectEqualStrings("tx_", b[0..3]);
    try std.testing.expectEqual(@as(usize, 29), a.len);
    try std.testing.expect(!std.mem.eql(u8, &a, &b));

    // ULID body must be Crockford-base32 chars only.
    for (a[3..]) |ch| {
        try std.testing.expect(std.mem.indexOfScalar(u8, crockford, ch) != null);
    }
}

test "hash_transaction is deterministic" {
    const allocator = std.testing.allocator;
    var log1: TxLog = .init(allocator);
    defer log1.deinit();
    var log2: TxLog = .init(allocator);
    defer log2.deinit();

    _ = try log1.append("{\"type\":\"BUY\",\"amount\":100}");
    _ = try log2.append("{\"amount\":100,\"type\":\"BUY\"}"); // same content, different order

    try std.testing.expectEqualSlices(u8, &log1.items.items[0].hash, &log2.items.items[0].hash);
}

test "prev_hash chains correctly" {
    const allocator = std.testing.allocator;
    var log: TxLog = .init(allocator);
    defer log.deinit();

    _ = try log.append("{\"v\":1}");
    _ = try log.append("{\"v\":2}");
    _ = try log.append("{\"v\":3}");

    try std.testing.expectEqualSlices(u8, &log.items.items[0].prev_hash, &zero_hash);
    try std.testing.expectEqualSlices(u8, &log.items.items[1].prev_hash, &log.items.items[0].hash);
    try std.testing.expectEqualSlices(u8, &log.items.items[2].prev_hash, &log.items.items[1].hash);
}

test "replay reconstructs chain" {
    const allocator = std.testing.allocator;
    var src: TxLog = .init(allocator);
    defer src.deinit();

    _ = try src.append("{\"type\":\"GENESIS\",\"name\":\"Test\"}");
    _ = try src.append("{\"type\":\"BUY\",\"shares\":100,\"price\":0.5}");
    _ = try src.append("{\"type\":\"BUY\",\"shares\":50,\"price\":0.6}");

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try src.writeAll(&aw.writer);

    var parsed = try TxLog.parseSlice(allocator, aw.written());
    defer parsed.deinit();

    try std.testing.expectEqual(src.len(), parsed.len());
    for (src.items.items, parsed.items.items) |a, b| {
        try std.testing.expectEqualStrings(&a.tx_id, &b.tx_id);
        try std.testing.expectEqualSlices(u8, &a.hash, &b.hash);
        try std.testing.expectEqualSlices(u8, &a.prev_hash, &b.prev_hash);
        try std.testing.expectEqualStrings(a.payload, b.payload);
    }

    var chain = try parsed.toChain(allocator);
    defer chain.deinit();
    try std.testing.expectEqual(src.len(), chain.len());
}

test "tampered payload is rejected by parseSlice" {
    const allocator = std.testing.allocator;
    var src: TxLog = .init(allocator);
    defer src.deinit();
    _ = try src.append("{\"v\":1}");

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try src.writeAll(&aw.writer);

    // Tamper: change the payload's value but keep the hash field intact.
    var tampered = try allocator.dupe(u8, aw.written());
    defer allocator.free(tampered);
    const needle = "\"v\":1";
    const idx = std.mem.indexOf(u8, tampered, needle).?;
    tampered[idx + needle.len - 1] = '9';

    try std.testing.expectError(error.HashMismatch, TxLog.parseSlice(allocator, tampered));
}

test "broken prev_hash chain is rejected" {
    const allocator = std.testing.allocator;

    // Build a real two-tx log, serialize it, then tamper with the *second*
    // line's prev_hash so parse-time chain verification trips.
    var src: TxLog = .init(allocator);
    defer src.deinit();
    _ = try src.append("{\"v\":1}");
    _ = try src.append("{\"v\":2}");

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try src.writeAll(&aw.writer);

    var tampered = try allocator.dupe(u8, aw.written());
    defer allocator.free(tampered);

    // Find the second occurrence of "prev_hash":" — that's record 2's prev_hash.
    const needle = "\"prev_hash\":\"";
    const first_at = std.mem.indexOf(u8, tampered, needle).?;
    const second_at = std.mem.indexOf(u8, tampered[first_at + needle.len ..], needle).? + first_at + needle.len;
    const hex_start = second_at + needle.len;
    // Overwrite the hex with a non-matching value.
    @memcpy(tampered[hex_start..][0..hash_hex_len], "deadbeef" ** 8);

    try std.testing.expectError(error.PrevHashBroken, TxLog.parseSlice(allocator, tampered));
}

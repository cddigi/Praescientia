//! Hashed checkpoint chain — the Hopper-doctrine core of Praescientia.
//!
//! Each item's `hash` is SHA-256(prev_item.hash || canonical_json_payload) —
//! a Merkle accumulator. Two chains with the same head hash are identical
//! (modulo SHA-256 collisions), so `divergesAt` short-circuits in O(1) on the
//! common case. When heads differ, a linear scan finds the first differing
//! index — letting us pinpoint *where* reality diverged from prediction
//! without reprocessing the whole context.

const std = @import("std");

const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const Hash = [Sha256.digest_length]u8;
pub const zero_hash: Hash = @splat(0);

pub const Item = struct {
    /// Canonical JSON bytes of the appended state. Chain owns this allocation.
    payload: []u8,
    /// Merkle accumulator: SHA-256(prev_item.hash || payload). prev is `zero_hash` for the head.
    hash: Hash,
};

pub const Chain = struct {
    allocator: Allocator,
    items: std.array_list.Managed(Item),

    pub fn init(allocator: Allocator) Chain {
        return .{
            .allocator = allocator,
            .items = .init(allocator),
        };
    }

    pub fn deinit(self: *Chain) void {
        for (self.items.items) |item| self.allocator.free(item.payload);
        self.items.deinit();
    }

    /// Append a canonical-JSON state. The chain takes ownership of a copy.
    pub fn append(self: *Chain, canonical_json: []const u8) !void {
        const owned = try self.allocator.dupe(u8, canonical_json);
        errdefer self.allocator.free(owned);

        const prev: Hash = if (self.items.items.len == 0)
            zero_hash
        else
            self.items.items[self.items.items.len - 1].hash;

        var hasher = Sha256.init(.{});
        hasher.update(&prev);
        hasher.update(owned);
        var hash: Hash = undefined;
        hasher.final(&hash);

        try self.items.append(.{ .payload = owned, .hash = hash });
    }

    pub fn len(self: *const Chain) usize {
        return self.items.items.len;
    }

    /// Head hash — the chain's current checkpoint identity. Null on an empty chain.
    pub fn checkpoint(self: *const Chain) ?Hash {
        if (self.items.items.len == 0) return null;
        return self.items.items[self.items.items.len - 1].hash;
    }

    /// First index at which `self` and `other` differ. Null if one is a prefix
    /// of the other AND lengths match. If lengths differ, the index of the
    /// first item present in the longer chain past the shorter is returned.
    ///
    /// Fast path: if both chains have the same head hash and same length, no
    /// linear scan happens.
    pub fn divergesAt(self: *const Chain, other: *const Chain) ?usize {
        const self_len = self.items.items.len;
        const other_len = other.items.items.len;
        const common = @min(self_len, other_len);

        // O(1) short-circuit on matching heads of matching length.
        if (self_len == other_len) {
            if (self_len == 0) return null;
            if (std.mem.eql(u8, &self.items.items[self_len - 1].hash, &other.items.items[other_len - 1].hash)) {
                return null;
            }
        }

        var i: usize = 0;
        while (i < common) : (i += 1) {
            if (!std.mem.eql(u8, &self.items.items[i].hash, &other.items.items[i].hash)) {
                return i;
            }
        }
        if (self_len == other_len) return null;
        return common;
    }
};

test "append produces stable hash" {
    const a = std.testing.allocator;
    var c1: Chain = .init(a);
    defer c1.deinit();
    var c2: Chain = .init(a);
    defer c2.deinit();

    try c1.append("{\"a\":1}");
    try c2.append("{\"a\":1}");

    try std.testing.expectEqual(@as(usize, 1), c1.len());
    try std.testing.expectEqualSlices(u8, &c1.items.items[0].hash, &c2.items.items[0].hash);
}

test "different payloads produce different hashes" {
    const a = std.testing.allocator;
    var c: Chain = .init(a);
    defer c.deinit();

    try c.append("{\"a\":1}");
    try c.append("{\"a\":2}");

    try std.testing.expect(!std.mem.eql(u8, &c.items.items[0].hash, &c.items.items[1].hash));
}

test "checkpoint returns head hash, null when empty" {
    const a = std.testing.allocator;
    var c: Chain = .init(a);
    defer c.deinit();

    try std.testing.expectEqual(@as(?Hash, null), c.checkpoint());

    try c.append("{\"v\":1}");
    try c.append("{\"v\":2}");
    const head = c.checkpoint().?;
    try std.testing.expectEqualSlices(u8, &head, &c.items.items[1].hash);
}

test "divergesAt returns null for identical chains" {
    const a = std.testing.allocator;
    var c1: Chain = .init(a);
    defer c1.deinit();
    var c2: Chain = .init(a);
    defer c2.deinit();

    inline for (.{ "{\"v\":1}", "{\"v\":2}", "{\"v\":3}" }) |payload| {
        try c1.append(payload);
        try c2.append(payload);
    }

    try std.testing.expectEqual(@as(?usize, null), c1.divergesAt(&c2));
}

test "divergesAt detects single-element delta" {
    const a = std.testing.allocator;
    var c1: Chain = .init(a);
    defer c1.deinit();
    var c2: Chain = .init(a);
    defer c2.deinit();

    try c1.append("{\"v\":1}");
    try c2.append("{\"v\":1}");
    try c1.append("{\"v\":2}");
    try c2.append("{\"v\":2}");
    try c1.append("{\"v\":3}");
    try c2.append("{\"v\":999}"); // divergence at index 2

    try std.testing.expectEqual(@as(?usize, 2), c1.divergesAt(&c2));
}

test "divergesAt at index 0 when first item differs" {
    const a = std.testing.allocator;
    var c1: Chain = .init(a);
    defer c1.deinit();
    var c2: Chain = .init(a);
    defer c2.deinit();

    try c1.append("{\"v\":1}");
    try c2.append("{\"v\":999}");

    try std.testing.expectEqual(@as(?usize, 0), c1.divergesAt(&c2));
}

test "divergesAt with prefix returns common length" {
    const a = std.testing.allocator;
    var short: Chain = .init(a);
    defer short.deinit();
    var long: Chain = .init(a);
    defer long.deinit();

    try short.append("{\"v\":1}");
    try short.append("{\"v\":2}");
    try long.append("{\"v\":1}");
    try long.append("{\"v\":2}");
    try long.append("{\"v\":3}");

    try std.testing.expectEqual(@as(?usize, 2), short.divergesAt(&long));
    try std.testing.expectEqual(@as(?usize, 2), long.divergesAt(&short));
}

test "O(1) short-circuit on matching heads of equal length" {
    // This test asserts behavior, not timing — a separate bench step (Task 2.5)
    // validates the wall-clock requirement on 100k entries.
    const a = std.testing.allocator;
    var c1: Chain = .init(a);
    defer c1.deinit();
    var c2: Chain = .init(a);
    defer c2.deinit();

    var i: usize = 0;
    while (i < 100) : (i += 1) {
        var buf: [32]u8 = undefined;
        const payload = try std.fmt.bufPrint(&buf, "{{\"i\":{d}}}", .{i});
        try c1.append(payload);
        try c2.append(payload);
    }

    try std.testing.expectEqual(@as(?usize, null), c1.divergesAt(&c2));
}

//! kb.ticks — tick primitives for the autonomous prediction agent.
//!
//! Each tick is a single state transition with a ULID identifier. The
//! orchestrator snapshots chain heads before and after, writes events to
//! a per-tick JSONL file, and tracks rejected sub-agent decisions on the
//! side. All paths live under `<kb_root>/.ticks/`.
//!
//! This module owns just the primitives — types, ULIDs, paths, and
//! schema/cap validation. The `praescientia-ticks` CLI (Stage 2) and the
//! orchestrate skill (Stage 5) compose them.

const std = @import("std");
const txlog = @import("../txlog.zig");

/// Length of the ULID portion of a tick id (Crockford-base32, 26 chars).
pub const tick_id_len: usize = 26;

/// One tick. Created at the start of a tick; the `id` is the audit anchor
/// for every artifact the tick produces (chain entries, snapshot files,
/// rejection logs, client_order_ids).
pub const Tick = struct {
    id: [tick_id_len]u8,

    /// Generate a fresh tick. ULID body = 48-bit Unix-ms timestamp + 80-bit
    /// CSPRNG randomness. Monotonic across ms boundaries but not within a
    /// single ms — fine for tick cadences measured in minutes.
    pub fn init() Tick {
        var tick: Tick = undefined;
        var tx_buf: [txlog.tx_id_len]u8 = undefined;
        txlog.generateTxId(&tx_buf);
        // generateTxId emits "tx_<26-char ULID>"; we only need the ULID body.
        @memcpy(&tick.id, tx_buf[3..][0..tick_id_len]);
        return tick;
    }

    /// Compose the on-disk path for one of the tick's artifact files.
    /// `buf` must be large enough to hold the full path; on overflow returns
    /// `error.NoSpaceLeft` (the `std.fmt.bufPrint` contract).
    pub fn path(self: *const Tick, buf: []u8, kb_root: []const u8, kind: PathKind) ![]u8 {
        return std.fmt.bufPrint(buf, "{s}/.ticks/{s}.{s}.{s}", .{
            kb_root,
            self.id[0..],
            @tagName(kind),
            kind.extension(),
        });
    }
};

/// The four per-tick artifact kinds. Determines both the filename suffix
/// and the file extension (`events` is JSONL; everything else is single-
/// object JSON).
pub const PathKind = enum {
    pre,
    post,
    events,
    rejected,

    fn extension(self: PathKind) []const u8 {
        return switch (self) {
            .events => "jsonl",
            .pre, .post, .rejected => "json",
        };
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "Tick.init generates a 26-char Crockford-base32 ULID" {
    const t = Tick.init();
    // Crockford alphabet: 0-9, A-Z minus I, L, O, U.
    for (t.id) |c| {
        const ok = (c >= '0' and c <= '9') or
            (c >= 'A' and c <= 'Z' and c != 'I' and c != 'L' and c != 'O' and c != 'U');
        try std.testing.expect(ok);
    }
}

test "Tick.path composes pre/post/events/rejected paths" {
    const t = Tick.init();
    var buf: [256]u8 = undefined;

    const pre = try t.path(&buf, "./kb", .pre);
    try std.testing.expect(std.mem.endsWith(u8, pre, ".pre.json"));
    try std.testing.expect(std.mem.startsWith(u8, pre, "./kb/.ticks/"));
    try std.testing.expect(std.mem.indexOf(u8, pre, t.id[0..]) != null);

    const post = try t.path(&buf, "./kb", .post);
    try std.testing.expect(std.mem.endsWith(u8, post, ".post.json"));

    const events = try t.path(&buf, "./kb", .events);
    try std.testing.expect(std.mem.endsWith(u8, events, ".events.jsonl"));

    const rejected = try t.path(&buf, "./kb", .rejected);
    try std.testing.expect(std.mem.endsWith(u8, rejected, ".rejected.json"));
}

test "Tick.path threads an absolute kb_root through" {
    const t = Tick.init();
    var buf: [256]u8 = undefined;
    const p = try t.path(&buf, "/var/lib/praescientia/kb", .pre);
    try std.testing.expect(std.mem.startsWith(u8, p, "/var/lib/praescientia/kb/.ticks/"));
}

test "Tick.init produces distinct ids across rapid calls" {
    const a = Tick.init();
    const b = Tick.init();
    // CSPRNG randomness suffix makes collision practically impossible even
    // within the same millisecond.
    try std.testing.expect(!std.mem.eql(u8, &a.id, &b.id));
}

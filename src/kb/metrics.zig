//! Prometheus-style counters for the KB substrate. All state is module-level
//! atomic; safe under Io.Threaded. No client library dependency — exposition
//! format is rendered as plain text on demand.

const std = @import("std");

pub const ChainKind = enum {
    market_reality,
    thesis_reality,
    other,

    pub fn label(self: ChainKind) []const u8 {
        return switch (self) {
            .market_reality => "market.reality",
            .thesis_reality => "thesis.reality",
            .other => "other",
        };
    }
};

const chain_kind_count = @typeInfo(ChainKind).@"enum".fields.len;

pub var chain_appends: [chain_kind_count]std.atomic.Value(u64) = blk: {
    var arr: [chain_kind_count]std.atomic.Value(u64) = undefined;
    for (&arr) |*v| v.* = .{ .raw = 0 };
    break :blk arr;
};

pub fn bumpAppend(kind: ChainKind) void {
    _ = chain_appends[@intFromEnum(kind)].fetchAdd(1, .monotonic);
}

pub const SkipReason = enum {
    price_delta_below_threshold,
    aggregate_unchanged,

    pub fn label(self: SkipReason) []const u8 {
        return switch (self) {
            .price_delta_below_threshold => "price_delta_below_threshold",
            .aggregate_unchanged => "aggregate_unchanged",
        };
    }
};

const skip_reason_count = @typeInfo(SkipReason).@"enum".fields.len;

pub var lock_contention: std.atomic.Value(u64) = .{ .raw = 0 };
pub var torn_tail_recovered: std.atomic.Value(u64) = .{ .raw = 0 };
pub var observe_skipped: [skip_reason_count]std.atomic.Value(u64) = blk: {
    var arr: [skip_reason_count]std.atomic.Value(u64) = undefined;
    for (&arr) |*v| v.* = .{ .raw = 0 };
    break :blk arr;
};

pub fn bumpLockContention() void {
    _ = lock_contention.fetchAdd(1, .monotonic);
}
pub fn bumpTornTail() void {
    _ = torn_tail_recovered.fetchAdd(1, .monotonic);
}
pub fn bumpObserveSkipped(r: SkipReason) void {
    _ = observe_skipped[@intFromEnum(r)].fetchAdd(1, .monotonic);
}

/// Zero every counter. Used by inline tests to isolate themselves from
/// counters that earlier tests bumped (module-level state).
pub fn resetAll() void {
    for (&chain_appends) |*v| v.store(0, .monotonic);
    lock_contention.store(0, .monotonic);
    torn_tail_recovered.store(0, .monotonic);
    for (&observe_skipped) |*v| v.store(0, .monotonic);
}

pub fn render(w: *std.Io.Writer) !void {
    try w.writeAll(
        \\# HELP praescientia_kb_chain_appends_total Successful chain appends, classified by payload kind.
        \\# TYPE praescientia_kb_chain_appends_total counter
        \\
    );
    for (std.enums.values(ChainKind)) |k| {
        const v = chain_appends[@intFromEnum(k)].load(.monotonic);
        try w.print("praescientia_kb_chain_appends_total{{kind=\"{s}\"}} {d}\n", .{ k.label(), v });
    }

    try w.writeAll(
        \\# HELP praescientia_kb_lock_contention_total Failed openForWrite attempts due to flock contention.
        \\# TYPE praescientia_kb_lock_contention_total counter
        \\
    );
    try w.print("praescientia_kb_lock_contention_total {d}\n", .{lock_contention.load(.monotonic)});

    try w.writeAll(
        \\# HELP praescientia_kb_torn_tail_recovered_total Torn writes truncated by recoverTornTail.
        \\# TYPE praescientia_kb_torn_tail_recovered_total counter
        \\
    );
    try w.print("praescientia_kb_torn_tail_recovered_total {d}\n", .{torn_tail_recovered.load(.monotonic)});

    try w.writeAll(
        \\# HELP praescientia_kb_observe_skipped_total Observations whose predicate did not fire.
        \\# TYPE praescientia_kb_observe_skipped_total counter
        \\
    );
    for (std.enums.values(SkipReason)) |r| {
        const v = observe_skipped[@intFromEnum(r)].load(.monotonic);
        try w.print("praescientia_kb_observe_skipped_total{{reason=\"{s}\"}} {d}\n", .{ r.label(), v });
    }
}

test "bumpAppend + render produces a parseable line" {
    resetAll();
    bumpAppend(.market_reality);
    bumpAppend(.market_reality);
    bumpAppend(.thesis_reality);

    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try render(&aw.writer);
    const out = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, out, "praescientia_kb_chain_appends_total{kind=\"market.reality\"} 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "praescientia_kb_chain_appends_total{kind=\"thesis.reality\"} 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "praescientia_kb_chain_appends_total{kind=\"other\"} 0") != null);
}

test "render exposes lock_contention, torn_tail, observe_skipped" {
    resetAll();
    bumpLockContention();
    bumpLockContention();
    bumpTornTail();
    bumpObserveSkipped(.price_delta_below_threshold);

    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try render(&aw.writer);
    const out = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, out, "praescientia_kb_lock_contention_total 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "praescientia_kb_torn_tail_recovered_total 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "praescientia_kb_observe_skipped_total{reason=\"price_delta_below_threshold\"} 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "praescientia_kb_observe_skipped_total{reason=\"aggregate_unchanged\"} 0") != null);
}

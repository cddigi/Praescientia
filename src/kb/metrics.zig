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

/// Zero every counter. Used by inline tests to isolate themselves from
/// counters that earlier tests bumped (module-level state).
pub fn resetAll() void {
    for (&chain_appends) |*v| v.store(0, .monotonic);
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

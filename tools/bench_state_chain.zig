//! Stage 2.5 microbenchmark — proves `state_chain.Chain.divergesAt` meets the
//! plan's sub-millisecond target on a 100k-entry chain.
//!
//! Reports two numbers:
//!   - fast path: identical heads, equal length → O(1) short-circuit
//!   - slow path: chains differ at index 50_000 → O(n) hash-by-hash compare
//!
//! Run: `zig build bench` (Debug) or `zig build bench -Doptimize=ReleaseFast`.

const std = @import("std");
const state_chain = @import("praescientia").state_chain;

const N = 100_000;
const DIVERGE_AT = N / 2;

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;

    var stdout_buf: [4096]u8 = undefined;
    var stdout_w = std.Io.File.stdout().writer(io, &stdout_buf);
    const out = &stdout_w.interface;
    defer out.flush() catch {};

    // Build the two chains. Both identical for the fast path; then we tweak
    // one item in the second chain for the slow path.
    var a: state_chain.Chain = .init(gpa);
    defer a.deinit();
    var b: state_chain.Chain = .init(gpa);
    defer b.deinit();

    var payload_buf: [32]u8 = undefined;
    var i: usize = 0;
    while (i < N) : (i += 1) {
        const payload = try std.fmt.bufPrint(&payload_buf, "{{\"i\":{d}}}", .{i});
        try a.append(payload);
        try b.append(payload);
    }

    // --- Fast path: identical heads, equal length.
    const fast_start = nowMonotonicNs();
    const fast_result = a.divergesAt(&b);
    std.mem.doNotOptimizeAway(fast_result);
    const fast_ns = nowMonotonicNs() - fast_start;
    if (fast_result != null) {
        try out.print("FAIL: fast path returned non-null on identical chains\n", .{});
        return 1;
    }

    // --- Slow path: force a single-index divergence.
    var c: state_chain.Chain = .init(gpa);
    defer c.deinit();
    i = 0;
    while (i < N) : (i += 1) {
        const payload = if (i == DIVERGE_AT)
            try std.fmt.bufPrint(&payload_buf, "{{\"i\":{d},\"x\":true}}", .{i})
        else
            try std.fmt.bufPrint(&payload_buf, "{{\"i\":{d}}}", .{i});
        try c.append(payload);
    }
    const slow_start = nowMonotonicNs();
    const slow_result = a.divergesAt(&c);
    std.mem.doNotOptimizeAway(slow_result);
    const slow_ns = nowMonotonicNs() - slow_start;
    if (slow_result == null or slow_result.? != DIVERGE_AT) {
        try out.print("FAIL: slow path expected divergence at {d}, got {?d}\n", .{ DIVERGE_AT, slow_result });
        return 1;
    }

    try out.print(
        \\state_chain.Chain.divergesAt on {d}-entry chains:
        \\  fast path (matching heads):       {d} ns  ({d:.3} us)
        \\  slow path (divergence at {d}): {d} ns  ({d:.3} us)
        \\
    , .{
        N,
        fast_ns,
        @as(f64, @floatFromInt(fast_ns)) / 1000.0,
        DIVERGE_AT,
        slow_ns,
        @as(f64, @floatFromInt(slow_ns)) / 1000.0,
    });

    const sub_millisecond: u64 = 1_000_000;
    if (fast_ns >= sub_millisecond or slow_ns >= sub_millisecond) {
        try out.print("FAIL: sub-millisecond target missed\n", .{});
        return 1;
    }
    try out.print("PASS: both paths under 1 ms\n", .{});
    return 0;
}

fn nowMonotonicNs() u64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    const sec: i128 = ts.sec;
    const nsec: i128 = ts.nsec;
    return @intCast(sec * 1_000_000_000 + nsec);
}

//! Canonical JSON encoding for hash-stable state representations.
//!
//! Object keys are sorted byte-wise ascending; no whitespace is emitted; numbers
//! use Zig stdlib's shortest-round-trip form. The same logical value MUST encode
//! identically regardless of source key order — this is what makes the
//! state_chain hashes deterministic across runs.
//!
//! Subset of RFC 8785 (JCS): ASCII key sort suffices for current use cases.
//! When non-ASCII keys appear, swap to UTF-16 code-point sort here only.

const std = @import("std");

const Allocator = std.mem.Allocator;
const Value = std.json.Value;

/// Canonicalize a parsed JSON value into the given writer.
pub fn encodeValue(value: Value, writer: *std.Io.Writer, scratch: Allocator) !void {
    var s: std.json.Stringify = .{ .writer = writer, .options = .{ .whitespace = .minified } };
    try emit(value, &s, scratch);
}

/// Canonicalize a raw JSON input slice. Caller owns the returned buffer.
pub fn encodeSlice(allocator: Allocator, json: []const u8) ![]u8 {
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();

    const parsed = try std.json.parseFromSliceLeaky(Value, arena.allocator(), json, .{});

    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    try encodeValue(parsed, &aw.writer, arena.allocator());
    return aw.toOwnedSlice();
}

/// Canonicalize a Zig value via std.json's introspection, then re-canonicalize
/// to enforce sorted keys. Convenient for native struct payloads.
pub fn encodeAny(allocator: Allocator, value: anytype) ![]u8 {
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();

    var first_pass: std.Io.Writer.Allocating = .init(arena.allocator());
    defer first_pass.deinit();
    try std.json.Stringify.value(value, .{ .whitespace = .minified }, &first_pass.writer);

    return encodeSlice(allocator, first_pass.written());
}

fn emit(value: Value, s: *std.json.Stringify, scratch: Allocator) !void {
    switch (value) {
        .null => try s.write(null),
        .bool => |b| try s.write(b),
        .integer => |i| try s.write(i),
        .float => |f| try s.write(f),
        .number_string => |ns| {
            try s.beginWriteRaw();
            try s.writer.writeAll(ns);
            s.endWriteRaw();
        },
        .string => |str| try s.write(str),
        .array => |arr| {
            try s.beginArray();
            for (arr.items) |item| try emit(item, s, scratch);
            try s.endArray();
        },
        .object => |obj| {
            const keys = try scratch.alloc([]const u8, obj.count());
            defer scratch.free(keys);
            var it = obj.iterator();
            var i: usize = 0;
            while (it.next()) |entry| : (i += 1) keys[i] = entry.key_ptr.*;
            std.mem.sort([]const u8, keys, {}, lessU8);

            try s.beginObject();
            for (keys) |k| {
                try s.objectField(k);
                try emit(obj.get(k).?, s, scratch);
            }
            try s.endObject();
        },
    }
}

fn lessU8(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

test "sorts object keys ascending" {
    const a = std.testing.allocator;
    const out = try encodeSlice(a, "{\"b\":1,\"a\":2}");
    defer a.free(out);
    try std.testing.expectEqualStrings("{\"a\":2,\"b\":1}", out);
}

test "sorts recursively in nested objects" {
    const a = std.testing.allocator;
    const out = try encodeSlice(a, "{\"z\":{\"y\":1,\"x\":2},\"a\":{\"b\":3,\"a\":4}}");
    defer a.free(out);
    try std.testing.expectEqualStrings(
        "{\"a\":{\"a\":4,\"b\":3},\"z\":{\"x\":2,\"y\":1}}",
        out,
    );
}

test "preserves array order" {
    const a = std.testing.allocator;
    const out = try encodeSlice(a, "[3,1,2]");
    defer a.free(out);
    try std.testing.expectEqualStrings("[3,1,2]", out);
}

test "elides whitespace" {
    const a = std.testing.allocator;
    const out = try encodeSlice(a, " {  \"a\" :   1  } ");
    defer a.free(out);
    try std.testing.expectEqualStrings("{\"a\":1}", out);
}

test "two equivalent inputs encode identically" {
    const a = std.testing.allocator;
    const left = try encodeSlice(a, "{\"a\":1,\"b\":[2,3]}");
    defer a.free(left);
    const right = try encodeSlice(a, "{\"b\":[2,3],\"a\":1}");
    defer a.free(right);
    try std.testing.expectEqualStrings(left, right);
}

test "encodeAny on a struct round-trips with sorted keys" {
    const a = std.testing.allocator;
    const S = struct { z: u32, a: u32 };
    const out = try encodeAny(a, S{ .z = 1, .a = 2 });
    defer a.free(out);
    try std.testing.expectEqualStrings("{\"a\":2,\"z\":1}", out);
}

test "handles strings, numbers, bool, null" {
    const a = std.testing.allocator;
    const out = try encodeSlice(a, "{\"s\":\"hi\",\"i\":42,\"f\":1.5,\"b\":true,\"n\":null}");
    defer a.free(out);
    try std.testing.expectEqualStrings(
        "{\"b\":true,\"f\":1.5,\"i\":42,\"n\":null,\"s\":\"hi\"}",
        out,
    );
}

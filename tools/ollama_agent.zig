const std = @import("std");

pub fn main(init: std.process.Init) !u8 {
    _ = init;
    std.debug.print("praescientia-ollama-agent stub\n", .{});
    return 0;
}

/// Extract a JSON envelope from `raw`, which may include leading/trailing prose,
/// a ```json ... ``` fence, or be bare JSON. Returns a freshly-allocated slice
/// containing the JSON substring. Caller owns the returned memory.
///
/// Strategy (in order):
///   1. Try parsing `raw` as JSON; if it parses, dupe and return.
///   2. Look for a ```json ... ``` fenced block; if found, return the body
///      (whitespace-trimmed) as long as it parses.
///   3. Scan from the first `{`, tracking brace depth (respecting string
///      literals and escape sequences) until depth returns to 0; try to parse
///      that slice. On parse failure, advance to the next `{` and retry.
///   4. Return error.NoJsonFound.
pub fn extractJsonEnvelope(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    if (tryParse(allocator, raw)) {
        return try allocator.dupe(u8, raw);
    }

    if (extractFencedJson(raw)) |body| {
        if (tryParse(allocator, body)) {
            return try allocator.dupe(u8, body);
        }
    }

    var search_start: usize = 0;
    while (std.mem.indexOfScalarPos(u8, raw, search_start, '{')) |open_idx| {
        if (findMatchingClose(raw, open_idx)) |close_idx| {
            const candidate = raw[open_idx .. close_idx + 1];
            if (tryParse(allocator, candidate)) {
                return try allocator.dupe(u8, candidate);
            }
        }
        search_start = open_idx + 1;
    }

    return error.NoJsonFound;
}

/// Try parsing `slice` as a generic JSON value. Returns true on success.
fn tryParse(allocator: std.mem.Allocator, slice: []const u8) bool {
    const parsed = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        slice,
        .{},
    ) catch return false;
    parsed.deinit();
    return true;
}

/// Find a ```json ... ``` fenced block in `raw` and return the body between
/// the fences (whitespace-trimmed). Returns null if no fence pair is found.
fn extractFencedJson(raw: []const u8) ?[]const u8 {
    const open_marker = "```json";
    const open_idx = std.mem.indexOf(u8, raw, open_marker) orelse return null;
    const after_open = open_idx + open_marker.len;
    if (after_open > raw.len) return null;
    const close_idx = std.mem.indexOf(u8, raw[after_open..], "```") orelse return null;
    const body = raw[after_open .. after_open + close_idx];
    return std.mem.trim(u8, body, " \t\r\n");
}

/// Starting at `open_idx` (which must point at `{`), scan forward tracking
/// brace depth while respecting JSON string literals (including `\"` escapes).
/// Returns the index of the matching closing `}`, or null if the braces never
/// balance (truncated input).
fn findMatchingClose(raw: []const u8, open_idx: usize) ?usize {
    std.debug.assert(raw[open_idx] == '{');
    var depth: usize = 0;
    var in_string: bool = false;
    var i: usize = open_idx;
    while (i < raw.len) : (i += 1) {
        const c = raw[i];
        if (in_string) {
            if (c == '\\') {
                // Skip the next byte (escape sequence body). Safe even if
                // we run off the end — the loop guard handles it.
                i += 1;
                continue;
            }
            if (c == '"') {
                in_string = false;
            }
            continue;
        }
        switch (c) {
            '"' => in_string = true,
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if (depth == 0) return i;
            },
            else => {},
        }
    }
    return null;
}

test "extractJsonEnvelope handles bare JSON" {
    const out = try extractJsonEnvelope(std.testing.allocator, "{\"x\":1}");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("{\"x\":1}", out);
}

test "extractJsonEnvelope strips leading prose" {
    const out = try extractJsonEnvelope(std.testing.allocator,
        "Here is the JSON:\n{\"x\":1,\"y\":2}\n");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("{\"x\":1,\"y\":2}", out);
}

test "extractJsonEnvelope unwraps ```json fence" {
    const out = try extractJsonEnvelope(std.testing.allocator,
        "Thinking...\n```json\n{\"x\":1}\n```\n");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("{\"x\":1}", out);
}

test "extractJsonEnvelope handles nested braces in prose" {
    const out = try extractJsonEnvelope(std.testing.allocator,
        "Note: {sic}. JSON: {\"x\":{\"y\":1}}");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("{\"x\":{\"y\":1}}", out);
}

test "extractJsonEnvelope returns error on no JSON" {
    try std.testing.expectError(
        error.NoJsonFound,
        extractJsonEnvelope(std.testing.allocator, "no braces here"),
    );
}

test "extractJsonEnvelope strips trailing prose" {
    const out = try extractJsonEnvelope(std.testing.allocator,
        "{\"x\":1}\nThat's the answer.");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("{\"x\":1}", out);
}

const std = @import("std");

/// Sub-agent role. Each role corresponds to a `.claude/agents/*.md` file whose
/// contents are baked into the binary at compile time via `@embedFile` (see
/// `rolePrompt`). The CLI form uses dashes (e.g. `thesis-analyst`); the enum
/// tag uses underscores. `Role.parse` enforces this boundary.
pub const Role = enum {
    thesis_analyst,
    loss_reflector,
    market_screener,

    /// Parse a CLI role string (dash form) into a `Role`. Only the canonical
    /// dash-separated forms are accepted; underscore forms and unknown strings
    /// return `null`. Caller pattern: `Role.parse(arg) orelse return error.UnknownRole`.
    pub fn parse(s: []const u8) ?Role {
        inline for (roles_table) |spec| {
            if (std.mem.eql(u8, s, spec.cli)) return spec.tag;
        }
        return null;
    }
};

/// Single-row spec linking a `Role` tag to its dash-form CLI string and the
/// anonymous-import name used by `@embedFile`. The table below is the source
/// of truth for the dash-form mapping; `Role.parse` walks it at comptime.
const RoleSpec = struct {
    tag: Role,
    cli: []const u8,
    embed_name: []const u8,
};

const roles_table = [_]RoleSpec{
    .{ .tag = .thesis_analyst, .cli = "thesis-analyst", .embed_name = "role_thesis_analyst" },
    .{ .tag = .loss_reflector, .cli = "loss-reflector", .embed_name = "role_loss_reflector" },
    .{ .tag = .market_screener, .cli = "market-screener", .embed_name = "role_market_screener" },
};

// Role-prompt files live at `.claude/agents/*.md`, outside this tool's
// package root, so they're registered as anonymous imports in `build.zig`
// (`addOllamaAgentRolePrompts`) and resolved here through those names.
// `@embedFile` requires a comptime string literal, so each decl stays
// explicit even though `roles_table` records the same name.
const thesis_prompt = @embedFile("role_thesis_analyst");
const loss_prompt = @embedFile("role_loss_reflector");
const screen_prompt = @embedFile("role_market_screener");

/// Return the embedded role definition prompt for `role`. The returned slice
/// is a pointer into the binary's read-only data and lives for the program's
/// lifetime — never freed by the caller.
fn rolePrompt(role: Role) []const u8 {
    return switch (role) {
        .thesis_analyst => thesis_prompt,
        .loss_reflector => loss_prompt,
        .market_screener => screen_prompt,
    };
}

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

test "rolePrompt returns expected embedded content per role" {
    const thesis = rolePrompt(.thesis_analyst);
    const loss = rolePrompt(.loss_reflector);
    const screen = rolePrompt(.market_screener);
    try std.testing.expect(thesis.len > 100);
    try std.testing.expect(loss.len > 100);
    try std.testing.expect(screen.len > 100);
    try std.testing.expect(!std.mem.eql(u8, thesis, loss));
    try std.testing.expect(std.ascii.indexOfIgnoreCase(thesis, "thesis") != null);
}

test "Role.parse maps CLI strings to Role enum and rejects unknowns" {
    try std.testing.expectEqual(@as(?Role, .thesis_analyst), Role.parse("thesis-analyst"));
    try std.testing.expectEqual(@as(?Role, .loss_reflector), Role.parse("loss-reflector"));
    try std.testing.expectEqual(@as(?Role, .market_screener), Role.parse("market-screener"));
    try std.testing.expectEqual(@as(?Role, null), Role.parse("unknown"));
    try std.testing.expectEqual(@as(?Role, null), Role.parse(""));
    try std.testing.expectEqual(@as(?Role, null), Role.parse("thesis_analyst")); // underscore form: NOT accepted
}

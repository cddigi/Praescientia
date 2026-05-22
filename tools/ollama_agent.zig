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

// ===========================================================================
// Ollama /api/chat client
// ---------------------------------------------------------------------------
// `callOllamaChat` is split into three layers so the pure logic is unit-tested
// and the HTTP path is exercised end-to-end by `scripts/ollama_agent_smoke.sh`
// (Task 2.6, gated by `OLLAMA_SMOKE=1`). This mirrors how the commentary
// indexer separates `embed_batch` (pure, mocked HTTP) from `commentary_smoke.sh`
// (real Ollama on localhost).
//
//   buildChatRequestBody  → assemble the JSON request body (pure)
//   parseChatResponse     → extract message.content from the response (pure)
//   callOllamaChat        → wire the two together over std.http.Client.fetch
// ===========================================================================

/// Ollama generation knobs. Held as constants because Task 2.4's scope is the
/// happy path against a single, locally-pinned model. If the orchestrator
/// later needs per-role overrides, promote these to a Role-keyed table.
const ollama_temperature: f64 = 0.2;
const ollama_num_predict: u32 = 4096;

/// Build the JSON request body for Ollama's `/api/chat` endpoint. The returned
/// slice is freshly allocated; the caller owns it and must `allocator.free` it.
///
/// Shape (verbatim — Ollama's documented contract):
///   {"model":"<tag>","messages":[
///     {"role":"system","content":"<rolePrompt(role)>"},
///     {"role":"user","content":"<prompt_payload>"}
///   ],"stream":false,"options":{"temperature":0.2,"num_predict":4096}}
pub fn buildChatRequestBody(
    allocator: std.mem.Allocator,
    model: []const u8,
    role: Role,
    prompt_payload: []const u8,
) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();

    // Build a typed struct that mirrors Ollama's contract and serialize it
    // through std.json.Stringify.value — that handles string escaping,
    // numeric formatting, and field ordering for us.
    const Message = struct {
        role: []const u8,
        content: []const u8,
    };
    const Options = struct {
        temperature: f64,
        num_predict: u32,
    };
    const Body = struct {
        model: []const u8,
        messages: [2]Message,
        stream: bool,
        options: Options,
    };

    const body: Body = .{
        .model = model,
        .messages = .{
            .{ .role = "system", .content = rolePrompt(role) },
            .{ .role = "user", .content = prompt_payload },
        },
        .stream = false,
        .options = .{ .temperature = ollama_temperature, .num_predict = ollama_num_predict },
    };

    try std.json.Stringify.value(body, .{ .whitespace = .minified }, &aw.writer);
    return aw.toOwnedSlice();
}

/// Parse an Ollama `/api/chat` response (with `stream: false`) and return a
/// freshly-allocated copy of `message.content`. Caller owns the returned slice.
///
/// Errors:
///   error.MalformedResponse — response is not a JSON object, `message` field
///     is missing/not-an-object, or `message.content` is missing/not-a-string.
///   Plus any error from `std.json.parseFromSlice` (invalid JSON).
pub fn parseChatResponse(
    allocator: std.mem.Allocator,
    body: []const u8,
) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();

    if (parsed.value != .object) return error.MalformedResponse;
    const root = parsed.value.object;

    const message_v = root.get("message") orelse return error.MalformedResponse;
    if (message_v != .object) return error.MalformedResponse;

    const content_v = message_v.object.get("content") orelse return error.MalformedResponse;
    if (content_v != .string) return error.MalformedResponse;

    return try allocator.dupe(u8, content_v.string);
}

/// POST to `<base_url>/api/chat` with the assembled request body and return
/// the assistant's `message.content` as a freshly-allocated slice. Caller
/// owns the returned memory.
///
/// Errors:
///   error.OllamaHttp        — non-200 response status.
///   error.MalformedResponse — response body did not contain `message.content`.
///   Plus any std.http.Client / allocator / JSON parse errors.
pub fn callOllamaChat(
    allocator: std.mem.Allocator,
    io: std.Io,
    base_url: []const u8,
    model: []const u8,
    role: Role,
    prompt_payload: []const u8,
) ![]u8 {
    const req_body = try buildChatRequestBody(allocator, model, role, prompt_payload);
    defer allocator.free(req_body);

    const url = try std.mem.concat(allocator, u8, &.{ base_url, "/api/chat" });
    defer allocator.free(url);

    var http: std.http.Client = .{ .allocator = allocator, .io = io };
    defer http.deinit();

    var resp_body: std.Io.Writer.Allocating = .init(allocator);
    defer resp_body.deinit();

    const result = try http.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = req_body,
        .response_writer = &resp_body.writer,
        .headers = .{
            .content_type = .{ .override = "application/json" },
            .accept_encoding = .{ .override = "application/json" },
        },
    });

    if (@intFromEnum(result.status) != 200) return error.OllamaHttp;

    return parseChatResponse(allocator, resp_body.written());
}

test "buildChatRequestBody round-trips through std.json with expected fields" {
    const a = std.testing.allocator;
    const body = try buildChatRequestBody(a, "llama3.2:latest", .thesis_analyst, "hello user payload");
    defer a.free(body);

    var parsed = try std.json.parseFromSlice(std.json.Value, a, body, .{});
    defer parsed.deinit();

    try std.testing.expect(parsed.value == .object);
    const root = parsed.value.object;

    const model_v = root.get("model") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("llama3.2:latest", model_v.string);

    const stream_v = root.get("stream") orelse return error.TestUnexpectedResult;
    try std.testing.expect(stream_v == .bool and stream_v.bool == false);

    const messages_v = root.get("messages") orelse return error.TestUnexpectedResult;
    try std.testing.expect(messages_v == .array);
    try std.testing.expectEqual(@as(usize, 2), messages_v.array.items.len);

    const sys = messages_v.array.items[0];
    try std.testing.expectEqualStrings("system", sys.object.get("role").?.string);
    // System content must match the embedded thesis-analyst prompt verbatim.
    try std.testing.expectEqualStrings(rolePrompt(.thesis_analyst), sys.object.get("content").?.string);

    const user = messages_v.array.items[1];
    try std.testing.expectEqualStrings("user", user.object.get("role").?.string);
    try std.testing.expectEqualStrings("hello user payload", user.object.get("content").?.string);
}

test "buildChatRequestBody encodes options.temperature and options.num_predict" {
    const a = std.testing.allocator;
    const body = try buildChatRequestBody(a, "m", .loss_reflector, "p");
    defer a.free(body);

    var parsed = try std.json.parseFromSlice(std.json.Value, a, body, .{});
    defer parsed.deinit();

    const opts = parsed.value.object.get("options") orelse return error.TestUnexpectedResult;
    try std.testing.expect(opts == .object);

    const temp = opts.object.get("temperature") orelse return error.TestUnexpectedResult;
    // std.json represents JSON numbers as .float when they have a decimal point.
    switch (temp) {
        .float => |f| try std.testing.expectApproxEqAbs(@as(f64, 0.2), f, 1e-9),
        .integer => |i| try std.testing.expectEqual(@as(i64, 0), i), // would mean 0 — fail loudly
        else => return error.TestUnexpectedResult,
    }

    const np = opts.object.get("num_predict") orelse return error.TestUnexpectedResult;
    try std.testing.expect(np == .integer);
    try std.testing.expectEqual(@as(i64, 4096), np.integer);
}

test "buildChatRequestBody escapes special characters in the user payload" {
    const a = std.testing.allocator;
    // Embed a quote, a backslash, and a newline in the payload. The JSON body
    // must remain parseable and round-trip the exact bytes.
    const payload = "she said \"hi\"\nwith\\slash";
    const body = try buildChatRequestBody(a, "m", .market_screener, payload);
    defer a.free(body);

    var parsed = try std.json.parseFromSlice(std.json.Value, a, body, .{});
    defer parsed.deinit();

    const user = parsed.value.object.get("messages").?.array.items[1];
    try std.testing.expectEqualStrings(payload, user.object.get("content").?.string);
}

test "parseChatResponse extracts message.content on well-formed response" {
    const body = "{\"message\":{\"role\":\"assistant\",\"content\":\"{\\\"ok\\\":true}\"},\"done\":true}";
    const out = try parseChatResponse(std.testing.allocator, body);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("{\"ok\":true}", out);
}

test "parseChatResponse returns MalformedResponse when message is missing" {
    try std.testing.expectError(
        error.MalformedResponse,
        parseChatResponse(std.testing.allocator, "{\"done\":true}"),
    );
}

test "parseChatResponse returns MalformedResponse when message.content is missing" {
    try std.testing.expectError(
        error.MalformedResponse,
        parseChatResponse(std.testing.allocator, "{\"message\":{\"role\":\"assistant\"}}"),
    );
}

test "parseChatResponse returns MalformedResponse when message.content is not a string" {
    try std.testing.expectError(
        error.MalformedResponse,
        parseChatResponse(std.testing.allocator, "{\"message\":{\"role\":\"assistant\",\"content\":42}}"),
    );
}

test "parseChatResponse returns MalformedResponse when root is not an object" {
    try std.testing.expectError(
        error.MalformedResponse,
        parseChatResponse(std.testing.allocator, "[]"),
    );
}

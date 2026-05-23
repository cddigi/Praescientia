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

/// Default knobs for the CLI. `--ollama-url` defaults to localhost on the
/// canonical Ollama port; `--timeout-ms` and `--temperature` are accepted at
/// the CLI but plumb-through into `callOllamaChat` / `buildChatRequestBody` is
/// deferred until those helpers gain timeout / per-call temperature support
/// (currently the request body uses the hardcoded `ollama_temperature`).
const default_ollama_url = "http://localhost:11434";
const default_timeout_ms: u32 = 120_000;
const default_temperature: f64 = 0.2;

/// Cap on stdin payload size. 1 MiB is well above the largest realistic
/// thesis context block (a tick.md §2 sub-agent prompt is ~50 KiB tops);
/// going higher would just mask runaway producers without operational value.
const max_stdin_bytes: usize = 1 << 20;

/// Parsed CLI surface for the Ollama agent. Held by value through `main`.
const ParsedArgs = struct {
    role: Role,
    model: []const u8,
    ollama_url: []const u8,
    timeout_ms: u32,
    temperature: f64,
};

/// Outcome of `parseArgs`. `.ok` carries the parsed flags; `.help` signals
/// that `--help` / `-h` was present and the caller should print usage and
/// exit 0; `.parse_error` signals argparse failure (a diagnostic was already
/// written to stderr) and the caller should exit 5.
const ParseResult = union(enum) {
    ok: ParsedArgs,
    help,
    parse_error,
};

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    const arena_alloc = init.arena.allocator();

    var stderr_buf: [4096]u8 = undefined;
    var stderr_w = std.Io.File.stderr().writer(io, &stderr_buf);
    const stderr = &stderr_w.interface;
    defer stderr.flush() catch {};

    var stdout_buf: [4096]u8 = undefined;
    var stdout_w = std.Io.File.stdout().writer(io, &stdout_buf);
    const stdout = &stdout_w.interface;
    defer stdout.flush() catch {};

    const argv = init.minimal.args.toSlice(arena_alloc) catch |err| {
        try stderr.print("failed to read argv: {s}\n", .{@errorName(err)});
        return 2;
    };

    const parsed = switch (parseArgs(argv[1..], stderr) catch |e| {
        try stderr.print("argparse failed: {s}\n", .{@errorName(e)});
        return 5;
    }) {
        .help => {
            try usage(stderr);
            return 0;
        },
        .parse_error => return 5,
        .ok => |p| p,
    };

    // Read all of stdin into the arena. The orchestrator pipes the per-tick
    // prompt as a single chunk and closes; we don't need streaming.
    const prompt_payload = readStdinAll(io, arena_alloc) catch |err| {
        try stderr.print("failed to read stdin: {s}\n", .{@errorName(err)});
        return 2;
    };

    const content = callOllamaChat(
        gpa,
        io,
        parsed.ollama_url,
        parsed.model,
        parsed.role,
        prompt_payload,
    ) catch |err| switch (err) {
        // The two "shape" errors share exit code 4 so an operator can
        // distinguish them from a transport failure. The actual
        // human-readable distinction lives in the stderr breadcrumb
        // emitted by callOllamaChat / here.
        error.MalformedResponse, error.EmptyContent => {
            try stderr.print(
                "ollama returned a malformed response ({s})\n",
                .{@errorName(err)},
            );
            return 4;
        },
        // Everything else — error.OllamaHttp (already breadcrumbed in
        // callOllamaChat), connection refused, timeout, DNS failure,
        // allocator failures, etc. — bucket into exit 2. callOllamaChat
        // emits a single-line diagnostic for transport-class errors before
        // returning; this branch adds the final "exit 2" framing.
        else => {
            try stderr.print(
                "ollama call failed ({s}) against {s}/api/chat\n",
                .{ @errorName(err), parsed.ollama_url },
            );
            return 2;
        },
    };
    defer gpa.free(content);

    const envelope = extractJsonEnvelope(arena_alloc, content) catch |err| switch (err) {
        error.NoJsonFound => {
            const preview = previewSlice(content, 200);
            try stderr.print(
                "no JSON envelope found in model output (first {d} chars): {s}\n",
                .{ preview.len, preview },
            );
            return 3;
        },
        else => {
            try stderr.print("envelope extraction failed: {s}\n", .{@errorName(err)});
            return 2;
        },
    };

    try stdout.print("{s}", .{envelope});
    try stdout.flush();
    return 0;
}

/// Parse argv (already trimmed of `argv[0]`). On the happy path returns
/// `.ok` with the parsed struct; on `--help` / `-h` returns `.help`; on any
/// argparse failure writes a diagnostic to `stderr` and returns `.parse_error`.
fn parseArgs(args: []const [:0]const u8, stderr: *std.Io.Writer) !ParseResult {
    var role_arg: ?[]const u8 = null;
    var model_arg: ?[]const u8 = null;
    var ollama_url: []const u8 = default_ollama_url;
    var timeout_ms: u32 = default_timeout_ms;
    var temperature: f64 = default_temperature;

    for (args) |a| {
        if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            return .help;
        } else if (std.mem.startsWith(u8, a, "--role=")) {
            role_arg = a["--role=".len..];
        } else if (std.mem.startsWith(u8, a, "--model=")) {
            model_arg = a["--model=".len..];
        } else if (std.mem.startsWith(u8, a, "--ollama-url=")) {
            ollama_url = a["--ollama-url=".len..];
        } else if (std.mem.startsWith(u8, a, "--timeout-ms=")) {
            const raw = a["--timeout-ms=".len..];
            timeout_ms = std.fmt.parseInt(u32, raw, 10) catch {
                try stderr.print("--timeout-ms must be a non-negative integer, got: '{s}'\n", .{raw});
                return .parse_error;
            };
        } else if (std.mem.startsWith(u8, a, "--temperature=")) {
            const raw = a["--temperature=".len..];
            temperature = std.fmt.parseFloat(f64, raw) catch {
                try stderr.print("--temperature must be a float, got: '{s}'\n", .{raw});
                return .parse_error;
            };
        } else {
            try stderr.print("unknown argument: {s}\n", .{a});
            return .parse_error;
        }
    }

    const role_str = role_arg orelse {
        try stderr.print("--role is required (one of: thesis-analyst, loss-reflector, market-screener)\n", .{});
        return .parse_error;
    };
    const role = Role.parse(role_str) orelse {
        try stderr.print(
            "--role must be one of thesis-analyst, loss-reflector, market-screener; got: '{s}'\n",
            .{role_str},
        );
        return .parse_error;
    };

    const model = model_arg orelse {
        try stderr.print("--model is required (e.g. --model=qwen3.6:27b-mlx)\n", .{});
        return .parse_error;
    };
    if (model.len == 0) {
        try stderr.print("--model must not be empty\n", .{});
        return .parse_error;
    }

    return .{ .ok = .{
        .role = role,
        .model = model,
        .ollama_url = ollama_url,
        .timeout_ms = timeout_ms,
        .temperature = temperature,
    } };
}

fn usage(stderr: *std.Io.Writer) !void {
    try stderr.print(
        \\Usage: praescientia-ollama-agent --role=ROLE --model=TAG [options] < PROMPT
        \\
        \\Pipe a sub-agent prompt payload on stdin; the binary POSTs to
        \\<ollama-url>/api/chat with the embedded role prompt as the system
        \\message and the stdin payload as the user message, then strips any
        \\prose wrapper from the model's reply and writes the JSON envelope
        \\to stdout.
        \\
        \\Required:
        \\  --role=ROLE              one of: thesis-analyst, loss-reflector, market-screener
        \\  --model=TAG              Ollama model tag (e.g. qwen3.6:27b-mlx)
        \\
        \\Optional:
        \\  --ollama-url=URL         Ollama base URL (default: {s})
        \\  --timeout-ms=N           request timeout in ms (default: {d}; accepted but not yet plumbed)
        \\  --temperature=F          generation temperature (default: {d}; accepted but not yet plumbed)
        \\  --help, -h               print this usage to stderr and exit 0
        \\
        \\Exit codes:
        \\  0  success; JSON envelope written to stdout
        \\  2  transport failure (HTTP non-200, refused, timeout, etc.)
        \\  3  model output did not contain a JSON envelope
        \\  4  Ollama returned a malformed or empty response body
        \\  5  argparse / usage error
        \\
    , .{ default_ollama_url, default_timeout_ms, default_temperature });
}

fn readStdinAll(io: std.Io, allocator: std.mem.Allocator) ![]u8 {
    var read_buf: [4096]u8 = undefined;
    var reader = std.Io.File.stdin().reader(io, &read_buf);
    var list: std.array_list.Managed(u8) = .init(allocator);
    errdefer list.deinit();
    while (true) {
        const chunk = reader.interface.peek(1) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (chunk.len == 0) break;
        if (list.items.len + chunk.len > max_stdin_bytes) {
            return error.StdinTooLarge;
        }
        try list.appendSlice(chunk);
        reader.interface.toss(chunk.len);
    }
    return list.toOwnedSlice();
}

/// Return at most `cap` bytes of `s` for inclusion in a stderr diagnostic.
/// Keeps the operator-visible blurb short and bounded.
fn previewSlice(s: []const u8, cap: usize) []const u8 {
    return if (s.len <= cap) s else s[0..cap];
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
///   error.EmptyContent — `message.content` parses but is the empty string.
///     Promoted to its own error so operators can distinguish "Ollama returned
///     nothing" from "Ollama returned prose with no JSON envelope" (which
///     surfaces later as `error.NoJsonFound` from `extractJsonEnvelope`). The
///     CLI maps both `MalformedResponse` and `EmptyContent` to exit code 4;
///     the distinction only shows up in the stderr breadcrumb.
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

    if (content_v.string.len == 0) return error.EmptyContent;

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

    if (@intFromEnum(result.status) != 200) {
        // I2 breadcrumb: include the status code and a body preview so an
        // operator can distinguish 404 (wrong model) from 500 (server crash)
        // without re-running with curl. Cap at 200 chars to keep stderr
        // readable when Ollama returns a long HTML error page. Transport-
        // class errors (connection refused / DNS / timeout) are not breadcrumbed
        // here — they bubble up through `try` and `main`'s catch arm emits a
        // single-line diagnostic with the URL, which is enough context.
        const body = resp_body.written();
        const preview = if (body.len <= 200) body else body[0..200];
        std.debug.print(
            "ollama returned HTTP {d} ({s}): {s}\n",
            .{ @intFromEnum(result.status), url, preview },
        );
        return error.OllamaHttp;
    }

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

test "parseChatResponse returns EmptyContent when message.content is empty string" {
    // Folded-in I1 (option a): empty content is its own error so the CLI can
    // emit a distinct stderr breadcrumb. Both EmptyContent and MalformedResponse
    // share exit code 4 — the distinction shows up only in the diagnostic.
    try std.testing.expectError(
        error.EmptyContent,
        parseChatResponse(std.testing.allocator, "{\"message\":{\"role\":\"assistant\",\"content\":\"\"}}"),
    );
}

// ---------------------------------------------------------------------------
// parseArgs — argparse for `main`. The CLI surface is small enough that
// these tests are end-to-end-ish: given a slice of argv tokens, assert the
// resulting `ParsedArgs` fields, that `--help` short-circuits, and that
// missing / malformed flags surface as `.parse_error`.
// ---------------------------------------------------------------------------

/// Helper: build a `[:0]const u8` slice from a `[]const []const u8` literal.
/// Tests' string literals come back as `[]const u8`, but `init.minimal.args.toSlice`
/// hands us `[:0]const u8` — we mirror that to keep the test inputs honest.
fn z(comptime literals: []const []const u8) [literals.len][:0]const u8 {
    var out: [literals.len][:0]const u8 = undefined;
    inline for (literals, 0..) |s, i| out[i] = s ++ "";
    return out;
}

test "parseArgs accepts minimal required flags" {
    var sink: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sink.deinit();
    const argv = z(&.{ "--role=thesis-analyst", "--model=qwen3.6:27b-mlx" });
    const result = try parseArgs(&argv, &sink.writer);
    try std.testing.expect(result == .ok);
    try std.testing.expectEqual(Role.thesis_analyst, result.ok.role);
    try std.testing.expectEqualStrings("qwen3.6:27b-mlx", result.ok.model);
    // Defaults must match the public CLI contract.
    try std.testing.expectEqualStrings(default_ollama_url, result.ok.ollama_url);
    try std.testing.expectEqual(default_timeout_ms, result.ok.timeout_ms);
}

test "parseArgs returns .help on --help" {
    var sink: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sink.deinit();
    const argv = z(&.{"--help"});
    const result = try parseArgs(&argv, &sink.writer);
    try std.testing.expect(result == .help);
}

test "parseArgs returns .parse_error on missing required flag" {
    var sink: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sink.deinit();
    // Missing --role.
    const argv = z(&.{"--model=qwen3.6:27b-mlx"});
    const result = try parseArgs(&argv, &sink.writer);
    try std.testing.expect(result == .parse_error);
    // The diagnostic must mention --role so an operator knows what's missing.
    try std.testing.expect(std.mem.indexOf(u8, sink.written(), "--role") != null);
}

test "parseArgs returns .parse_error on unknown flag" {
    var sink: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sink.deinit();
    const argv = z(&.{ "--role=thesis-analyst", "--model=m", "--bogus" });
    const result = try parseArgs(&argv, &sink.writer);
    try std.testing.expect(result == .parse_error);
    try std.testing.expect(std.mem.indexOf(u8, sink.written(), "--bogus") != null);
}

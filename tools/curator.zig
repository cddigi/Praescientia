//! praescientia-curator — CLI for the source-curator sub-agent's output.
//!
//! Subcommands:
//!   validate --output=PATH --tick-id=ULID [--max-fetches=N]   Validate agent JSON.
//!                                                              Exit 0 accept, 1 reject.
//!   apply    --output=PATH --tick-id=ULID [--kb-root=PATH]     Persist entries as
//!            [--thesis=ID] [--max-fetches=N] [--dry-run]        source-backed commentary:
//!            [--allow-global-sources]                           prepend frontmatter, stamp
//!                                                               source:<tier>, writeCommentary.
//!   tick     --thesis=ID [--kb-root=PATH] [--max-fetches=N]    End-to-end grounding tick:
//!            [--curator-agent-bin via claude] [--allow-global]  gather neighbors → build input
//!                                                               → claude dispatch → validate
//!                                                               → apply. Daemon spawns this.
//!
//! Global entries are downgraded to the dispatch thesis scope unless
//! --allow-global-sources is set (resolved decision D2).

const std = @import("std");
const common = @import("common");
const praescientia = @import("praescientia");

const curator_mod = praescientia.kb.curator;
const commentary_mod = praescientia.kb.commentary;

pub fn main(init: std.process.Init) !u8 {
    return common.runMain(init, "praescientia-curator", &.{
        .{ .name = "validate", .description = "Validate a source-curator output JSON file", .run = cmdValidate },
        .{ .name = "apply", .description = "Persist accepted entries as source-backed commentary", .run = cmdApply },
        .{ .name = "tick", .description = "End-to-end grounding tick (gather → dispatch → validate → apply)", .run = cmdTick },
    });
}

fn nowMs(io: std.Io) i64 {
    return @intCast(@divFloor(std.Io.Clock.real.now(io).nanoseconds, 1_000_000));
}

fn loadOutput(ctx: *common.Context) !?[]const u8 {
    const path = ctx.flagValue("--output") orelse {
        try ctx.stderr.print("--output=PATH is required (curator output JSON file)\n", .{});
        return null;
    };
    return std.Io.Dir.cwd().readFileAlloc(ctx.io, path, ctx.arena, .unlimited) catch |err| {
        try ctx.stderr.print("read --output {s}: {t}\n", .{ path, err });
        return null;
    };
}

fn maxFetchesFlag(ctx: *common.Context) usize {
    if (ctx.flagValue("--max-fetches")) |v| {
        if (std.fmt.parseInt(usize, v, 10)) |n| return n else |_| {}
    }
    return 5;
}

fn hasFlag(ctx: *common.Context, name: []const u8) bool {
    for (ctx.args[1..]) |a| {
        if (std.mem.eql(u8, a, name)) return true;
    }
    return false;
}

fn cmdValidate(ctx: *common.Context) !u8 {
    const bytes = (try loadOutput(ctx)) orelse return 2;
    const tick_id = ctx.flagValue("--tick-id") orelse {
        try ctx.stderr.print("--tick-id=ULID is required\n", .{});
        return 2;
    };
    const result = curator_mod.validate(ctx.arena, bytes, tick_id, nowMs(ctx.io), maxFetchesFlag(ctx)) catch |err| {
        try ctx.stderr.print("{{\"ok\":false,\"reason\":\"{t}\"}}\n", .{err});
        return 1;
    };
    try ctx.stdout.print(
        "{{\"ok\":true,\"tick_id\":\"{s}\",\"entries\":{d},\"counts\":{{\"primary\":{d},\"sportsbook\":{d},\"news_org\":{d},\"aggregator\":{d},\"forum\":{d}}}}}\n",
        .{
            result.output.tick_id,        result.output.entries.len,
            result.counts.primary,        result.counts.sportsbook,
            result.counts.news_org,       result.counts.aggregator,
            result.counts.forum,
        },
    );
    return 0;
}

/// Prepend the provenance frontmatter line to a curator entry's body. Format
/// must match commentary.parseFrontmatter byte-for-byte.
fn buildBodyWithFrontmatter(arena: std.mem.Allocator, entry: curator_mod.CuratorEntry) ![]const u8 {
    return std.fmt.allocPrint(
        arena,
        "--- src: {s} fetched: {d} valid_until: {d} ---\n{s}",
        .{ entry.source_url, entry.fetch_ts_ms, entry.valid_until_ms, entry.body },
    );
}

/// Resolve an entry's commentary scope, applying the D2 global→thesis
/// downgrade when global writes are not allowed. Returns null when a global
/// entry cannot be downgraded (no dispatch thesis to attach it to).
fn resolveScope(
    entry: curator_mod.CuratorEntry,
    dispatch_thesis: ?[]const u8,
    allow_global: bool,
) ?commentary_mod.Scope {
    return switch (entry.scope) {
        .thesis => .{ .thesis = entry.scope_key },
        .market => .{ .market = entry.scope_key },
        .global => if (allow_global)
            .global
        else if (dispatch_thesis) |t|
            .{ .thesis = t }
        else
            null,
    };
}

/// Stamp the source:<tier> tag onto the agent's tags if not already present,
/// and sanitize: drop empty or over-length (> max_tag_len) tags so the entry
/// never trips commentary.validatePayload at write time. Agents sometimes emit
/// tags embedding the full ticker (e.g. `market:KXTEMPNYCH-26MAY2319-T61.99`,
/// 34 chars > the 32 cap) — an over-long *tag* must not sink an otherwise good
/// source, so we drop it here rather than reject the dispatch. Caps the total
/// at commentary.max_tags; the source tag takes priority.
fn buildTags(
    arena: std.mem.Allocator,
    entry: curator_mod.CuratorEntry,
) ![]const []const u8 {
    var has_source = false;
    for (entry.tags) |t| {
        if (std.mem.startsWith(u8, t, commentary_mod.source_tag_prefix)) has_source = true;
    }
    var list: std.array_list.Managed([]const u8) = .init(arena);
    const source_tag = try std.fmt.allocPrint(arena, "source:{s}", .{entry.source_tier.key()});
    if (!has_source) try list.append(source_tag);
    for (entry.tags) |t| {
        if (list.items.len >= commentary_mod.max_tags) break;
        if (t.len == 0 or t.len > commentary_mod.max_tag_len) continue; // sanitize malformed tags
        try list.append(t);
    }
    return list.items;
}

fn applyEntries(
    ctx: *common.Context,
    kb_root: std.Io.Dir,
    result: curator_mod.ValidationResult,
    dispatch_thesis: ?[]const u8,
    allow_global: bool,
) !struct { written: usize, downgraded: usize, skipped: usize } {
    var written: usize = 0;
    var downgraded: usize = 0;
    var skipped: usize = 0;

    for (result.output.entries) |entry| {
        if (entry.scope == .global and !allow_global) downgraded += 1;
        const scope = resolveScope(entry, dispatch_thesis, allow_global) orelse {
            try ctx.stderr.print("skip global entry (no dispatch thesis to downgrade to): {s}\n", .{entry.source_url});
            skipped += 1;
            continue;
        };
        const body = try buildBodyWithFrontmatter(ctx.arena, entry);
        const tags = try buildTags(ctx.arena, entry);
        const payload: commentary_mod.CommentaryPayload = .{
            .agent = .{ .model = "praescientia-source-curator", .run_id = result.output.tick_id },
            .body = body,
            .references = entry.references,
            .parent_hash = null,
            .inputs = .{ .prediction_head = null, .market_set_heads = &.{} },
            .tags = tags,
            .ts_ms = entry.fetch_ts_ms,
        };
        const r = commentary_mod.writeCommentary(ctx.gpa, ctx.io, kb_root, scope, payload) catch |err| {
            try ctx.stderr.print("commentary write ({s}): {t}\n", .{ entry.source_url, err });
            skipped += 1;
            continue;
        };
        ctx.gpa.free(r.scope_path);
        written += 1;
    }
    return .{ .written = written, .downgraded = downgraded, .skipped = skipped };
}

fn cmdApply(ctx: *common.Context) !u8 {
    const bytes = (try loadOutput(ctx)) orelse return 2;
    const tick_id = ctx.flagValue("--tick-id") orelse {
        try ctx.stderr.print("--tick-id=ULID is required\n", .{});
        return 2;
    };
    const kb_root_path = ctx.flagValue("--kb-root") orelse "./kb";
    const dispatch_thesis = ctx.flagValue("--thesis");
    const allow_global = hasFlag(ctx, "--allow-global-sources");
    const dry_run = hasFlag(ctx, "--dry-run");

    const result = curator_mod.validate(ctx.arena, bytes, tick_id, nowMs(ctx.io), maxFetchesFlag(ctx)) catch |err| {
        try ctx.stderr.print("{{\"ok\":false,\"reason\":\"{t}\"}}\n", .{err});
        return 1;
    };

    if (dry_run) {
        try ctx.stdout.print(
            "{{\"ok\":true,\"dry_run\":true,\"tick_id\":\"{s}\",\"planned\":{d}}}\n",
            .{ result.output.tick_id, result.output.entries.len },
        );
        return 0;
    }

    var kb_root = std.Io.Dir.cwd().openDir(ctx.io, kb_root_path, .{ .iterate = true }) catch |err| {
        try ctx.stderr.print("open kb-root {s}: {t}\n", .{ kb_root_path, err });
        return 1;
    };
    defer kb_root.close(ctx.io);

    const counts = try applyEntries(ctx, kb_root, result, dispatch_thesis, allow_global);
    try ctx.stdout.print(
        "{{\"ok\":true,\"tick_id\":\"{s}\",\"written\":{d},\"downgraded\":{d},\"skipped\":{d}}}\n",
        .{ result.output.tick_id, counts.written, counts.downgraded, counts.skipped },
    );
    return 0;
}

// ---------------------------------------------------------------------------
// `tick` — end-to-end grounding tick (the daemon spawns this).
// ---------------------------------------------------------------------------

const subprocess_max_bytes: usize = 16 * 1024 * 1024;

const SubprocessResult = struct {
    exit: u8,
    stdout: []const u8,
    stderr: []const u8,
};

fn runSubprocess(ctx: *common.Context, argv: []const []const u8) !SubprocessResult {
    var child = try std.process.spawn(ctx.io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    var stdout_reader = child.stdout.?.readerStreaming(ctx.io, &.{});
    var stderr_reader = child.stderr.?.readerStreaming(ctx.io, &.{});
    const stdout_bytes = stdout_reader.interface.allocRemaining(ctx.arena, .limited(subprocess_max_bytes)) catch &[_]u8{};
    const stderr_bytes = stderr_reader.interface.allocRemaining(ctx.arena, .limited(subprocess_max_bytes)) catch &[_]u8{};
    const term = try child.wait(ctx.io);
    const exit_code: u8 = switch (term) {
        .exited => |c| c,
        .signal => 130,
        .stopped => 137,
        .unknown => 1,
    };
    return .{ .exit = exit_code, .stdout = stdout_bytes, .stderr = stderr_bytes };
}

/// Mirror screener.extractJsonObject — greedy outer-{} with string/escape
/// state so prose prefixes and embedded braces don't fool the extractor.
fn extractJsonObject(s: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, s, " \r\n\t");
    const start = std.mem.indexOfScalar(u8, trimmed, '{') orelse return null;
    var depth: usize = 0;
    var in_string = false;
    var escape = false;
    var i: usize = start;
    while (i < trimmed.len) : (i += 1) {
        const c = trimmed[i];
        if (escape) {
            escape = false;
            continue;
        }
        if (in_string) {
            if (c == '\\') {
                escape = true;
            } else if (c == '"') {
                in_string = false;
            }
            continue;
        }
        switch (c) {
            '"' => in_string = true,
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if (depth == 0) return trimmed[start .. i + 1];
            },
            else => {},
        }
    }
    return null;
}

/// Read a thesis's commentary chain tail and emit it as a JSON array of
/// neighbor objects {hash, scope_path, body, tags, ts_ms}. Returns "[]" if the
/// chain doesn't exist yet. Caps at the most recent `limit` entries.
fn loadThesisNeighborsJson(
    arena: std.mem.Allocator,
    io: std.Io,
    kb_root: std.Io.Dir,
    thesis_id: []const u8,
    limit: usize,
) ![]const u8 {
    const rel = try std.fmt.allocPrint(arena, "theses/{s}/commentary/main.jsonl", .{thesis_id});
    const raw = kb_root.readFileAlloc(io, rel, arena, .unlimited) catch |err| switch (err) {
        error.FileNotFound => return "[]",
        else => return err,
    };
    const scope_path = try std.fmt.allocPrint(arena, "theses/{s}/commentary", .{thesis_id});

    // Collect lines, keep the last `limit`.
    var lines: std.array_list.Managed([]const u8) = .init(arena);
    var it = std.mem.splitScalar(u8, raw, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        try lines.append(line);
    }
    const start: usize = if (lines.items.len > limit) lines.items.len - limit else 0;

    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    try w.writeAll("[");
    var emitted: usize = 0;
    for (lines.items[start..]) |line| {
        var parsed = std.json.parseFromSlice(std.json.Value, arena, line, .{}) catch continue;
        defer parsed.deinit();
        if (parsed.value != .object) continue;
        const obj = parsed.value.object;
        const hash_v = obj.get("hash") orelse continue;
        const payload_v = obj.get("payload") orelse continue;
        if (hash_v != .string or payload_v != .object) continue;
        const body_v = payload_v.object.get("body") orelse continue;
        if (body_v != .string) continue;
        const ts_v = payload_v.object.get("ts");
        const ts_ms: i64 = if (ts_v) |t| (if (t == .integer) t.integer else 0) else 0;

        if (emitted > 0) try w.writeAll(",");
        try w.print("{{\"hash\":\"{s}\",\"scope_path\":\"{s}\",\"body\":", .{ hash_v.string, scope_path });
        try std.json.Stringify.value(body_v.string, .{}, w);
        try w.writeAll(",\"tags\":");
        if (payload_v.object.get("tags")) |tags_v| {
            try std.json.Stringify.value(tags_v, .{}, w);
        } else {
            try w.writeAll("[]");
        }
        try w.print(",\"ts_ms\":{d}}}", .{ts_ms});
        emitted += 1;
    }
    try w.writeAll("]");
    return aw.written();
}

fn cmdTick(ctx: *common.Context) !u8 {
    const kb_root_path = ctx.flagValue("--kb-root") orelse "./kb";
    const thesis_id = ctx.flagValue("--thesis") orelse {
        try ctx.stderr.print("--thesis=ID is required\n", .{});
        return 2;
    };
    const max_fetches = maxFetchesFlag(ctx);
    const allow_global = hasFlag(ctx, "--allow-global-sources");

    var kb_root = std.Io.Dir.cwd().openDir(ctx.io, kb_root_path, .{ .iterate = true }) catch |err| {
        try ctx.stderr.print("open kb-root {s}: {t}\n", .{ kb_root_path, err });
        return 1;
    };
    defer kb_root.close(ctx.io);

    // --- Load thesis manifest + neighbors -----------------------------------
    const manifest_rel = try std.fmt.allocPrint(ctx.arena, "theses/{s}/manifest.json", .{thesis_id});
    const manifest_bytes = kb_root.readFileAlloc(ctx.io, manifest_rel, ctx.arena, .unlimited) catch |err| {
        try ctx.stderr.print("read thesis manifest {s}: {t}\n", .{ manifest_rel, err });
        return 1;
    };
    const manifest_trimmed = std.mem.trim(u8, manifest_bytes, " \r\n\t");
    const neighbors_json = loadThesisNeighborsJson(ctx.arena, ctx.io, kb_root, thesis_id, 8) catch |err| {
        try ctx.stderr.print("load neighbors: {t}\n", .{err});
        return 1;
    };

    const tick_id = ctx.flagValue("--tick-id") orelse try std.fmt.allocPrint(ctx.arena, "01CURATORTICK{d}", .{nowMs(ctx.io)});

    // --- Build curator input payload ----------------------------------------
    const input_json = try std.fmt.allocPrint(ctx.arena,
        \\{{"tick_id":"{s}","thesis":{s},"ticker":null,"search_hints":[],"neighbors":{s},"max_fetches":{d},"tier_budget":{{"primary":3,"sportsbook":2,"news_org":3,"aggregator":2,"forum":1}}}}
    , .{ tick_id, manifest_trimmed, neighbors_json, max_fetches });

    const input_path = try std.fmt.allocPrint(ctx.arena, "/tmp/curator_input_{s}.json", .{tick_id});
    const output_path = try std.fmt.allocPrint(ctx.arena, "/tmp/curator_output_{s}.json", .{tick_id});
    std.Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = input_path, .data = input_json }) catch |err| {
        try ctx.stderr.print("write input {s}: {t}\n", .{ input_path, err });
        return 1;
    };

    // --- Dispatch claude → source-curator agent -----------------------------
    const prompt = try std.fmt.allocPrint(ctx.arena,
        \\You are the praescientia curator-tick orchestrator running in a non-interactive `claude -p` session.
        \\
        \\YOUR ONE TASK: invoke the praescientia-source-curator Agent with the payload at INPUT_PATH, then write its JSON response to OUTPUT_PATH.
        \\
        \\INPUT_PATH:  {s}
        \\OUTPUT_PATH: {s}
        \\
        \\Procedure:
        \\1. Read INPUT_PATH using the Read tool.
        \\2. Invoke the Agent tool with these exact parameters:
        \\   - subagent_type: "praescientia-source-curator"
        \\   - model: "sonnet"
        \\   - description: "Ground thesis with sources"
        \\   - prompt: the verbatim contents of INPUT_PATH.
        \\3. The Agent returns a JSON object (it may emit prose or fences — strip them). Find the outer {{...}} substring.
        \\4. Write that JSON substring verbatim to OUTPUT_PATH using the Write tool.
        \\5. Print to stdout EXACTLY ONE LINE: {{"status":"ok"}} on success, or {{"status":"failed","reason":"<cause>"}} on failure.
        \\
        \\Do not invoke other tools beyond Read, Agent, Write. Do not place orders. Do not modify the kb.
    , .{ input_path, output_path });

    var claude_argv: std.array_list.Managed([]const u8) = .init(ctx.arena);
    try claude_argv.append("claude");
    try claude_argv.append("--model");
    try claude_argv.append("sonnet");
    try claude_argv.append("-p");
    try claude_argv.append(prompt);

    const claude_result = runSubprocess(ctx, claude_argv.items) catch |err| {
        try ctx.stderr.print("spawn claude: {t}\n", .{err});
        return 1;
    };
    if (claude_result.exit != 0) {
        try ctx.stderr.print("claude exited {d}; stderr tail: {s}\n", .{ claude_result.exit, std.mem.trim(u8, claude_result.stderr, " \r\n\t") });
        return 1;
    }

    // --- Read output, validate, apply ---------------------------------------
    const output_bytes = std.Io.Dir.cwd().readFileAlloc(ctx.io, output_path, ctx.arena, .unlimited) catch |err| {
        try ctx.stderr.print("read agent output {s}: {t}\n", .{ output_path, err });
        return 1;
    };
    const json_slice = extractJsonObject(output_bytes) orelse {
        try ctx.stderr.print("agent output at {s} has no parseable JSON object\n", .{output_path});
        return 1;
    };
    const result = curator_mod.validate(ctx.arena, json_slice, tick_id, nowMs(ctx.io), max_fetches) catch |err| {
        try ctx.stderr.print("{{\"ok\":false,\"reason\":\"{t}\"}}\n", .{err});
        return 1;
    };
    const counts = try applyEntries(ctx, kb_root, result, thesis_id, allow_global);
    try ctx.stdout.print(
        "{{\"ok\":true,\"tick_id\":\"{s}\",\"thesis\":\"{s}\",\"written\":{d},\"downgraded\":{d},\"skipped\":{d},\"fetches_consumed\":{d},\"output_path\":\"{s}\"}}\n",
        .{ tick_id, thesis_id, counts.written, counts.downgraded, counts.skipped, result.output.fetches_consumed, output_path },
    );
    return 0;
}

// ---------------------------------------------------------------------------
// Tests — pure helpers (validate/apply lifecycle covered by scripts/curator_smoke.sh).
// ---------------------------------------------------------------------------

fn testEntry() curator_mod.CuratorEntry {
    return .{
        .scope = .thesis,
        .scope_key = "eu-cpi",
        .source_url = "https://x.test/a",
        .source_tier = .primary,
        .fetch_ts_ms = 1779840000000,
        .valid_until_ms = 1779840000000 + 86_400_000,
        .body = "prose citing https://x.test/a",
        .tags = &.{"eu-cpi"},
        .references = &.{},
    };
}

test "buildBodyWithFrontmatter — round-trips through commentary.parseFrontmatter" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const out = try buildBodyWithFrontmatter(arena, testEntry());
    const fm = try commentary_mod.parseFrontmatter(out);
    try std.testing.expectEqualStrings("https://x.test/a", fm.src);
    try std.testing.expectEqualStrings("prose citing https://x.test/a", fm.rest);
}

test "buildTags — stamps source tier when absent" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const tags = try buildTags(arena, testEntry());
    try std.testing.expectEqualStrings("source:primary", tags[0]);
    try std.testing.expectEqual(@as(usize, 2), tags.len);
}

test "buildTags — drops empty and over-length tags (sanitization)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var e = testEntry();
    // 34-char ticker tag (> 32 cap), an empty tag, and a valid one.
    e.tags = &.{ "market:KXTEMPNYCH-26MAY2319-T61.99", "", "topic:temperature" };
    const tags = try buildTags(arena, e);
    for (tags) |t| {
        try std.testing.expect(t.len > 0 and t.len <= commentary_mod.max_tag_len);
    }
    // The valid tag survives; the over-long + empty ones are gone.
    var saw_valid = false;
    for (tags) |t| {
        if (std.mem.eql(u8, t, "topic:temperature")) saw_valid = true;
        try std.testing.expect(!std.mem.eql(u8, t, "market:KXTEMPNYCH-26MAY2319-T61.99"));
    }
    try std.testing.expect(saw_valid);
}

test "buildTags — does not double-stamp an existing source tag" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var e = testEntry();
    e.tags = &.{ "source:primary", "eu-cpi" };
    const tags = try buildTags(arena, e);
    var source_count: usize = 0;
    for (tags) |t| {
        if (std.mem.startsWith(u8, t, "source:")) source_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), source_count);
}

test "resolveScope — thesis and market pass through" {
    const e_thesis = testEntry();
    const s = resolveScope(e_thesis, null, false).?;
    try std.testing.expect(s == .thesis);

    var e_market = testEntry();
    e_market.scope = .market;
    e_market.scope_key = "KXBTC-26";
    const sm = resolveScope(e_market, null, false).?;
    try std.testing.expect(sm == .market);
}

test "resolveScope — global downgrades to dispatch thesis when not allowed" {
    var e = testEntry();
    e.scope = .global;
    e.scope_key = "";
    const downgraded = resolveScope(e, "eu-cpi", false).?;
    try std.testing.expect(downgraded == .thesis);
    try std.testing.expectEqualStrings("eu-cpi", downgraded.thesis);
}

test "resolveScope — global stays global when allowed" {
    var e = testEntry();
    e.scope = .global;
    e.scope_key = "";
    const g = resolveScope(e, "eu-cpi", true).?;
    try std.testing.expect(g == .global);
}

test "resolveScope — global with no dispatch thesis and not allowed is null" {
    var e = testEntry();
    e.scope = .global;
    e.scope_key = "";
    try std.testing.expect(resolveScope(e, null, false) == null);
}

test "extractJsonObject — strips prose around curator envelope" {
    const input = "Here you go:\n{\"tick_id\":\"01X\",\"entries\":[]}";
    const got = extractJsonObject(input) orelse return error.NoMatch;
    try std.testing.expectEqualStrings("{\"tick_id\":\"01X\",\"entries\":[]}", got);
}

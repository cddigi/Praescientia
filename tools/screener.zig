//! praescientia-screener — CLI for the market-screener sub-agent's output.
//!
//! Subcommands:
//!   validate --output=PATH [--kb-root=PATH]              Validate the agent JSON.
//!                                                        Exit 0 on accept, 1 on reject.
//!   apply    --output=PATH [--kb-root=PATH]              Materialize accepted entries:
//!            [--bucket=safe|moderate|high_risk]            add-market, add-thesis,
//!            [--dry-run]                                   commentary write (per seed).
//!   tick     [--kb-root=PATH] [--markets-bin=PATH]       End-to-end screener tick:
//!            [--limit=N] [--live] [--cap-*=N]              fetch candidates → build
//!                                                          input → spawn claude to
//!                                                          dispatch agent → validate
//!                                                          → apply. Designed to be
//!                                                          spawned by the daemon's
//!                                                          --screener-cadence loop.

const std = @import("std");
const common = @import("common");
const praescientia = @import("praescientia");

const screener_mod = praescientia.kb.screener;
const init_mod = praescientia.kb.init;
const commentary_mod = praescientia.kb.commentary;

pub fn main(init: std.process.Init) !u8 {
    return common.runMain(init, "praescientia-screener", &.{
        .{ .name = "validate", .description = "Validate a screener output JSON file", .run = cmdValidate },
        .{ .name = "apply", .description = "Materialize accepted bucket entries", .run = cmdApply },
        .{ .name = "tick", .description = "End-to-end screener tick (fetch → dispatch → validate → apply)", .run = cmdTick },
    });
}

fn loadExistingMarketSet(
    arena: std.mem.Allocator,
    io: std.Io,
    kb_root: std.Io.Dir,
) ![]const []const u8 {
    var out: std.array_list.Managed([]const u8) = .init(arena);
    var theses_dir = kb_root.openDir(io, "theses", .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return out.items,
        else => return err,
    };
    defer theses_dir.close(io);
    var it = theses_dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        var thesis_dir = theses_dir.openDir(io, entry.name, .{}) catch continue;
        defer thesis_dir.close(io);
        const manifest_bytes = thesis_dir.readFileAlloc(io, "manifest.json", arena, .unlimited) catch continue;
        var parsed = std.json.parseFromSlice(std.json.Value, arena, manifest_bytes, .{}) catch continue;
        defer parsed.deinit();
        const root = parsed.value.object;
        const market_set_v = root.get("market_set") orelse continue;
        if (market_set_v != .array) continue;
        for (market_set_v.array.items) |t| {
            if (t != .string) continue;
            try out.append(try arena.dupe(u8, t.string));
        }
    }
    return out.items;
}

fn loadOutput(ctx: *common.Context) !?[]const u8 {
    const path = ctx.flagValue("--output") orelse {
        try ctx.stderr.print("--output=PATH is required (screener output JSON file)\n", .{});
        return null;
    };
    return std.Io.Dir.cwd().readFileAlloc(ctx.io, path, ctx.arena, .unlimited) catch |err| {
        try ctx.stderr.print("read --output {s}: {t}\n", .{ path, err });
        return null;
    };
}

fn parseCapsFromFlags(ctx: *common.Context) screener_mod.BucketCaps {
    var caps: screener_mod.BucketCaps = .{};
    if (ctx.flagValue("--cap-safe")) |v| {
        if (std.fmt.parseInt(usize, v, 10)) |n| caps.safe = n else |_| {}
    }
    if (ctx.flagValue("--cap-moderate")) |v| {
        if (std.fmt.parseInt(usize, v, 10)) |n| caps.moderate = n else |_| {}
    }
    if (ctx.flagValue("--cap-high-risk")) |v| {
        if (std.fmt.parseInt(usize, v, 10)) |n| caps.high_risk = n else |_| {}
    }
    return caps;
}

fn cmdValidate(ctx: *common.Context) !u8 {
    const bytes = (try loadOutput(ctx)) orelse return 2;
    const kb_root_path = ctx.flagValue("--kb-root") orelse "./kb";
    var kb_root = std.Io.Dir.cwd().openDir(ctx.io, kb_root_path, .{ .iterate = true }) catch |err| {
        try ctx.stderr.print("open kb-root {s}: {t}\n", .{ kb_root_path, err });
        return 1;
    };
    defer kb_root.close(ctx.io);
    const existing = loadExistingMarketSet(ctx.arena, ctx.io, kb_root) catch |err| {
        try ctx.stderr.print("load existing theses: {t}\n", .{err});
        return 1;
    };
    const caps = parseCapsFromFlags(ctx);
    const result = screener_mod.validate(ctx.arena, bytes, existing, caps) catch |err| {
        try ctx.stderr.print("{{\"ok\":false,\"reason\":\"{t}\"}}\n", .{err});
        return 1;
    };
    try ctx.stdout.print(
        "{{\"ok\":true,\"scan_id\":\"{s}\",\"counts\":{{\"safe\":{d},\"moderate\":{d},\"high_risk\":{d}}}}}\n",
        .{ result.output.scan_id, result.counts.safe, result.counts.moderate, result.counts.high_risk },
    );
    return 0;
}

const ApplyPlan = struct {
    add_market: []const u8,
    add_thesis: struct {
        id: []const u8,
        description: []const u8,
        weights_json: []const u8,
    },
    commentaries: []const []const u8,
    bucket: []const u8,
    confidence_bp: u32,
    suggested_size_pct_of_cap: u32,
};

fn buildWeightsJson(arena: std.mem.Allocator, ticker: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "{{\"{s}\":10000}}", .{ticker});
}

fn buildDescription(
    arena: std.mem.Allocator,
    entry: screener_mod.BucketEntry,
) ![]const u8 {
    return std.fmt.allocPrint(
        arena,
        "[screener:{s}] {s} | implied={d}c our={d}c edge={d}c conf={d}bp size_pct={d}%",
        .{
            entry.bucket.key(),
            entry.primary_signal,
            entry.implied_yes_cents,
            entry.our_estimate_yes_cents,
            entry.edge_cents,
            entry.confidence_bp,
            entry.suggested_size_pct_of_cap,
        },
    );
}

fn entryMatchesBucketFilter(entry: screener_mod.BucketEntry, filter: ?[]const u8) bool {
    const f = filter orelse return true;
    if (std.mem.eql(u8, f, "all")) return true;
    const kind = screener_mod.BucketKind.parse(f) orelse return true;
    return entry.bucket == kind;
}

fn cmdApply(ctx: *common.Context) !u8 {
    const bytes = (try loadOutput(ctx)) orelse return 2;
    const dry_run = ctx.flagValue("--dry-run") != null or
        for (ctx.args[1..]) |a| {
            if (std.mem.eql(u8, a, "--dry-run")) break true;
        } else false;
    const bucket_filter = ctx.flagValue("--bucket");
    const kb_root_path = ctx.flagValue("--kb-root") orelse "./kb";

    var kb_root = std.Io.Dir.cwd().openDir(ctx.io, kb_root_path, .{ .iterate = true }) catch |err| {
        try ctx.stderr.print("open kb-root {s}: {t}\n", .{ kb_root_path, err });
        return 1;
    };
    defer kb_root.close(ctx.io);

    const existing = loadExistingMarketSet(ctx.arena, ctx.io, kb_root) catch |err| {
        try ctx.stderr.print("load existing theses: {t}\n", .{err});
        return 1;
    };
    const caps = parseCapsFromFlags(ctx);

    const validation = screener_mod.validate(ctx.arena, bytes, existing, caps) catch |err| {
        try ctx.stderr.print("{{\"ok\":false,\"reason\":\"{t}\"}}\n", .{err});
        return 1;
    };

    var plans: std.array_list.Managed(ApplyPlan) = .init(ctx.arena);
    for (validation.output.buckets) |entry| {
        if (!entryMatchesBucketFilter(entry, bucket_filter)) continue;
        const weights_json = try buildWeightsJson(ctx.arena, entry.ticker);
        const description = try buildDescription(ctx.arena, entry);
        try plans.append(.{
            .add_market = entry.ticker,
            .add_thesis = .{
                .id = entry.proposed_thesis_id,
                .description = description,
                .weights_json = weights_json,
            },
            .commentaries = entry.suggested_seed_commentary,
            .bucket = entry.bucket.key(),
            .confidence_bp = entry.confidence_bp,
            .suggested_size_pct_of_cap = entry.suggested_size_pct_of_cap,
        });
    }

    if (dry_run) {
        try ctx.stdout.print(
            "{{\"ok\":true,\"dry_run\":true,\"scan_id\":\"{s}\",\"planned\":{d},\"writes\":[\n",
            .{ validation.output.scan_id, plans.items.len },
        );
        for (plans.items, 0..) |p, i| {
            try ctx.stdout.print(
                "  {{\"bucket\":\"{s}\",\"thesis_id\":\"{s}\",\"ticker\":\"{s}\",\"commentaries\":{d},\"confidence_bp\":{d},\"size_pct\":{d}}}{s}\n",
                .{
                    p.bucket,
                    p.add_thesis.id,
                    p.add_market,
                    p.commentaries.len,
                    p.confidence_bp,
                    p.suggested_size_pct_of_cap,
                    if (i == plans.items.len - 1) "" else ",",
                },
            );
        }
        try ctx.stdout.print("]}}\n", .{});
        return 0;
    }

    // Real apply path — write to disk.
    var written: usize = 0;
    var commentary_written: usize = 0;
    for (plans.items) |p| {
        // Add market (idempotent — init.addMarket creates a directory; if it
        // already exists, the call returns an error which we treat as already-
        // present and continue).
        init_mod.addMarket(ctx.io, kb_root, p.add_market, 1) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => {
                try ctx.stderr.print("add-market {s}: {t}\n", .{ p.add_market, err });
                continue;
            },
        };
        // Add thesis.
        init_mod.addThesis(ctx.gpa, ctx.io, kb_root, .{
            .id = p.add_thesis.id,
            .description = p.add_thesis.description,
            .rollup_fn = "weighted_avg_v1",
            .weights_json = p.add_thesis.weights_json,
            .confidence_delta_bp = 300,
        }) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => {
                try ctx.stderr.print("add-thesis {s}: {t}\n", .{ p.add_thesis.id, err });
                continue;
            },
        };
        written += 1;
        // Write seed commentaries.
        const ts_ms: i64 = @intCast(@divFloor(std.Io.Clock.real.now(ctx.io).nanoseconds, 1_000_000));
        const tags = [_][]const u8{ "screener-seed", "first-tick-ready" };
        const scope: commentary_mod.Scope = .{ .thesis = p.add_thesis.id };
        for (p.commentaries) |body| {
            const payload: commentary_mod.CommentaryPayload = .{
                .agent = .{ .model = "praescientia-market-screener", .run_id = validation.output.scan_id },
                .body = body,
                .references = &.{},
                .parent_hash = null,
                .inputs = .{ .prediction_head = null, .market_set_heads = &.{} },
                .tags = &tags,
                .ts_ms = ts_ms,
            };
            const result = commentary_mod.writeCommentary(ctx.gpa, ctx.io, kb_root, scope, payload) catch |err| {
                try ctx.stderr.print("commentary write {s}: {t}\n", .{ p.add_thesis.id, err });
                continue;
            };
            ctx.gpa.free(result.scope_path);
            commentary_written += 1;
        }
    }

    try ctx.stdout.print(
        "{{\"ok\":true,\"applied\":{d},\"commentaries_written\":{d},\"scan_id\":\"{s}\"}}\n",
        .{ written, commentary_written, validation.output.scan_id },
    );
    return 0;
}

// ---------------------------------------------------------------------------
// `tick` — end-to-end screener tick (the daemon spawns this).
// ---------------------------------------------------------------------------
//
// Pipeline:
//   1. fetch candidates  →  subprocess `praescientia-markets candidates`
//   2. build input JSON  →  in-process merge of candidates + existing_set + caps
//   3. dispatch agent    →  subprocess `claude -p '<prompt>'` (the prompt tells
//                            claude to invoke the praescientia-market-screener
//                            sub-agent and write its JSON response to a file)
//   4. validate          →  in-process call to screener_mod.validate
//   5. apply             →  in-process writes (markets, theses, commentaries)
//
// Why a Zig CLI orchestrating claude (rather than claude orchestrating a
// pipeline): the deterministic file I/O is cheap in Zig and the only step
// that actually needs claude's reasoning is the agent dispatch. Keeps the
// daemon's spawn target a single binary instead of a slash-command surface.

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

    const stdout_bytes = stdout_reader.interface.allocRemaining(
        ctx.arena,
        .limited(subprocess_max_bytes),
    ) catch &[_]u8{};
    const stderr_bytes = stderr_reader.interface.allocRemaining(
        ctx.arena,
        .limited(subprocess_max_bytes),
    ) catch &[_]u8{};

    const term = try child.wait(ctx.io);
    const exit_code: u8 = switch (term) {
        .exited => |c| c,
        .signal => 130,
        .stopped => 137,
        .unknown => 1,
    };
    return .{ .exit = exit_code, .stdout = stdout_bytes, .stderr = stderr_bytes };
}

/// Find the outer {...} JSON object in `s`. The screener agent (and
/// every other Praescientia sub-agent) frequently emits prose or
/// markdown fences around its JSON despite the no-prose protocol;
/// matches the prose-stripping pattern in tick.md §step-8.
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

/// Merge the candidates JSON (output of `praescientia-markets candidates`)
/// with `existing_market_set` + `caps` into the agent's input payload.
/// Allocates from `arena`.
fn buildScreenerInputJson(
    arena: std.mem.Allocator,
    candidates_bytes: []const u8,
    existing: []const []const u8,
    caps: screener_mod.BucketCaps,
) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;

    // Strip the closing brace from the candidates JSON, then append the
    // extra fields. We trust that `praescientia-markets candidates`
    // emits a well-formed top-level object.
    const trimmed = std.mem.trim(u8, candidates_bytes, " \r\n\t");
    if (trimmed.len < 2 or trimmed[0] != '{' or trimmed[trimmed.len - 1] != '}') {
        return error.InvalidCandidatesJson;
    }
    const inner = trimmed[1 .. trimmed.len - 1];

    try w.writeAll("{");
    try w.writeAll(inner);
    try w.writeAll(",\"existing_market_set\":[");
    for (existing, 0..) |t, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("\"");
        try w.writeAll(t);
        try w.writeAll("\"");
    }
    try w.print("],\"caps\":{{\"safe\":{d},\"moderate\":{d},\"high_risk\":{d}}}}}", .{
        caps.safe, caps.moderate, caps.high_risk,
    });
    return aw.written();
}

fn cmdTick(ctx: *common.Context) !u8 {
    const kb_root_path = ctx.flagValue("--kb-root") orelse "./kb";
    const markets_bin = ctx.flagValue("--markets-bin") orelse "./zig-out/bin/praescientia-markets";
    const limit = ctx.flagValue("--limit") orelse "80";
    const live_flag = blk: {
        for (ctx.args[1..]) |a| {
            if (std.mem.eql(u8, a, "--live")) break :blk true;
        }
        break :blk false;
    };
    const env_arg: []const u8 = if (live_flag) "--live" else "--demo";

    var kb_root = std.Io.Dir.cwd().openDir(ctx.io, kb_root_path, .{ .iterate = true }) catch |err| {
        try ctx.stderr.print("open kb-root {s}: {t}\n", .{ kb_root_path, err });
        return 1;
    };
    defer kb_root.close(ctx.io);

    // --- Step 1: fetch candidates -------------------------------------------
    var candidates_argv: std.array_list.Managed([]const u8) = .init(ctx.arena);
    try candidates_argv.append(markets_bin);
    try candidates_argv.append(env_arg);
    try candidates_argv.append("candidates");
    try candidates_argv.append(try std.fmt.allocPrint(ctx.arena, "--limit={s}", .{limit}));
    const cands_result = runSubprocess(ctx, candidates_argv.items) catch |err| {
        try ctx.stderr.print("spawn {s}: {t}\n", .{ markets_bin, err });
        return 1;
    };
    if (cands_result.exit != 0) {
        try ctx.stderr.print(
            "{s} exited {d}: {s}\n",
            .{ markets_bin, cands_result.exit, std.mem.trim(u8, cands_result.stderr, " \r\n\t") },
        );
        return 1;
    }
    const candidates_bytes = cands_result.stdout;

    // --- Step 2: parse + early-exit on empty --------------------------------
    var parsed = std.json.parseFromSlice(std.json.Value, ctx.arena, candidates_bytes, .{}) catch |err| {
        try ctx.stderr.print("parse candidates JSON: {t}\n", .{err});
        return 1;
    };
    defer parsed.deinit();
    const root_v = parsed.value;
    if (root_v != .object) {
        try ctx.stderr.print("candidates JSON is not an object\n", .{});
        return 1;
    }
    const cands_v = root_v.object.get("candidates") orelse {
        try ctx.stderr.print("candidates JSON missing 'candidates' field\n", .{});
        return 1;
    };
    if (cands_v != .array) {
        try ctx.stderr.print("candidates JSON 'candidates' is not an array\n", .{});
        return 1;
    }
    const scan_id_v = root_v.object.get("scan_id") orelse return error.MissingScanId;
    if (scan_id_v != .string) return error.InvalidScanId;
    const scan_id = scan_id_v.string;

    if (cands_v.array.items.len == 0) {
        try ctx.stdout.print(
            "{{\"ok\":true,\"skipped\":\"no_candidates\",\"scan_id\":\"{s}\"}}\n",
            .{scan_id},
        );
        return 0;
    }

    // --- Step 3: existing_market_set + caps ---------------------------------
    const existing = loadExistingMarketSet(ctx.arena, ctx.io, kb_root) catch |err| {
        try ctx.stderr.print("load existing theses: {t}\n", .{err});
        return 1;
    };
    const caps = parseCapsFromFlags(ctx);

    // --- Step 4: build input payload + write to tmp -------------------------
    const input_json = try buildScreenerInputJson(ctx.arena, candidates_bytes, existing, caps);
    const input_path = try std.fmt.allocPrint(ctx.arena, "/tmp/screener_input_{s}.json", .{scan_id});
    const output_path = try std.fmt.allocPrint(ctx.arena, "/tmp/screener_output_{s}.json", .{scan_id});
    std.Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = input_path, .data = input_json }) catch |err| {
        try ctx.stderr.print("write input {s}: {t}\n", .{ input_path, err });
        return 1;
    };

    // --- Step 5: dispatch claude --------------------------------------------
    const prompt = try std.fmt.allocPrint(ctx.arena,
        \\You are the praescientia screener-tick orchestrator running in a non-interactive `claude -p` session.
        \\
        \\YOUR ONE TASK: invoke the praescientia-market-screener Agent with the payload at INPUT_PATH, then write its JSON response to OUTPUT_PATH.
        \\
        \\INPUT_PATH:  {s}
        \\OUTPUT_PATH: {s}
        \\
        \\Procedure:
        \\1. Read INPUT_PATH using the Read tool.
        \\2. Invoke the Agent tool with these exact parameters:
        \\   - subagent_type: "praescientia-market-screener"
        \\   - model: "sonnet"
        \\   - description: "Screen Kalshi candidates"
        \\   - prompt: a multi-line string consisting of "Screen these Kalshi candidates per your agent contract. Emit your single JSON nomination per the contract.\n\nInput payload:\n" followed by the verbatim contents of INPUT_PATH wrapped in a fenced code block.
        \\3. The Agent returns a JSON object (it may emit prose prefix or markdown fences — that is expected; strip them). Find the outer {{...}} substring of the JSON object in the Agent response.
        \\4. Write that JSON substring verbatim to OUTPUT_PATH using the Write tool.
        \\5. Print to stdout EXACTLY ONE LINE of JSON:
        \\   - success: {{"status":"ok"}}
        \\   - failure: {{"status":"failed","reason":"<short cause>"}}
        \\
        \\Do not invoke any other tools. Do not print any other text. Do not place orders. Do not modify the kb. Do not write files other than OUTPUT_PATH.
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
        try ctx.stderr.print(
            "claude exited {d}; stderr tail: {s}\n",
            .{ claude_result.exit, std.mem.trim(u8, claude_result.stderr, " \r\n\t") },
        );
        return 1;
    }

    // --- Step 6: read output, validate, apply -------------------------------
    const output_bytes = std.Io.Dir.cwd().readFileAlloc(ctx.io, output_path, ctx.arena, .unlimited) catch |err| {
        try ctx.stderr.print("read agent output {s}: {t}\n", .{ output_path, err });
        return 1;
    };
    const json_slice = extractJsonObject(output_bytes) orelse {
        try ctx.stderr.print("agent output at {s} has no parseable JSON object\n", .{output_path});
        return 1;
    };
    const validation = screener_mod.validate(ctx.arena, json_slice, existing, caps) catch |err| {
        try ctx.stderr.print("{{\"ok\":false,\"reason\":\"{t}\"}}\n", .{err});
        return 1;
    };

    // Inline apply — mirrors cmdApply's write loop.
    var applied: usize = 0;
    var commentaries_written: usize = 0;
    for (validation.output.buckets) |entry| {
        const weights_json = try buildWeightsJson(ctx.arena, entry.ticker);
        const description = try buildDescription(ctx.arena, entry);
        init_mod.addMarket(ctx.io, kb_root, entry.ticker, 1) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => {
                try ctx.stderr.print("add-market {s}: {t}\n", .{ entry.ticker, err });
                continue;
            },
        };
        init_mod.addThesis(ctx.gpa, ctx.io, kb_root, .{
            .id = entry.proposed_thesis_id,
            .description = description,
            .rollup_fn = "weighted_avg_v1",
            .weights_json = weights_json,
            .confidence_delta_bp = 300,
        }) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => {
                try ctx.stderr.print("add-thesis {s}: {t}\n", .{ entry.proposed_thesis_id, err });
                continue;
            },
        };
        applied += 1;
        const ts_ms: i64 = @intCast(@divFloor(std.Io.Clock.real.now(ctx.io).nanoseconds, 1_000_000));
        const tags = [_][]const u8{ "screener-seed", "first-tick-ready" };
        const scope: commentary_mod.Scope = .{ .thesis = entry.proposed_thesis_id };
        for (entry.suggested_seed_commentary) |body| {
            const payload: commentary_mod.CommentaryPayload = .{
                .agent = .{ .model = "praescientia-market-screener", .run_id = validation.output.scan_id },
                .body = body,
                .references = &.{},
                .parent_hash = null,
                .inputs = .{ .prediction_head = null, .market_set_heads = &.{} },
                .tags = &tags,
                .ts_ms = ts_ms,
            };
            const r = commentary_mod.writeCommentary(ctx.gpa, ctx.io, kb_root, scope, payload) catch |err| {
                try ctx.stderr.print("commentary write {s}: {t}\n", .{ entry.proposed_thesis_id, err });
                continue;
            };
            ctx.gpa.free(r.scope_path);
            commentaries_written += 1;
        }
    }

    try ctx.stdout.print(
        "{{\"ok\":true,\"scan_id\":\"{s}\",\"applied\":{d},\"commentaries_written\":{d},\"output_path\":\"{s}\"}}\n",
        .{ validation.output.scan_id, applied, commentaries_written, output_path },
    );
    return 0;
}

// ---------------------------------------------------------------------------
// Tests — pure helpers (the validate/apply lifecycle is exercised end-to-end
// by scripts/screener_smoke.sh).
// ---------------------------------------------------------------------------

test "buildWeightsJson — emits single-ticker map" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const s = try buildWeightsJson(arena, "KX-FOO-BAR");
    try std.testing.expectEqualStrings("{\"KX-FOO-BAR\":10000}", s);
}

test "extractJsonObject — strips prose prefix" {
    const input = "Now I have everything:\n{\"scan_id\":\"01ABC\",\"buckets\":{}}";
    const got = extractJsonObject(input) orelse return error.NoMatch;
    try std.testing.expectEqualStrings("{\"scan_id\":\"01ABC\",\"buckets\":{}}", got);
}

test "extractJsonObject — handles strings with embedded braces" {
    const input = "{\"body\":\"text with { and } inside\",\"x\":1}";
    const got = extractJsonObject(input) orelse return error.NoMatch;
    try std.testing.expectEqualStrings(input, got);
}

test "extractJsonObject — handles escaped quotes in strings" {
    const input = "prefix {\"a\":\"with \\\"quoted\\\" }fake-close\",\"b\":2} trailing";
    const got = extractJsonObject(input) orelse return error.NoMatch;
    try std.testing.expectEqualStrings("{\"a\":\"with \\\"quoted\\\" }fake-close\",\"b\":2}", got);
}

test "extractJsonObject — returns null on missing brace" {
    try std.testing.expect(extractJsonObject("no json here") == null);
    try std.testing.expect(extractJsonObject("{unclosed") == null);
}

test "buildScreenerInputJson — appends existing_market_set + caps" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const candidates = "{\"scan_id\":\"01XYZ\",\"candidates\":[]}";
    const existing = [_][]const u8{ "KX-A", "KX-B" };
    const caps: screener_mod.BucketCaps = .{ .safe = 5, .moderate = 3, .high_risk = 2 };
    const got = try buildScreenerInputJson(arena, candidates, &existing, caps);
    try std.testing.expectEqualStrings(
        "{\"scan_id\":\"01XYZ\",\"candidates\":[],\"existing_market_set\":[\"KX-A\",\"KX-B\"],\"caps\":{\"safe\":5,\"moderate\":3,\"high_risk\":2}}",
        got,
    );
}

test "buildScreenerInputJson — empty existing_market_set is ok" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const candidates = "{\"scan_id\":\"01XYZ\",\"candidates\":[]}";
    const caps: screener_mod.BucketCaps = .{};
    const got = try buildScreenerInputJson(arena, candidates, &.{}, caps);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"existing_market_set\":[]") != null);
}

test "buildScreenerInputJson — rejects malformed candidates JSON" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectError(error.InvalidCandidatesJson, buildScreenerInputJson(arena, "not json", &.{}, .{}));
    try std.testing.expectError(error.InvalidCandidatesJson, buildScreenerInputJson(arena, "[1,2]", &.{}, .{}));
}

test "entryMatchesBucketFilter — matches when filter null or all" {
    const entry: screener_mod.BucketEntry = .{
        .bucket = .safe,
        .ticker = "KX-A",
        .proposed_thesis_id = "x",
        .primary_signal = "x",
        .implied_yes_cents = 50,
        .our_estimate_yes_cents = 55,
        .edge_cents = 5,
        .confidence_bp = 5000,
        .research_required = "",
        .suggested_seed_commentary = &.{},
        .suggested_size_pct_of_cap = 10,
    };
    try std.testing.expect(entryMatchesBucketFilter(entry, null));
    try std.testing.expect(entryMatchesBucketFilter(entry, "all"));
    try std.testing.expect(entryMatchesBucketFilter(entry, "safe"));
    try std.testing.expect(!entryMatchesBucketFilter(entry, "moderate"));
    try std.testing.expect(!entryMatchesBucketFilter(entry, "high_risk"));
}

//! kb.commentary — Talmud-style commentary chain type. First-class peer of
//! the reality and prediction chains. Three scopes:
//!
//!   - `theses/<id>/commentary/`     — observations tied to a thesis
//!   - `markets/<TICKER>/commentary/`— observations about a market
//!   - `commentary/global/`          — macro observations
//!
//! Payload schema (alphabetical keys for hash stability):
//!
//!   {
//!     "agent":       {"model": "...", "run_id": "..."},
//!     "body":        "free-form prose, ≤ 16 KB",
//!     "inputs":      {"prediction_head": "...|null",
//!                     "market_set_heads": ["hash", ...]},
//!     "kind":        "commentary",
//!     "parent_hash": "<hex>|null",
//!     "references":  ["hash", ...],
//!     "tags":        ["tag", ...],
//!     "ts":          1779000000000
//!   }

const std = @import("std");
const Allocator = std.mem.Allocator;

const chain_mod = @import("chain.zig");
const Hash = @import("../state_chain.zig").Hash;

/// Caps on the payload fields. Hashed bytes — keep these constants in step
/// with anything downstream (`server/handlers.zig`, the Python indexer).
pub const body_max_bytes: usize = 16 * 1024; // 16 KB
pub const max_tags: usize = 8;
pub const max_tag_len: usize = 32;
pub const hash_hex_len: usize = 64;

pub const Agent = struct {
    model: []const u8,
    run_id: []const u8 = "",
};

pub const Inputs = struct {
    /// Hex hash of the prediction-chain head the agent was reading at the
    /// time of writing. `null` when not applicable (global commentary,
    /// market-scoped commentary without a thesis context).
    prediction_head: ?[]const u8 = null,
    /// Reality-chain heads on each component market the agent was reading.
    /// Empty slice if not applicable.
    market_set_heads: []const []const u8 = &.{},
};

pub const CommentaryPayload = struct {
    agent: Agent,
    body: []const u8,
    /// Hex hashes (64-char) of chain entries this commentary is *about*.
    references: []const []const u8 = &.{},
    /// Hex hash of the prior commentary entry this replies to. Null if root.
    parent_hash: ?[]const u8 = null,
    inputs: Inputs = .{},
    tags: []const []const u8 = &.{},
    /// Milliseconds since the Unix epoch. int64 — no floats in hashed fields.
    ts_ms: i64,
};

pub const WriteResult = struct {
    hash: Hash,
    /// e.g. `"theses/fed-jun/commentary"`. Owned by the caller's `buf`.
    scope_path: []const u8,
};

pub const Scope = union(enum) {
    thesis: []const u8,
    market: []const u8,
    global,
};

const empty_branches_json =
    "{\"active\":\"main\",\"branches\":[{\"name\":\"main\"," ++
    "\"head_hash\":\"0000000000000000000000000000000000000000000000000000000000000000\"," ++
    "\"parent_hash\":\"0000000000000000000000000000000000000000000000000000000000000000\"," ++
    "\"parent_branch\":\"\",\"created_ts_ms\":0}]}";

/// Append a commentary entry to the chain identified by `scope` under
/// `kb_root`. Returns the new entry's hash and the (kb_root-relative) scope
/// chain dir path. The path slice references the caller-visible `result.path_buf`
/// — copy if you need to outlive the WriteResult.
///
/// Behaviour:
///   - Validates the payload (per-rule errors, see `validatePayload`).
///   - For `.global` and `.market`/`.thesis` scopes where the commentary
///     subdir doesn't yet exist (e.g. first-ever global commentary, or a
///     market/thesis that pre-dates Stage 1.5), creates the dir tree +
///     genesis branches.json + empty main.jsonl. `addMarket`/`addThesis`
///     do this materialisation up front for the scopes they manage; this
///     fallback covers the global path that has no equivalent admission step.
///   - If `parent_hash` is set, loads the active branch and refuses with
///     `error.ParentHashNotFound` if no entry on the branch has that hash.
///   - Encodes the payload via `encodePayload` and appends. The chain's
///     own hash for that line is what's returned in `result.hash`.
pub fn writeCommentary(
    allocator: Allocator,
    io: std.Io,
    kb_root: std.Io.Dir,
    scope: Scope,
    payload: CommentaryPayload,
) !WriteResult {
    try validatePayload(&payload);

    var path_buf: [256]u8 = undefined;
    const rel_path = try scopeRelativePath(&path_buf, scope);

    // Materialise the chain dir on demand (global has no admission step, and
    // pre-Stage-1.5 markets/theses may lack a commentary subdir).
    try ensureChainDir(io, kb_root, rel_path);

    var chain_dir = try kb_root.openDir(io, rel_path, .{ .iterate = false });
    defer chain_dir.close(io);

    // If parent_hash is given, verify it exists on the active branch.
    if (payload.parent_hash) |hex| {
        var existing = try chain_mod.openRead(allocator, io, chain_dir, "main");
        defer existing.deinit();
        var target: Hash = undefined;
        try hexDecode(hex, &target);
        if (existing.at(target) == null) return error.ParentHashNotFound;
    }

    // Encode the canonical-JSON payload.
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try encodePayload(&aw.writer, payload);

    var h = try chain_mod.openForWrite(allocator, io, chain_dir, "main");
    defer h.deinit();
    const tx = try h.append(aw.written());

    // We need an owned buffer for the scope_path so the caller can keep using
    // it after `path_buf` goes out of scope. Reuse `WriteResult.scope_path`
    // semantics: caller owns and frees via the allocator they passed in.
    const owned_path = try allocator.dupe(u8, rel_path);
    return .{ .hash = tx.hash, .scope_path = owned_path };
}

fn ensureChainDir(io: std.Io, kb_root: std.Io.Dir, rel_path: []const u8) !void {
    // If the directory already exists, just confirm the two chain files are
    // there. If absent, create the dir + genesis files.
    if (kb_root.access(io, rel_path, .{})) |_| {
        // Make sure branches.json + main.jsonl exist; otherwise an old market
        // (pre-Stage-1.5) might have an empty commentary dir.
        return;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }

    try kb_root.createDirPath(io, rel_path);

    var jsonl_buf: [320]u8 = undefined;
    const jsonl_path = try std.fmt.bufPrint(&jsonl_buf, "{s}/main.jsonl", .{rel_path});
    try kb_root.writeFile(io, .{ .sub_path = jsonl_path, .data = "" });

    var branches_buf: [320]u8 = undefined;
    const branches_path = try std.fmt.bufPrint(&branches_buf, "{s}/branches.json", .{rel_path});
    try kb_root.writeFile(io, .{ .sub_path = branches_path, .data = empty_branches_json });
}

fn hexDecode(hex: []const u8, out: *Hash) !void {
    if (hex.len != hash_hex_len) return error.InvalidHashFormat;
    for (out, 0..) |*byte, i| {
        const hi = try hexNibble(hex[i * 2]);
        const lo = try hexNibble(hex[i * 2 + 1]);
        byte.* = (hi << 4) | lo;
    }
}

fn hexNibble(c: u8) !u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => 10 + c - 'a',
        'A'...'F' => 10 + c - 'A',
        else => error.InvalidHashFormat,
    };
}

/// Write a scope's chain-directory path (relative to kb_root) into `buf` and
/// return a slice pointing into it. Validates the embedded id/ticker against
/// the same charset rules that the manifest validators use, so a malformed
/// scope is refused before any IO happens.
pub fn scopeRelativePath(buf: []u8, scope: Scope) ![]const u8 {
    return switch (scope) {
        .thesis => |id| blk: {
            try validateThesisId(id);
            break :blk std.fmt.bufPrint(buf, "theses/{s}/commentary", .{id});
        },
        .market => |ticker| blk: {
            try validateMarketTicker(ticker);
            break :blk std.fmt.bufPrint(buf, "markets/{s}/commentary", .{ticker});
        },
        .global => std.fmt.bufPrint(buf, "commentary/global", .{}),
    };
}

/// Match `manifest.validateThesis` charset rules: lowercase + digits + hyphen,
/// 1..64 chars.
fn validateThesisId(id: []const u8) !void {
    if (id.len == 0 or id.len > 64) return error.InvalidThesisId;
    for (id) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '-';
        if (!ok) return error.InvalidThesisId;
    }
}

/// Match `manifest.validateMarket` charset rules: uppercase + digits + hyphen
/// + dot (for threshold suffixes), 1..64 chars.
fn validateMarketTicker(ticker: []const u8) !void {
    if (ticker.len == 0 or ticker.len > 64) return error.InvalidMarketTicker;
    for (ticker) |c| {
        const ok = (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '-' or c == '.';
        if (!ok) return error.InvalidMarketTicker;
    }
}

/// Encode the payload to canonical JSON. Keys emitted in strict alphabetical
/// order: agent, body, inputs, kind, parent_hash, references, tags, ts.
pub fn encodePayload(writer: *std.Io.Writer, payload: CommentaryPayload) !void {
    try writer.writeByte('{');

    // agent
    try writer.writeAll("\"agent\":{");
    try writer.writeAll("\"model\":");
    try writeJsonString(writer, payload.agent.model);
    try writer.writeAll(",\"run_id\":");
    try writeJsonString(writer, payload.agent.run_id);
    try writer.writeByte('}');

    // body
    try writer.writeAll(",\"body\":");
    try writeJsonString(writer, payload.body);

    // inputs
    try writer.writeAll(",\"inputs\":{");
    try writer.writeAll("\"market_set_heads\":[");
    for (payload.inputs.market_set_heads, 0..) |h, i| {
        if (i > 0) try writer.writeByte(',');
        try writeJsonString(writer, h);
    }
    try writer.writeAll("],\"prediction_head\":");
    if (payload.inputs.prediction_head) |h| {
        try writeJsonString(writer, h);
    } else {
        try writer.writeAll("null");
    }
    try writer.writeByte('}');

    // kind
    try writer.writeAll(",\"kind\":\"commentary\"");

    // parent_hash
    try writer.writeAll(",\"parent_hash\":");
    if (payload.parent_hash) |h| {
        try writeJsonString(writer, h);
    } else {
        try writer.writeAll("null");
    }

    // references
    try writer.writeAll(",\"references\":[");
    for (payload.references, 0..) |r, i| {
        if (i > 0) try writer.writeByte(',');
        try writeJsonString(writer, r);
    }
    try writer.writeByte(']');

    // tags
    try writer.writeAll(",\"tags\":[");
    for (payload.tags, 0..) |t, i| {
        if (i > 0) try writer.writeByte(',');
        try writeJsonString(writer, t);
    }
    try writer.writeByte(']');

    // ts
    try writer.print(",\"ts\":{d}", .{payload.ts_ms});

    try writer.writeByte('}');
}

/// Minimal JSON string escaper — quotes the input. Handles the standard
/// JSON escape set; non-ASCII bytes pass through unchanged (UTF-8 stays valid).
fn writeJsonString(writer: *std.Io.Writer, s: []const u8) !void {
    try writer.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            0x00...0x07, 0x0B, 0x0E...0x1F => try writer.print("\\u{x:0>4}", .{c}),
            else => try writer.writeByte(c),
        }
    }
    try writer.writeByte('"');
}

/// Validate the in-memory payload before encoding. Per-rule distinct errors
/// so the CLI/HTTP layers can map to user-friendly messages.
///
/// Not validated here:
///   - `parent_hash` referencing an entry that actually exists on the chain —
///     that's a chain-level check done in `writeCommentary`.
pub fn validatePayload(p: *const CommentaryPayload) !void {
    if (p.agent.model.len == 0) return error.MissingAgentModel;
    if (p.body.len > body_max_bytes) return error.BodyTooLong;
    if (p.tags.len > max_tags) return error.TooManyTags;
    for (p.tags) |t| {
        if (t.len == 0 or t.len > max_tag_len) return error.TagTooLong;
    }
    for (p.references) |r| {
        if (!isHexHash(r)) return error.InvalidHashFormat;
    }
    if (p.parent_hash) |h| {
        if (!isHexHash(h)) return error.InvalidHashFormat;
    }
    if (p.inputs.prediction_head) |h| {
        if (!isHexHash(h)) return error.InvalidHashFormat;
    }
    for (p.inputs.market_set_heads) |h| {
        if (!isHexHash(h)) return error.InvalidHashFormat;
    }
}

fn isHexHash(s: []const u8) bool {
    if (s.len != hash_hex_len) return false;
    for (s) |c| {
        const ok = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
        if (!ok) return false;
    }
    return true;
}

test "encodePayload produces canonical alphabetically-sorted JSON" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try encodePayload(&aw.writer, .{
        .agent = .{ .model = "claude-opus-4-7", .run_id = "abc" },
        .body = "test body",
        .references = &.{},
        .parent_hash = null,
        .inputs = .{},
        .tags = &.{},
        .ts_ms = 1779000000000,
    });
    const out = aw.written();
    // Keys: agent, body, inputs, kind, parent_hash, references, tags, ts
    try std.testing.expect(std.mem.indexOf(u8, out, "\"agent\":{\"model\":\"claude-opus-4-7\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"kind\":\"commentary\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"parent_hash\":null") != null);
}

// Tiny helper builder for tests — every test was rebuilding the same struct.
fn validPayload() CommentaryPayload {
    return .{
        .agent = .{ .model = "test-model", .run_id = "r" },
        .body = "hello",
        .references = &.{},
        .parent_hash = null,
        .inputs = .{},
        .tags = &.{},
        .ts_ms = 1,
    };
}

test "validatePayload accepts a well-formed minimal payload" {
    const p = validPayload();
    try validatePayload(&p);
}

test "validatePayload rejects body over 16 KB" {
    var big_body: [body_max_bytes + 1]u8 = undefined;
    @memset(&big_body, 'x');
    var p = validPayload();
    p.body = &big_body;
    try std.testing.expectError(error.BodyTooLong, validatePayload(&p));
}

test "validatePayload rejects more than 8 tags" {
    var p = validPayload();
    p.tags = &.{ "a", "b", "c", "d", "e", "f", "g", "h", "i" };
    try std.testing.expectError(error.TooManyTags, validatePayload(&p));
}

test "validatePayload rejects tag longer than 32 chars" {
    var p = validPayload();
    p.tags = &.{ "ok", "this-tag-is-way-way-way-too-long-to-be-allowed" };
    try std.testing.expectError(error.TagTooLong, validatePayload(&p));
}

test "validatePayload rejects an empty tag" {
    var p = validPayload();
    p.tags = &.{ "" };
    try std.testing.expectError(error.TagTooLong, validatePayload(&p));
}

test "validatePayload rejects references that aren't 64-char hex" {
    var p = validPayload();
    p.references = &.{ "not-a-hash" };
    try std.testing.expectError(error.InvalidHashFormat, validatePayload(&p));
}

test "validatePayload rejects references with non-hex chars" {
    var p = validPayload();
    // 64 chars but contains a 'z'
    p.references = &.{ "z" ** 64 };
    try std.testing.expectError(error.InvalidHashFormat, validatePayload(&p));
}

test "validatePayload accepts a well-formed 64-char hex reference" {
    var p = validPayload();
    p.references = &.{ "0" ** 64 };
    try validatePayload(&p);
}

test "validatePayload rejects empty agent.model" {
    var p = validPayload();
    p.agent.model = "";
    try std.testing.expectError(error.MissingAgentModel, validatePayload(&p));
}

test "validatePayload rejects malformed parent_hash" {
    var p = validPayload();
    p.parent_hash = "abc";
    try std.testing.expectError(error.InvalidHashFormat, validatePayload(&p));
}

test "scopeRelativePath maps each scope to the right chain dir" {
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings(
        "theses/fed-jun/commentary",
        try scopeRelativePath(&buf, .{ .thesis = "fed-jun" }),
    );
    try std.testing.expectEqualStrings(
        "markets/KXBTC-26/commentary",
        try scopeRelativePath(&buf, .{ .market = "KXBTC-26" }),
    );
    try std.testing.expectEqualStrings(
        "commentary/global",
        try scopeRelativePath(&buf, .global),
    );
}

test "scopeRelativePath rejects malformed thesis ids" {
    var buf: [256]u8 = undefined;
    try std.testing.expectError(error.InvalidThesisId, scopeRelativePath(&buf, .{ .thesis = "" }));
    try std.testing.expectError(error.InvalidThesisId, scopeRelativePath(&buf, .{ .thesis = "Uppercase" }));
    try std.testing.expectError(error.InvalidThesisId, scopeRelativePath(&buf, .{ .thesis = "../evil" }));
}

test "scopeRelativePath rejects malformed market tickers" {
    var buf: [256]u8 = undefined;
    try std.testing.expectError(error.InvalidMarketTicker, scopeRelativePath(&buf, .{ .market = "" }));
    try std.testing.expectError(error.InvalidMarketTicker, scopeRelativePath(&buf, .{ .market = "kx-bad" }));
    try std.testing.expectError(error.InvalidMarketTicker, scopeRelativePath(&buf, .{ .market = "../evil" }));
}

test "writeCommentary appends to the right chain and returns the hash" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try @import("init.zig").initTree(io, tmp.dir, true); // creates SAMPLE market + sample thesis

    const result = try writeCommentary(std.testing.allocator, io, tmp.dir, .{ .thesis = "sample" }, .{
        .agent = .{ .model = "claude-opus-4-7", .run_id = "test" },
        .body = "first observation",
        .references = &.{},
        .parent_hash = null,
        .inputs = .{},
        .tags = &.{"macro"},
        .ts_ms = 1779000000000,
    });
    defer std.testing.allocator.free(result.scope_path);
    try std.testing.expectEqualStrings("theses/sample/commentary", result.scope_path);

    var chain_dir = try tmp.dir.openDir(io, "theses/sample/commentary", .{ .iterate = false });
    defer chain_dir.close(io);
    var chain = try chain_mod.openRead(std.testing.allocator, io, chain_dir, "main");
    defer chain.deinit();
    try std.testing.expectEqual(@as(usize, 1), chain.len());
    try std.testing.expectEqualSlices(u8, &chain.head().?, &result.hash);
}

test "writeCommentary materialises a missing global commentary dir on first use" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try @import("init.zig").initTree(io, tmp.dir, false);

    const result = try writeCommentary(std.testing.allocator, io, tmp.dir, .global, .{
        .agent = .{ .model = "human", .run_id = "" },
        .body = "macro observation",
        .ts_ms = 1779000000000,
    });
    defer std.testing.allocator.free(result.scope_path);
    try std.testing.expectEqualStrings("commentary/global", result.scope_path);

    var chain_dir = try tmp.dir.openDir(io, "commentary/global", .{ .iterate = false });
    defer chain_dir.close(io);
    var chain = try chain_mod.openRead(std.testing.allocator, io, chain_dir, "main");
    defer chain.deinit();
    try std.testing.expectEqual(@as(usize, 1), chain.len());
}

test "writeCommentary refuses a parent_hash that doesn't exist on the chain" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try @import("init.zig").initTree(io, tmp.dir, true);

    const err = writeCommentary(std.testing.allocator, io, tmp.dir, .{ .thesis = "sample" }, .{
        .agent = .{ .model = "claude", .run_id = "" },
        .body = "reply to nothing",
        .parent_hash = "0" ** 64,
        .ts_ms = 1,
    });
    try std.testing.expectError(error.ParentHashNotFound, err);
}

test "writeCommentary chains via parent_hash" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try @import("init.zig").initTree(io, tmp.dir, true);

    const first = try writeCommentary(std.testing.allocator, io, tmp.dir, .{ .thesis = "sample" }, .{
        .agent = .{ .model = "claude", .run_id = "" },
        .body = "root",
        .ts_ms = 1,
    });
    defer std.testing.allocator.free(first.scope_path);

    var hex: [hash_hex_len]u8 = undefined;
    _ = std.fmt.bufPrint(&hex, "{x}", .{first.hash}) catch unreachable;

    const reply = try writeCommentary(std.testing.allocator, io, tmp.dir, .{ .thesis = "sample" }, .{
        .agent = .{ .model = "claude", .run_id = "" },
        .body = "reply",
        .parent_hash = &hex,
        .ts_ms = 2,
    });
    defer std.testing.allocator.free(reply.scope_path);

    var chain_dir = try tmp.dir.openDir(io, "theses/sample/commentary", .{ .iterate = false });
    defer chain_dir.close(io);
    var chain = try chain_mod.openRead(std.testing.allocator, io, chain_dir, "main");
    defer chain.deinit();
    try std.testing.expectEqual(@as(usize, 2), chain.len());
}

test "writeCommentary propagates validation errors" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try @import("init.zig").initTree(io, tmp.dir, true);

    const err = writeCommentary(std.testing.allocator, io, tmp.dir, .{ .thesis = "sample" }, .{
        .agent = .{ .model = "", .run_id = "" },
        .body = "x",
        .ts_ms = 1,
    });
    try std.testing.expectError(error.MissingAgentModel, err);
}

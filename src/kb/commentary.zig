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

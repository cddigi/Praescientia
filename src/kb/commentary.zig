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

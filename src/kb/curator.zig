//! Schema + validator for the source-curator sub-agent's output.
//!
//! Mirrors `src/kb/screener.zig::validate` — the orchestrator parses agent
//! output through the greedy outer-`{}` extractor, then calls `validate()`
//! here to enforce the curator's hard invariants before `apply` persists
//! source-backed commentary:
//!
//!   1. `tick_id` echoes the dispatch's tick_id.
//!   2. `1 ≤ entries.length ≤ max_fetches`.
//!   3. `scope ∈ {thesis, market, global}`; `scope_key` required unless global.
//!   4. `source_tier` is one of the five *external* tiers (NOT model_synthesis —
//!      curator entries are by definition fetched, not synthesised).
//!   5. `source_url` is a non-empty http/https URL.
//!   6. body contains `source_url` inline (defence-in-depth) and, once the
//!      provenance frontmatter is prepended at apply-time, stays ≤ 16 KB.
//!   7. Per-tier TTL bound: `0 < valid_until_ms - fetch_ts_ms ≤ tierMax`.
//!   8. `valid_until_ms > now_ms + 60_000` (no pre-expired entries).
//!   9. No two entries share the same `source_url + scope + scope_key`.
//!  10. `references[]` are 64-char hex (chain-existence is checked at apply).
//!
//! Cross-KB URL-keyed replacement (the "if a non-expired entry with the same
//! URL already exists, replace not append" rule) is an apply-time concern that
//! needs chain access — it lives in tools/curator.zig, not here.

const std = @import("std");
const Allocator = std.mem.Allocator;
const commentary = @import("commentary.zig");

pub const SourceTier = commentary.SourceTier;

pub const Scope = enum {
    thesis,
    market,
    global,

    pub fn parse(s: []const u8) ?Scope {
        if (std.mem.eql(u8, s, "thesis")) return .thesis;
        if (std.mem.eql(u8, s, "market")) return .market;
        if (std.mem.eql(u8, s, "global")) return .global;
        return null;
    }

    pub fn key(self: Scope) []const u8 {
        return switch (self) {
            .thesis => "thesis",
            .market => "market",
            .global => "global",
        };
    }
};

/// Per-tier maximum TTL in milliseconds. Mirrors the bounds in the agent
/// prompt and IMPLEMENTATION_PLAN_source_curator.md Stage 2.
pub fn tierTtlMaxMs(tier: SourceTier) i64 {
    return switch (tier) {
        .primary => 30 * 24 * 60 * 60 * 1000, // 30 days
        .aggregator => 30 * 24 * 60 * 60 * 1000, // 30 days
        .news_org => 7 * 24 * 60 * 60 * 1000, // 7 days
        .forum => 24 * 60 * 60 * 1000, // 24 hours
        .sportsbook => 4 * 60 * 60 * 1000, // 4 hours
        .model_synthesis => std.math.maxInt(i64), // never used (rejected upstream)
    };
}

pub const CuratorEntry = struct {
    scope: Scope,
    scope_key: []const u8, // "" for global
    source_url: []const u8,
    source_tier: SourceTier,
    fetch_ts_ms: i64,
    valid_until_ms: i64,
    body: []const u8,
    tags: []const []const u8,
    references: []const []const u8,
};

pub const CuratorOutput = struct {
    tick_id: []const u8,
    entries: []const CuratorEntry,
    fetches_consumed: u32,
    summary: []const u8,
};

pub const ValidationError = error{
    JsonParseFailed,
    MissingTickId,
    TickIdMismatch,
    MissingEntries,
    EmptyEntries,
    TooManyEntries,
    MissingScope,
    UnknownScope,
    MissingScopeKey,
    MissingSourceTier,
    UnknownSourceTier,
    NonFetchableTier,
    InvalidSourceUrl,
    BodyTooLong,
    BodyMissingUrl,
    TtlOutOfBounds,
    EntryExpired,
    DuplicateSource,
    InvalidReference,
    OutOfMemory,
};

pub const ValidationResult = struct {
    output: CuratorOutput,
    /// Per-external-tier counts for the apply-time audit summary.
    counts: struct {
        primary: usize = 0,
        sportsbook: usize = 0,
        news_org: usize = 0,
        aggregator: usize = 0,
        forum: usize = 0,
    },
};

fn isHexHash(s: []const u8) bool {
    if (s.len != commentary.hash_hex_len) return false;
    for (s) |c| {
        const ok = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
        if (!ok) return false;
    }
    return true;
}

fn isHttpUrl(s: []const u8) bool {
    return std.mem.startsWith(u8, s, "http://") or std.mem.startsWith(u8, s, "https://");
}

/// Exact length of the provenance frontmatter line the applier will prepend,
/// including the trailing newline. Kept in step with commentary.zig's format:
///   "--- src: " + url + " fetched: " + ts + " valid_until: " + ts + " ---\n"
fn frontmatterLen(entry: CuratorEntry) usize {
    var n: usize = "--- src: ".len + " fetched: ".len + " valid_until: ".len + " ---\n".len;
    n += entry.source_url.len;
    n += isoLen(entry.fetch_ts_ms);
    n += isoLen(entry.valid_until_ms);
    return n;
}

/// The applier renders timestamps as the integer ms (the curator's contract
/// passes ISO strings, but to stay self-contained the applier writes the
/// numeric ms). 20 digits is the max for i64; use a safe upper bound.
fn isoLen(_: i64) usize {
    return 20;
}

pub fn validate(
    arena: Allocator,
    json_bytes: []const u8,
    expected_tick_id: []const u8,
    now_ms: i64,
    max_fetches: usize,
) ValidationError!ValidationResult {
    var parsed = std.json.parseFromSlice(std.json.Value, arena, json_bytes, .{}) catch return error.JsonParseFailed;
    defer parsed.deinit();
    if (parsed.value != .object) return error.JsonParseFailed;
    const root = parsed.value.object;

    const tick_v = root.get("tick_id") orelse return error.MissingTickId;
    if (tick_v != .string or tick_v.string.len == 0) return error.MissingTickId;
    if (!std.mem.eql(u8, tick_v.string, expected_tick_id)) return error.TickIdMismatch;

    const entries_v = root.get("entries") orelse return error.MissingEntries;
    if (entries_v != .array) return error.MissingEntries;
    if (entries_v.array.items.len == 0) return error.EmptyEntries;
    if (entries_v.array.items.len > max_fetches) return error.TooManyEntries;

    var entries_list: std.array_list.Managed(CuratorEntry) = .init(arena);
    var counts: @FieldType(ValidationResult, "counts") = .{};

    for (entries_v.array.items) |item| {
        if (item != .object) return error.MissingEntries;
        const entry = try parseEntry(arena, item.object, now_ms);

        // In-dispatch dedup on (source_url, scope, scope_key).
        for (entries_list.items) |prior| {
            if (prior.scope == entry.scope and
                std.mem.eql(u8, prior.scope_key, entry.scope_key) and
                std.mem.eql(u8, prior.source_url, entry.source_url))
            {
                return error.DuplicateSource;
            }
        }

        switch (entry.source_tier) {
            .primary => counts.primary += 1,
            .sportsbook => counts.sportsbook += 1,
            .news_org => counts.news_org += 1,
            .aggregator => counts.aggregator += 1,
            .forum => counts.forum += 1,
            .model_synthesis => unreachable, // rejected in parseEntry
        }
        try entries_list.append(entry);
    }

    const fetches_consumed: u32 = blk: {
        if (root.get("fetches_consumed")) |v| {
            if (v == .integer and v.integer >= 0) break :blk @intCast(v.integer);
        }
        break :blk 0;
    };
    const summary = blk: {
        if (root.get("summary")) |v| {
            if (v == .string) break :blk v.string;
        }
        break :blk "";
    };

    return .{
        .output = .{
            .tick_id = tick_v.string,
            .entries = entries_list.items,
            .fetches_consumed = fetches_consumed,
            .summary = summary,
        },
        .counts = counts,
    };
}

fn parseEntry(arena: Allocator, obj: std.json.ObjectMap, now_ms: i64) ValidationError!CuratorEntry {
    const scope_v = obj.get("scope") orelse return error.MissingScope;
    if (scope_v != .string) return error.MissingScope;
    const scope = Scope.parse(scope_v.string) orelse return error.UnknownScope;

    const scope_key: []const u8 = blk: {
        if (scope == .global) break :blk "";
        const k = obj.get("scope_key") orelse return error.MissingScopeKey;
        if (k != .string or k.string.len == 0) return error.MissingScopeKey;
        break :blk k.string;
    };

    const tier_v = obj.get("source_tier") orelse return error.MissingSourceTier;
    if (tier_v != .string) return error.MissingSourceTier;
    const tier = SourceTier.parse(tier_v.string) orelse return error.UnknownSourceTier;
    if (tier == .model_synthesis) return error.NonFetchableTier;

    const url_v = obj.get("source_url") orelse return error.InvalidSourceUrl;
    if (url_v != .string or url_v.string.len == 0 or !isHttpUrl(url_v.string)) return error.InvalidSourceUrl;
    const source_url = url_v.string;

    const fetch_ts_ms = intField(obj, "fetch_ts_ms") orelse return error.TtlOutOfBounds;
    const valid_until_ms = intField(obj, "valid_until_ms") orelse return error.TtlOutOfBounds;

    const ttl = valid_until_ms - fetch_ts_ms;
    if (ttl <= 0 or ttl > tierTtlMaxMs(tier)) return error.TtlOutOfBounds;
    if (valid_until_ms <= now_ms + 60_000) return error.EntryExpired;

    const body_v = obj.get("body") orelse return error.BodyTooLong;
    if (body_v != .string) return error.BodyTooLong;
    const body = body_v.string;
    if (std.mem.indexOf(u8, body, source_url) == null) return error.BodyMissingUrl;

    const entry: CuratorEntry = .{
        .scope = scope,
        .scope_key = scope_key,
        .source_url = source_url,
        .source_tier = tier,
        .fetch_ts_ms = fetch_ts_ms,
        .valid_until_ms = valid_until_ms,
        .body = body,
        .tags = try parseStringArray(arena, obj, "tags"),
        .references = try parseStringArray(arena, obj, "references"),
    };

    // body + prepended frontmatter must stay under the chain cap.
    if (body.len + frontmatterLen(entry) > commentary.body_max_bytes) return error.BodyTooLong;

    for (entry.references) |r| {
        if (!isHexHash(r)) return error.InvalidReference;
    }

    return entry;
}

fn parseStringArray(arena: Allocator, obj: std.json.ObjectMap, key: []const u8) ValidationError![]const []const u8 {
    const v = obj.get(key) orelse return &.{};
    if (v != .array) return &.{};
    var list: std.array_list.Managed([]const u8) = .init(arena);
    for (v.array.items) |item| {
        if (item != .string) continue;
        try list.append(item.string);
    }
    return list.items;
}

fn intField(obj: std.json.ObjectMap, key: []const u8) ?i64 {
    const v = obj.get(key) orelse return null;
    if (v != .integer) return null;
    return v.integer;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const test_tick = "01KSAJM77VV5D749D7ZE9X1V45";
// now = 2026-05-23T00:00:00Z-ish; entries fetched ~now with 30-day TTL.
const test_now: i64 = 1779840000000;
const test_fetch: i64 = 1779840000000;
const test_valid: i64 = 1779840000000 + 7 * 24 * 60 * 60 * 1000; // +7d, within primary/news bounds

fn validBody() []const u8 {
    return "Eurostat flash HICP 3.0% YoY, see https://ec.europa.eu/eurostat/x for detail.";
}

fn oneEntryJson(arena: Allocator, overrides: []const u8) ![]const u8 {
    _ = overrides;
    return std.fmt.allocPrint(arena,
        \\{{"tick_id":"{s}","entries":[{{"scope":"thesis","scope_key":"eu-cpi","source_url":"https://ec.europa.eu/eurostat/x","source_tier":"primary","fetch_ts_ms":{d},"valid_until_ms":{d},"body":"Eurostat flash HICP 3.0% YoY, see https://ec.europa.eu/eurostat/x for detail.","tags":["eu-cpi","source:primary"],"references":[]}}],"fetches_consumed":2,"summary":"ok"}}
    , .{ test_tick, test_fetch, test_valid });
}

test "validate — positive single primary entry" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const body = try oneEntryJson(arena, "");
    const result = try validate(arena, body, test_tick, test_now, 5);
    try std.testing.expectEqual(@as(usize, 1), result.output.entries.len);
    try std.testing.expectEqual(@as(usize, 1), result.counts.primary);
    try std.testing.expectEqual(Scope.thesis, result.output.entries[0].scope);
}

test "validate — rejects tick_id mismatch" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const body = try oneEntryJson(arena, "");
    try std.testing.expectError(error.TickIdMismatch, validate(arena, body, "01WRONGTICK0000000000000000", test_now, 5));
}

test "validate — rejects empty entries" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const body = try std.fmt.allocPrint(arena, "{{\"tick_id\":\"{s}\",\"entries\":[],\"fetches_consumed\":0,\"summary\":\"\"}}", .{test_tick});
    try std.testing.expectError(error.EmptyEntries, validate(arena, body, test_tick, test_now, 5));
}

test "validate — rejects more entries than max_fetches" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const body = try oneEntryJson(arena, "");
    try std.testing.expectError(error.TooManyEntries, validate(arena, body, test_tick, test_now, 0));
}

test "validate — rejects model_synthesis tier (non-fetchable)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const body = try std.fmt.allocPrint(arena,
        \\{{"tick_id":"{s}","entries":[{{"scope":"thesis","scope_key":"x","source_url":"https://x.test/a","source_tier":"model_synthesis","fetch_ts_ms":{d},"valid_until_ms":{d},"body":"see https://x.test/a","tags":[],"references":[]}}],"fetches_consumed":0,"summary":""}}
    , .{ test_tick, test_fetch, test_valid });
    try std.testing.expectError(error.NonFetchableTier, validate(arena, body, test_tick, test_now, 5));
}

test "validate — rejects non-http source_url" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const body = try std.fmt.allocPrint(arena,
        \\{{"tick_id":"{s}","entries":[{{"scope":"thesis","scope_key":"x","source_url":"ftp://x.test/a","source_tier":"primary","fetch_ts_ms":{d},"valid_until_ms":{d},"body":"see ftp://x.test/a","tags":[],"references":[]}}],"fetches_consumed":0,"summary":""}}
    , .{ test_tick, test_fetch, test_valid });
    try std.testing.expectError(error.InvalidSourceUrl, validate(arena, body, test_tick, test_now, 5));
}

test "validate — rejects body missing the source_url inline" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const body = try std.fmt.allocPrint(arena,
        \\{{"tick_id":"{s}","entries":[{{"scope":"thesis","scope_key":"x","source_url":"https://x.test/a","source_tier":"primary","fetch_ts_ms":{d},"valid_until_ms":{d},"body":"prose with no url at all","tags":[],"references":[]}}],"fetches_consumed":0,"summary":""}}
    , .{ test_tick, test_fetch, test_valid });
    try std.testing.expectError(error.BodyMissingUrl, validate(arena, body, test_tick, test_now, 5));
}

test "validate — rejects TTL beyond the tier bound" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // sportsbook bound is 4h; give it 7 days.
    const body = try std.fmt.allocPrint(arena,
        \\{{"tick_id":"{s}","entries":[{{"scope":"thesis","scope_key":"x","source_url":"https://x.test/a","source_tier":"sportsbook","fetch_ts_ms":{d},"valid_until_ms":{d},"body":"see https://x.test/a","tags":[],"references":[]}}],"fetches_consumed":0,"summary":""}}
    , .{ test_tick, test_fetch, test_valid });
    try std.testing.expectError(error.TtlOutOfBounds, validate(arena, body, test_tick, test_now, 5));
}

test "validate — rejects an already-expired entry" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // valid_until in the past relative to now.
    const past_fetch: i64 = test_now - 10 * 24 * 60 * 60 * 1000;
    const past_valid: i64 = test_now - 1000;
    const body = try std.fmt.allocPrint(arena,
        \\{{"tick_id":"{s}","entries":[{{"scope":"thesis","scope_key":"x","source_url":"https://x.test/a","source_tier":"primary","fetch_ts_ms":{d},"valid_until_ms":{d},"body":"see https://x.test/a","tags":[],"references":[]}}],"fetches_consumed":0,"summary":""}}
    , .{ test_tick, past_fetch, past_valid });
    try std.testing.expectError(error.EntryExpired, validate(arena, body, test_tick, test_now, 5));
}

test "validate — rejects duplicate source within the dispatch" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const body = try std.fmt.allocPrint(arena,
        \\{{"tick_id":"{s}","entries":[
        \\{{"scope":"thesis","scope_key":"x","source_url":"https://x.test/a","source_tier":"primary","fetch_ts_ms":{d},"valid_until_ms":{d},"body":"see https://x.test/a","tags":[],"references":[]}},
        \\{{"scope":"thesis","scope_key":"x","source_url":"https://x.test/a","source_tier":"news_org","fetch_ts_ms":{d},"valid_until_ms":{d},"body":"see https://x.test/a again","tags":[],"references":[]}}
        \\],"fetches_consumed":2,"summary":""}}
    , .{ test_tick, test_fetch, test_valid, test_fetch, test_valid });
    try std.testing.expectError(error.DuplicateSource, validate(arena, body, test_tick, test_now, 5));
}

test "validate — rejects a non-hex reference" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const body = try std.fmt.allocPrint(arena,
        \\{{"tick_id":"{s}","entries":[{{"scope":"thesis","scope_key":"x","source_url":"https://x.test/a","source_tier":"primary","fetch_ts_ms":{d},"valid_until_ms":{d},"body":"see https://x.test/a","tags":[],"references":["not-a-hash"]}}],"fetches_consumed":0,"summary":""}}
    , .{ test_tick, test_fetch, test_valid });
    try std.testing.expectError(error.InvalidReference, validate(arena, body, test_tick, test_now, 5));
}

test "validate — global scope needs no scope_key" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const body = try std.fmt.allocPrint(arena,
        \\{{"tick_id":"{s}","entries":[{{"scope":"global","source_url":"https://x.test/a","source_tier":"primary","fetch_ts_ms":{d},"valid_until_ms":{d},"body":"see https://x.test/a","tags":[],"references":[]}}],"fetches_consumed":0,"summary":""}}
    , .{ test_tick, test_fetch, test_valid });
    const result = try validate(arena, body, test_tick, test_now, 5);
    try std.testing.expectEqual(Scope.global, result.output.entries[0].scope);
    try std.testing.expectEqualStrings("", result.output.entries[0].scope_key);
}

test "tierTtlMaxMs — bounds per tier" {
    try std.testing.expectEqual(@as(i64, 30 * 24 * 60 * 60 * 1000), tierTtlMaxMs(.primary));
    try std.testing.expectEqual(@as(i64, 7 * 24 * 60 * 60 * 1000), tierTtlMaxMs(.news_org));
    try std.testing.expectEqual(@as(i64, 24 * 60 * 60 * 1000), tierTtlMaxMs(.forum));
    try std.testing.expectEqual(@as(i64, 4 * 60 * 60 * 1000), tierTtlMaxMs(.sportsbook));
}

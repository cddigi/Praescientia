//! Schema + validator for the market-screener sub-agent's output.
//!
//! Mirrors the role `src/kb/ticks.zig::validateDecision` plays for the
//! thesis-analyst — the orchestrator parses agent output through the
//! greedy outer-`{}` extractor, then calls `validate()` here to enforce
//! the screener's hard invariants:
//!
//!   1. Every ticker in any bucket MUST NOT appear in `existing_market_set`
//!      (no thesis is re-proposed for a market we already track).
//!   2. Every bucket entry has ≥2 `suggested_seed_commentary` entries
//!      (the §6.b two-neighbors precondition is satisfiable at apply-time).
//!   3. `confidence_bp ∈ [0, 10000]`.
//!   4. `proposed_thesis_id` matches `^[a-z][a-z0-9-]+$` (kebab slug).
//!   5. `bucket ∈ {safe, moderate, high_risk}`.
//!   6. `primary_signal` non-empty.
//!   7. `our_estimate_yes_cents` and `implied_yes_cents` ∈ [0, 100].
//!   8. Bucket counts ≤ caps (default safe=5, moderate=3, high_risk=2;
//!      operator-overridable via `BucketCaps`).

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const BucketKind = enum {
    safe,
    moderate,
    high_risk,

    pub fn parse(s: []const u8) ?BucketKind {
        if (std.mem.eql(u8, s, "safe")) return .safe;
        if (std.mem.eql(u8, s, "moderate")) return .moderate;
        if (std.mem.eql(u8, s, "high_risk")) return .high_risk;
        return null;
    }

    pub fn key(self: BucketKind) []const u8 {
        return switch (self) {
            .safe => "safe",
            .moderate => "moderate",
            .high_risk => "high_risk",
        };
    }
};

pub const BucketCaps = struct {
    safe: usize = 5,
    moderate: usize = 3,
    high_risk: usize = 2,

    pub fn cap(self: BucketCaps, kind: BucketKind) usize {
        return switch (kind) {
            .safe => self.safe,
            .moderate => self.moderate,
            .high_risk => self.high_risk,
        };
    }
};

/// One bucket entry — the agent's proposal for a single market.
pub const BucketEntry = struct {
    bucket: BucketKind,
    ticker: []const u8,
    proposed_thesis_id: []const u8,
    primary_signal: []const u8,
    implied_yes_cents: i32,
    our_estimate_yes_cents: i32,
    edge_cents: i32,
    confidence_bp: u32,
    research_required: []const u8,
    suggested_seed_commentary: []const []const u8,
    suggested_size_pct_of_cap: u32,
};

/// Full agent output — the canonical screener product per scan.
pub const ScreenerOutput = struct {
    scan_id: []const u8,
    scan_ts_ms: i64,
    candidates_evaluated: u32,
    buckets: []const BucketEntry,
    skipped: []const Skipped,

    pub const Skipped = struct {
        ticker: []const u8,
        reason: []const u8,
    };
};

pub const ValidationError = error{
    JsonParseFailed,
    MissingScanId,
    MissingBuckets,
    MissingCandidate,
    UnknownBucketKind,
    InvalidThesisId,
    EmptyPrimarySignal,
    ConfidenceOutOfRange,
    PriceOutOfRange,
    EdgeMismatch,
    TickerDuplicatesExisting,
    InsufficientNeighbors,
    SizePctOutOfRange,
    BucketCapExceeded,
    OutOfMemory,
};

pub const ValidationResult = struct {
    output: ScreenerOutput,
    /// Per-bucket count for the operator's audit summary.
    counts: struct {
        safe: usize,
        moderate: usize,
        high_risk: usize,
    },
};

/// Slug pattern: starts with lowercase letter, then lowercase / digit /
/// hyphen. Length 3..64 (arbitrary but enough to spot typos).
fn isValidSlug(s: []const u8) bool {
    if (s.len < 3 or s.len > 64) return false;
    if (!std.ascii.isLower(s[0])) return false;
    for (s) |c| {
        if (!(std.ascii.isLower(c) or std.ascii.isDigit(c) or c == '-')) return false;
    }
    return true;
}

fn entryHasExistingTicker(entry: BucketEntry, existing: []const []const u8) bool {
    for (existing) |t| if (std.mem.eql(u8, t, entry.ticker)) return true;
    return false;
}

/// Validate a screener output. Caller owns the JSON bytes; the parsed
/// arena-bound result references slices in that JSON. The arena must
/// outlive any use of the returned ValidationResult.
pub fn validate(
    arena: Allocator,
    json_bytes: []const u8,
    existing_market_set: []const []const u8,
    caps: BucketCaps,
) ValidationError!ValidationResult {
    var parsed = std.json.parseFromSlice(std.json.Value, arena, json_bytes, .{}) catch return error.JsonParseFailed;
    defer parsed.deinit();
    if (parsed.value != .object) return error.JsonParseFailed;
    const root = parsed.value.object;

    const scan_id_v = root.get("scan_id") orelse return error.MissingScanId;
    if (scan_id_v != .string or scan_id_v.string.len == 0) return error.MissingScanId;

    const scan_ts_ms: i64 = blk: {
        if (root.get("scan_ts_ms")) |v| {
            if (v == .integer) break :blk v.integer;
        }
        break :blk 0;
    };
    const candidates_evaluated: u32 = blk: {
        if (root.get("candidates_evaluated")) |v| {
            if (v == .integer and v.integer >= 0) break :blk @intCast(v.integer);
        }
        break :blk 0;
    };

    const buckets_v = root.get("buckets") orelse return error.MissingBuckets;
    if (buckets_v != .object) return error.MissingBuckets;

    var entries_list: std.array_list.Managed(BucketEntry) = .init(arena);
    var counts: struct { safe: usize, moderate: usize, high_risk: usize } = .{ .safe = 0, .moderate = 0, .high_risk = 0 };

    const all_kinds = [_]BucketKind{ .safe, .moderate, .high_risk };
    for (all_kinds) |kind| {
        const arr_v = buckets_v.object.get(kind.key()) orelse continue;
        if (arr_v != .array) return error.MissingBuckets;
        for (arr_v.array.items) |item| {
            if (item != .object) return error.MissingCandidate;
            const entry = try parseBucketEntry(arena, kind, item.object);
            // Per-bucket cap
            const cap_n = caps.cap(kind);
            switch (kind) {
                .safe => if (counts.safe >= cap_n) return error.BucketCapExceeded,
                .moderate => if (counts.moderate >= cap_n) return error.BucketCapExceeded,
                .high_risk => if (counts.high_risk >= cap_n) return error.BucketCapExceeded,
            }
            // Existing-ticker dedup
            if (entryHasExistingTicker(entry, existing_market_set)) return error.TickerDuplicatesExisting;
            try entries_list.append(entry);
            switch (kind) {
                .safe => counts.safe += 1,
                .moderate => counts.moderate += 1,
                .high_risk => counts.high_risk += 1,
            }
        }
    }

    var skipped_list: std.array_list.Managed(ScreenerOutput.Skipped) = .init(arena);
    if (root.get("skipped")) |sv| {
        if (sv == .array) {
            for (sv.array.items) |item| {
                if (item != .object) continue;
                const t_v = item.object.get("ticker") orelse continue;
                const r_v = item.object.get("reason") orelse continue;
                if (t_v != .string or r_v != .string) continue;
                try skipped_list.append(.{ .ticker = t_v.string, .reason = r_v.string });
            }
        }
    }

    return .{
        .output = .{
            .scan_id = scan_id_v.string,
            .scan_ts_ms = scan_ts_ms,
            .candidates_evaluated = candidates_evaluated,
            .buckets = entries_list.items,
            .skipped = skipped_list.items,
        },
        .counts = .{
            .safe = counts.safe,
            .moderate = counts.moderate,
            .high_risk = counts.high_risk,
        },
    };
}

fn parseBucketEntry(
    arena: Allocator,
    kind: BucketKind,
    obj: std.json.ObjectMap,
) ValidationError!BucketEntry {
    const ticker = stringField(obj, "ticker") orelse return error.MissingCandidate;
    if (ticker.len == 0) return error.MissingCandidate;

    const tid = stringField(obj, "proposed_thesis_id") orelse return error.InvalidThesisId;
    if (!isValidSlug(tid)) return error.InvalidThesisId;

    const ps = stringField(obj, "primary_signal") orelse return error.EmptyPrimarySignal;
    if (ps.len == 0) return error.EmptyPrimarySignal;

    const implied_y: i32 = try intField(obj, "implied_yes_cents", 0, 100);
    const our_y: i32 = try intField(obj, "our_estimate_yes_cents", 0, 100);
    const edge: i32 = blk: {
        if (obj.get("edge_cents")) |v| {
            if (v == .integer and v.integer >= -100 and v.integer <= 100) break :blk @intCast(v.integer);
        }
        break :blk 0;
    };
    // Edge must equal |our - implied| within 1c tolerance — keeps the
    // agent honest about its own math.
    const diff: i32 = our_y - implied_y;
    const expected_edge: i32 = if (diff < 0) -diff else diff;
    const reported: i32 = if (edge < 0) -edge else edge;
    const drift: i32 = reported - expected_edge;
    const drift_abs: i32 = if (drift < 0) -drift else drift;
    if (drift_abs > 1) return error.EdgeMismatch;

    const conf_v = obj.get("confidence_bp") orelse return error.ConfidenceOutOfRange;
    if (conf_v != .integer or conf_v.integer < 0 or conf_v.integer > 10000) return error.ConfidenceOutOfRange;
    const confidence_bp: u32 = @intCast(conf_v.integer);

    const research_required = stringField(obj, "research_required") orelse "";

    const seed_arr_v = obj.get("suggested_seed_commentary") orelse return error.InsufficientNeighbors;
    if (seed_arr_v != .array) return error.InsufficientNeighbors;
    if (seed_arr_v.array.items.len < 2) return error.InsufficientNeighbors;
    var seeds: std.array_list.Managed([]const u8) = .init(arena);
    for (seed_arr_v.array.items) |s| {
        if (s != .string or s.string.len == 0) return error.InsufficientNeighbors;
        try seeds.append(s.string);
    }

    const size_pct: u32 = blk: {
        if (obj.get("suggested_size_pct_of_cap")) |v| {
            if (v != .integer or v.integer < 0 or v.integer > 100) return error.SizePctOutOfRange;
            break :blk @intCast(v.integer);
        }
        break :blk 0;
    };

    return .{
        .bucket = kind,
        .ticker = ticker,
        .proposed_thesis_id = tid,
        .primary_signal = ps,
        .implied_yes_cents = implied_y,
        .our_estimate_yes_cents = our_y,
        .edge_cents = edge,
        .confidence_bp = confidence_bp,
        .research_required = research_required,
        .suggested_seed_commentary = seeds.items,
        .suggested_size_pct_of_cap = size_pct,
    };
}

fn stringField(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    if (v != .string) return null;
    return v.string;
}

fn intField(obj: std.json.ObjectMap, key: []const u8, lo: i64, hi: i64) ValidationError!i32 {
    const v = obj.get(key) orelse return error.PriceOutOfRange;
    if (v != .integer) return error.PriceOutOfRange;
    if (v.integer < lo or v.integer > hi) return error.PriceOutOfRange;
    return @intCast(v.integer);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const test_caps: BucketCaps = .{};

const valid_output =
    \\{
    \\  "scan_id": "01TESTSCAN0000000000000001",
    \\  "scan_ts_ms": 1779255000000,
    \\  "candidates_evaluated": 7,
    \\  "buckets": {
    \\    "safe": [
    \\      {
    \\        "ticker": "KX-SAFE-1",
    \\        "proposed_thesis_id": "safe-bet-1",
    \\        "primary_signal": "ladder-sum-arb",
    \\        "implied_yes_cents": 95,
    \\        "our_estimate_yes_cents": 98,
    \\        "edge_cents": 3,
    \\        "confidence_bp": 8000,
    \\        "research_required": "minimal — structural play",
    \\        "suggested_seed_commentary": ["seed 1 body","seed 2 body"],
    \\        "suggested_size_pct_of_cap": 60
    \\      }
    \\    ],
    \\    "moderate": [],
    \\    "high_risk": []
    \\  },
    \\  "skipped": [
    \\    {"ticker": "KX-OTHER", "reason": "no researchable underlying"}
    \\  ]
    \\}
;

test "validate — positive case" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const result = try validate(arena, valid_output, &.{}, test_caps);
    try std.testing.expectEqualStrings("01TESTSCAN0000000000000001", result.output.scan_id);
    try std.testing.expectEqual(@as(usize, 1), result.output.buckets.len);
    try std.testing.expectEqual(@as(usize, 1), result.output.skipped.len);
    try std.testing.expectEqual(@as(usize, 1), result.counts.safe);
    try std.testing.expectEqual(@as(usize, 0), result.counts.moderate);
    try std.testing.expectEqual(@as(usize, 0), result.counts.high_risk);
}

test "validate — rejects ticker that duplicates existing thesis" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const existing = [_][]const u8{"KX-SAFE-1"};
    try std.testing.expectError(error.TickerDuplicatesExisting, validate(arena, valid_output, &existing, test_caps));
}

test "validate — rejects fewer than 2 seed commentaries" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const body =
        \\{"scan_id":"01TESTSCAN0000000000000001","scan_ts_ms":0,"candidates_evaluated":1,"buckets":{"safe":[{"ticker":"KX-A","proposed_thesis_id":"safe-bet-1","primary_signal":"x","implied_yes_cents":50,"our_estimate_yes_cents":55,"edge_cents":5,"confidence_bp":6000,"research_required":"x","suggested_seed_commentary":["only one"],"suggested_size_pct_of_cap":20}],"moderate":[],"high_risk":[]},"skipped":[]}
    ;
    try std.testing.expectError(error.InsufficientNeighbors, validate(arena, body, &.{}, test_caps));
}

test "validate — rejects bucket cap overflow" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // moderate cap is 3 by default — pass 4 entries
    const body =
        \\{"scan_id":"01TESTSCAN0000000000000001","scan_ts_ms":0,"candidates_evaluated":4,"buckets":{"safe":[],"moderate":[
        \\{"ticker":"KX-M1","proposed_thesis_id":"mod-1","primary_signal":"x","implied_yes_cents":50,"our_estimate_yes_cents":55,"edge_cents":5,"confidence_bp":5000,"research_required":"x","suggested_seed_commentary":["a","b"],"suggested_size_pct_of_cap":20},
        \\{"ticker":"KX-M2","proposed_thesis_id":"mod-2","primary_signal":"x","implied_yes_cents":50,"our_estimate_yes_cents":55,"edge_cents":5,"confidence_bp":5000,"research_required":"x","suggested_seed_commentary":["a","b"],"suggested_size_pct_of_cap":20},
        \\{"ticker":"KX-M3","proposed_thesis_id":"mod-3","primary_signal":"x","implied_yes_cents":50,"our_estimate_yes_cents":55,"edge_cents":5,"confidence_bp":5000,"research_required":"x","suggested_seed_commentary":["a","b"],"suggested_size_pct_of_cap":20},
        \\{"ticker":"KX-M4","proposed_thesis_id":"mod-4","primary_signal":"x","implied_yes_cents":50,"our_estimate_yes_cents":55,"edge_cents":5,"confidence_bp":5000,"research_required":"x","suggested_seed_commentary":["a","b"],"suggested_size_pct_of_cap":20}],
        \\"high_risk":[]},"skipped":[]}
    ;
    try std.testing.expectError(error.BucketCapExceeded, validate(arena, body, &.{}, test_caps));
}

test "validate — rejects invalid slug" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const body =
        \\{"scan_id":"01TESTSCAN0000000000000001","scan_ts_ms":0,"candidates_evaluated":1,"buckets":{"safe":[{"ticker":"KX-A","proposed_thesis_id":"BadSlug!With_Underscore","primary_signal":"x","implied_yes_cents":50,"our_estimate_yes_cents":55,"edge_cents":5,"confidence_bp":5000,"research_required":"x","suggested_seed_commentary":["a","b"],"suggested_size_pct_of_cap":20}],"moderate":[],"high_risk":[]},"skipped":[]}
    ;
    try std.testing.expectError(error.InvalidThesisId, validate(arena, body, &.{}, test_caps));
}

test "validate — rejects edge math mismatch" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // edge_cents=20 but |55-50|=5 — should reject
    const body =
        \\{"scan_id":"01TESTSCAN0000000000000001","scan_ts_ms":0,"candidates_evaluated":1,"buckets":{"safe":[{"ticker":"KX-A","proposed_thesis_id":"safe-bet-1","primary_signal":"x","implied_yes_cents":50,"our_estimate_yes_cents":55,"edge_cents":20,"confidence_bp":5000,"research_required":"x","suggested_seed_commentary":["a","b"],"suggested_size_pct_of_cap":20}],"moderate":[],"high_risk":[]},"skipped":[]}
    ;
    try std.testing.expectError(error.EdgeMismatch, validate(arena, body, &.{}, test_caps));
}

test "validate — rejects malformed JSON" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectError(error.JsonParseFailed, validate(arena, "not json", &.{}, test_caps));
}

test "isValidSlug — kebab patterns" {
    try std.testing.expect(isValidSlug("safe-bet-1"));
    try std.testing.expect(isValidSlug("mlb-lad-sd-total-14"));
    try std.testing.expect(!isValidSlug("Safe-Bet"));
    try std.testing.expect(!isValidSlug("safe_bet"));
    try std.testing.expect(!isValidSlug("-leading-hyphen"));
    try std.testing.expect(!isValidSlug("12-leading-digit"));
    try std.testing.expect(!isValidSlug("ab"));
}

test "BucketKind.parse — round trip" {
    try std.testing.expectEqual(@as(?BucketKind, .safe), BucketKind.parse("safe"));
    try std.testing.expectEqual(@as(?BucketKind, .moderate), BucketKind.parse("moderate"));
    try std.testing.expectEqual(@as(?BucketKind, .high_risk), BucketKind.parse("high_risk"));
    try std.testing.expectEqual(@as(?BucketKind, null), BucketKind.parse("unknown"));
}

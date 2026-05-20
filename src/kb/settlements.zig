//! Transform Kalshi `/portfolio/settlements` records into §8 Settlement
//! shapes the orchestrator's loss-reflection dispatch consumes.
//!
//! One Kalshi record may produce 0, 1, or 2 §8 Settlements:
//!   * Voided market — 0 (no winner; nothing to classify)
//!   * Held one side only — 1
//!   * Held both sides — 2 (the orchestrator dispatches independently per
//!     side; both could be wins, both losses, or split, depending on
//!     `market_result`)
//!
//! Output is emitted as a distinct `OutSettlement` rather than the in-memory
//! `ticks.Settlement` so JSON serialization stays stable across enum-tag
//! changes: `our_held_side` is the lowercase string `"yes"` or `"no"`.

const std = @import("std");
const portfolio = @import("../kalshi/portfolio.zig");
const ticks = @import("ticks.zig");

/// JSON-stable output shape. Matches `tests/fixtures/settlements/*.json`
/// so the orchestrator can pipe `transformAll` output straight into
/// `praescientia-ticks classify-resolution --settlement=PATH`.
pub const OutSettlement = struct {
    ticker: []const u8,
    resolved_yes: bool,
    resolution_ts_ms: i64,
    our_held_side: []const u8, // "yes" or "no"
    our_contracts: u32,
    realized_pnl_cents: i64,
};

/// Final CLI output shape: `{next_cursor, settlements: []}`.
pub const TransformedPage = struct {
    next_cursor: []const u8,
    settlements: []const OutSettlement,
};

/// Transform one Kalshi record. Returns 0/1/2 entries appended to `out`.
/// `arena` owns any duplicated strings; the caller must keep it alive for
/// the lifetime of the emitted entries.
///
/// Parses the string-formatted Kalshi fields into typed values:
///   yes_count_fp / no_count_fp      ("10.00") → u32 via countStringToInt
///   yes_total_cost_dollars / no_..  ("0.400000") → i64 cents via dollarStringToCents
pub fn transformOne(
    arena: std.mem.Allocator,
    record: portfolio.SettlementRecord,
    out: *std.array_list.Managed(OutSettlement),
) !void {
    // Voided markets have no winner. Skip silently — they're neither wins
    // nor losses for the §8 asymmetry, just refunds.
    if (std.mem.eql(u8, record.market_result, "void")) return;

    const resolved_yes = std.mem.eql(u8, record.market_result, "yes");
    const ts_ms = parseIso8601Ms(record.settled_time) catch 0;

    // Parse string-formatted counts and costs. Bad input → zero (silent
    // skip is safer than crashing the orchestrator on a single malformed
    // record).
    const yes_count = countStringToInt(record.yes_count_fp) catch 0;
    const no_count = countStringToInt(record.no_count_fp) catch 0;
    const yes_total_cost_cents = dollarStringToCents(record.yes_total_cost_dollars) catch 0;
    const no_total_cost_cents = dollarStringToCents(record.no_total_cost_dollars) catch 0;

    // Per-side realized P&L. A contract pays 100c if its side won, 0
    // otherwise. Total cost is what we paid for that side's contracts.
    if (yes_count > 0) {
        const yes_revenue: i64 = if (resolved_yes) 100 * @as(i64, yes_count) else 0;
        try out.append(.{
            .ticker = try arena.dupe(u8, record.ticker),
            .resolved_yes = resolved_yes,
            .resolution_ts_ms = ts_ms,
            .our_held_side = "yes",
            .our_contracts = yes_count,
            .realized_pnl_cents = yes_revenue - yes_total_cost_cents,
        });
    }
    if (no_count > 0) {
        const no_revenue: i64 = if (!resolved_yes) 100 * @as(i64, no_count) else 0;
        try out.append(.{
            .ticker = try arena.dupe(u8, record.ticker),
            .resolved_yes = resolved_yes,
            .resolution_ts_ms = ts_ms,
            .our_held_side = "no",
            .our_contracts = no_count,
            .realized_pnl_cents = no_revenue - no_total_cost_cents,
        });
    }
}

// ---------------------------------------------------------------------------
// Kalshi-API string parsing helpers
// ---------------------------------------------------------------------------

/// Parse a Kalshi count string like "10.00" or "0.00" into u32.
/// Kalshi reports counts as floats with trailing ".00" because the
/// underlying field type is shared with non-integer-valued data (fees,
/// costs). For contract counts the value is always integer-valued.
pub fn countStringToInt(s: []const u8) !u32 {
    if (s.len == 0) return 0;
    const dot = std.mem.indexOfScalar(u8, s, '.');
    const int_part = if (dot) |d| s[0..d] else s;
    if (int_part.len == 0) return 0;
    return std.fmt.parseInt(u32, int_part, 10);
}

/// Parse a Kalshi dollar string like "0.400000", "1.500000", "-1.50"
/// into i64 cents. Two-decimal precision retained; deeper precision
/// truncated toward zero. Negatives supported.
pub fn dollarStringToCents(s: []const u8) !i64 {
    if (s.len == 0) return 0;
    var negative = false;
    var idx: usize = 0;
    if (s[0] == '-') {
        negative = true;
        idx = 1;
    }
    const remainder = s[idx..];

    const dot = std.mem.indexOfScalar(u8, remainder, '.');
    var int_part: i64 = 0;
    var frac_cents: i64 = 0;

    if (dot) |d| {
        if (d > 0) {
            int_part = try std.fmt.parseInt(i64, remainder[0..d], 10);
        }
        const frac_str = remainder[d + 1 ..];
        if (frac_str.len >= 2) {
            frac_cents = try std.fmt.parseInt(i64, frac_str[0..2], 10);
        } else if (frac_str.len == 1) {
            // ".5" → 50 cents (one fractional digit = tens)
            frac_cents = (try std.fmt.parseInt(i64, frac_str, 10)) * 10;
        }
    } else {
        int_part = try std.fmt.parseInt(i64, remainder, 10);
    }

    var result = int_part * 100 + frac_cents;
    if (negative) result = -result;
    return result;
}

/// Transform every record in a `SettlementsListTyped` and return the
/// orchestrator-facing page. Caller owns the slice via `arena`.
pub fn transformPage(
    arena: std.mem.Allocator,
    page: portfolio.SettlementsListTyped,
) !TransformedPage {
    var out: std.array_list.Managed(OutSettlement) = .init(arena);
    for (page.settlements) |r| try transformOne(arena, r, &out);
    return .{
        .next_cursor = try arena.dupe(u8, page.cursor),
        .settlements = try out.toOwnedSlice(),
    };
}

// ---------------------------------------------------------------------------
// ISO 8601 parser — strict format YYYY-MM-DDTHH:MM:SS[.fff]Z
// ---------------------------------------------------------------------------

const Iso8601Error = error{InvalidFormat};

/// Parse the strict subset Kalshi emits: `YYYY-MM-DDTHH:MM:SS[.fff]Z`.
/// Returns ms since Unix epoch. Tolerates 0-3 fractional digits.
/// Returns `Iso8601Error.InvalidFormat` on any deviation rather than
/// silently producing 0 — the caller decides whether to swallow the error.
pub fn parseIso8601Ms(s: []const u8) Iso8601Error!i64 {
    if (s.len < 20) return error.InvalidFormat;
    if (s[4] != '-' or s[7] != '-' or s[10] != 'T' or s[13] != ':' or s[16] != ':') {
        return error.InvalidFormat;
    }
    if (s[s.len - 1] != 'Z') return error.InvalidFormat;

    const year = parseIntPart(i32, s[0..4]) catch return error.InvalidFormat;
    const month = parseIntPart(u8, s[5..7]) catch return error.InvalidFormat;
    const day = parseIntPart(u8, s[8..10]) catch return error.InvalidFormat;
    const hour = parseIntPart(u8, s[11..13]) catch return error.InvalidFormat;
    const min = parseIntPart(u8, s[14..16]) catch return error.InvalidFormat;
    const sec = parseIntPart(u8, s[17..19]) catch return error.InvalidFormat;

    var ms_frac: i64 = 0;
    if (s.len > 20) {
        if (s[19] != '.') return error.InvalidFormat;
        const frac = s[20 .. s.len - 1];
        if (frac.len == 0 or frac.len > 3) return error.InvalidFormat;
        const n = parseIntPart(i64, frac) catch return error.InvalidFormat;
        // Pad to milliseconds: ".1" → 100, ".12" → 120, ".123" → 123.
        ms_frac = n * std.math.pow(i64, 10, 3 - @as(i64, @intCast(frac.len)));
    } else if (s.len != 20) {
        return error.InvalidFormat;
    }

    const days = daysFromCivil(year, month, day);
    const seconds: i64 = days * 86400 + @as(i64, hour) * 3600 + @as(i64, min) * 60 + @as(i64, sec);
    return seconds * 1000 + ms_frac;
}

fn parseIntPart(comptime T: type, s: []const u8) !T {
    return std.fmt.parseInt(T, s, 10);
}

/// Howard Hinnant's days-from-civil algorithm. Returns days since
/// 1970-01-01 for the given Gregorian (year, month, day). Year may be
/// negative; month is [1, 12]; day is [1, 31] for the month.
fn daysFromCivil(year: i32, month: u8, day: u8) i64 {
    var y = year;
    if (month <= 2) y -= 1;
    const era = @divFloor(if (y >= 0) y else y - 399, 400);
    const yoe: u32 = @intCast(y - era * 400);
    const m: u32 = @intCast(month);
    const d: u32 = @intCast(day);
    const m_shift: u32 = if (m > 2) m - 3 else m + 9;
    const doy: u32 = (153 * m_shift + 2) / 5 + d - 1;
    const doe: u32 = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    return @as(i64, era) * 146097 + @as(i64, doe) - 719468;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "transformOne: yes-resolved, only yes side held" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var out: std.array_list.Managed(OutSettlement) = .init(arena.allocator());

    try transformOne(arena.allocator(), .{
        .ticker = "KX-YES-WIN",
        .market_result = "yes",
        .yes_count_fp = "5.00",
        .no_count_fp = "0.00",
        .yes_total_cost_dollars = "1.500000", // 150c = $1.50 average 30c × 5 contracts
        .no_total_cost_dollars = "0.000000",
        .revenue = 500, // 100c per contract × 5
        .settled_time = "2026-05-19T12:00:00Z",
    }, &out);

    try std.testing.expectEqual(@as(usize, 1), out.items.len);
    const s = out.items[0];
    try std.testing.expectEqualStrings("KX-YES-WIN", s.ticker);
    try std.testing.expect(s.resolved_yes);
    try std.testing.expectEqualStrings("yes", s.our_held_side);
    try std.testing.expectEqual(@as(u32, 5), s.our_contracts);
    // 100*5 - 150 = 350c profit
    try std.testing.expectEqual(@as(i64, 350), s.realized_pnl_cents);
}

test "transformOne: no-resolved, only no side held" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var out: std.array_list.Managed(OutSettlement) = .init(arena.allocator());

    try transformOne(arena.allocator(), .{
        .ticker = "KX-NO-WIN",
        .market_result = "no",
        .yes_count_fp = "0.00",
        .no_count_fp = "3.00",
        .yes_total_cost_dollars = "0.000000",
        .no_total_cost_dollars = "0.900000", // 90c = $0.90 (3 × 30c avg)
        .revenue = 300,
        .settled_time = "2026-05-19T13:30:00Z",
    }, &out);

    try std.testing.expectEqual(@as(usize, 1), out.items.len);
    const s = out.items[0];
    try std.testing.expect(!s.resolved_yes);
    try std.testing.expectEqualStrings("no", s.our_held_side);
    try std.testing.expectEqual(@as(u32, 3), s.our_contracts);
    // 100*3 - 90 = 210c profit
    try std.testing.expectEqual(@as(i64, 210), s.realized_pnl_cents);
}

test "transformOne: yes-resolved, both sides held (split into two entries)" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var out: std.array_list.Managed(OutSettlement) = .init(arena.allocator());

    try transformOne(arena.allocator(), .{
        .ticker = "KX-BOTH-HELD",
        .market_result = "yes",
        .yes_count_fp = "2.00",
        .no_count_fp = "1.00",
        .yes_total_cost_dollars = "0.500000", // 50c: win side, 100*2 - 50 = +150
        .no_total_cost_dollars = "0.350000",  // 35c: loss side, 0 - 35 = -35
        .revenue = 200,
        .settled_time = "2026-05-19T14:15:00.123Z",
    }, &out);

    try std.testing.expectEqual(@as(usize, 2), out.items.len);
    try std.testing.expectEqualStrings("yes", out.items[0].our_held_side);
    try std.testing.expectEqual(@as(i64, 150), out.items[0].realized_pnl_cents);
    try std.testing.expectEqualStrings("no", out.items[1].our_held_side);
    try std.testing.expectEqual(@as(i64, -35), out.items[1].realized_pnl_cents);
    // Both entries share the same resolution_ts_ms (parsed from the ISO string).
    try std.testing.expectEqual(out.items[0].resolution_ts_ms, out.items[1].resolution_ts_ms);
}

test "transformOne: voided market emits nothing" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var out: std.array_list.Managed(OutSettlement) = .init(arena.allocator());

    try transformOne(arena.allocator(), .{
        .ticker = "KX-VOIDED",
        .market_result = "void",
        .yes_count_fp = "4.00",
        .no_count_fp = "0.00",
        .yes_total_cost_dollars = "1.000000",
        .no_total_cost_dollars = "0.000000",
        .revenue = 100, // full refund
        .settled_time = "2026-05-19T15:00:00Z",
    }, &out);

    try std.testing.expectEqual(@as(usize, 0), out.items.len);
}

test "transformPage drives transformOne over the whole fixture array" {
    const fixture = @embedFile("../kalshi/testdata/portfolio_settlements.json");
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const parsed = try std.json.parseFromSliceLeaky(
        portfolio.SettlementsListTyped,
        a,
        fixture,
        .{ .ignore_unknown_fields = true },
    );

    const page = try transformPage(a, parsed);
    try std.testing.expectEqualStrings("next-page-token", page.next_cursor);
    // Fixture has 4 raw records; voided emits 0, both-held emits 2 ⇒ 4 outputs.
    try std.testing.expectEqual(@as(usize, 4), page.settlements.len);

    // Spot-check that the voided ticker is absent.
    for (page.settlements) |s| {
        try std.testing.expect(!std.mem.eql(u8, s.ticker, "KX-VOIDED"));
    }
}

test "parseIso8601Ms handles whole-second timestamps" {
    // 2026-05-19T00:00:00Z is day 20592 since unix epoch (verified vs
    // `date -j -u -f '%Y-%m-%dT%H:%M:%S' '2026-05-19T12:00:00' +%s`).
    // 20592 * 86400 + 12*3600 = 1779192000 unix seconds → 1779192000000 ms.
    const ms = try parseIso8601Ms("2026-05-19T12:00:00Z");
    try std.testing.expectEqual(@as(i64, 1779192000000), ms);
}

test "parseIso8601Ms handles fractional-second timestamps" {
    // 2026-05-19T14:15:00 + .123s
    const ms = try parseIso8601Ms("2026-05-19T14:15:00.123Z");
    try std.testing.expectEqual(@as(i64, 1779200100123), ms);
}

test "parseIso8601Ms pads 1-digit fractional to 100 ms" {
    // .1 → 100, .01 → 010, .001 → 001 — we pad to ms scale.
    const ms = try parseIso8601Ms("2026-05-19T14:15:00.1Z");
    try std.testing.expectEqual(@as(i64, 1779200100100), ms);
}

test "parseIso8601Ms rejects missing Z suffix" {
    try std.testing.expectError(
        Iso8601Error.InvalidFormat,
        parseIso8601Ms("2026-05-19T12:00:00"),
    );
}

test "parseIso8601Ms rejects garbage" {
    try std.testing.expectError(
        Iso8601Error.InvalidFormat,
        parseIso8601Ms("not-a-timestamp"),
    );
}

// --- countStringToInt tests ---

test "countStringToInt: typical Kalshi count" {
    try std.testing.expectEqual(@as(u32, 10), try countStringToInt("10.00"));
    try std.testing.expectEqual(@as(u32, 0), try countStringToInt("0.00"));
    try std.testing.expectEqual(@as(u32, 5), try countStringToInt("5"));
}

test "countStringToInt: empty string returns 0" {
    try std.testing.expectEqual(@as(u32, 0), try countStringToInt(""));
}

// --- dollarStringToCents tests ---

test "dollarStringToCents: typical Kalshi values" {
    // "0.400000" → 40c
    try std.testing.expectEqual(@as(i64, 40), try dollarStringToCents("0.400000"));
    // "1.500000" → 150c
    try std.testing.expectEqual(@as(i64, 150), try dollarStringToCents("1.500000"));
    // "10.00" → 1000c
    try std.testing.expectEqual(@as(i64, 1000), try dollarStringToCents("10.00"));
    // "0.030000" → 3c (fee)
    try std.testing.expectEqual(@as(i64, 3), try dollarStringToCents("0.030000"));
}

test "dollarStringToCents: integer-only" {
    try std.testing.expectEqual(@as(i64, 500), try dollarStringToCents("5"));
}

test "dollarStringToCents: single fractional digit pads to tens" {
    // ".5" → 50c (5 in tens place)
    try std.testing.expectEqual(@as(i64, 50), try dollarStringToCents("0.5"));
}

test "dollarStringToCents: negative values" {
    try std.testing.expectEqual(@as(i64, -150), try dollarStringToCents("-1.50"));
    try std.testing.expectEqual(@as(i64, -5), try dollarStringToCents("-0.05"));
}

test "dollarStringToCents: empty string returns 0" {
    try std.testing.expectEqual(@as(i64, 0), try dollarStringToCents(""));
}

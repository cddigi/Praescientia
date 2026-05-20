//! game_state — classify a Kalshi market into a GamePhase + recommended
//! polling interval.
//!
//! Pure module: no I/O, no network. Parses ticker prefixes to identify
//! the sport and game date, then compares against `now_ms` to compute
//! the phase. The orchestrator daemon uses this to decide per-thesis
//! polling cadence: 30s during in_game windows, 5min when nothing is
//! about to happen.
//!
//! Path 1 (heuristic) implementation. Path 2 (live-data milestone
//! overlay) is documented in IMPLEMENTATION_PLAN.md and lives in a
//! follow-up PR.
//!
//! Time-zone note: Kalshi tickers encode game dates in **Eastern Time**
//! (ET). This module hardcodes EDT (UTC-4) for now — works May through
//! early November. EST handling and DST-aware conversion is a
//! follow-up. The error this introduces is at most 1h of phase-window
//! misalignment, which is acceptable for a polling-cadence heuristic.

const std = @import("std");
const markets_mod = @import("../kalshi/markets.zig");

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

pub const Sport = enum {
    unknown,
    nba,
    wnba,
    mlb,
    nfl,
    nhl,
    mls,
    atp,
    wta,
    soccer_intl, // catch-all for KXBELGIANPLGAME and similar international football

    pub fn label(self: Sport) []const u8 {
        return @tagName(self);
    }
};

pub const GamePhase = enum {
    /// Sport unrecognized OR ticker parse failed. Treat as standard cadence.
    unknown,
    /// Game date >24h in the future.
    scheduled,
    /// 1h..24h before game.
    pre_game,
    /// 0..1h before game.
    near_game,
    /// Active game window per sport duration.
    in_game,
    /// 0..2h after game end (settlement pending).
    post_game,
    /// market.status ∈ {determined, finalized}.
    finalized,

    pub fn label(self: GamePhase) []const u8 {
        return @tagName(self);
    }
};

/// Recommended polling interval per phase, in seconds.
pub const PollInterval = enum(u32) {
    sleep = 1800, // 30 min — game is days away
    standard = 300, // 5 min — normal cadence / unknown phase
    elevated = 120, // 2 min — within hours of game OR post-game settling
    aggressive = 30, // 30 sec — game in progress
};

pub const TickerInfo = struct {
    sport: Sport,
    /// "2026-05-21" or null on parse failure.
    game_date_iso: ?[]const u8,
    /// "13:05" Eastern Time. MLB tickers embed this; NBA/ATP/WTA do not.
    game_time_iso: ?[]const u8,
    /// Best-effort 3-letter team / player codes (uppercase). Either may be null.
    team_codes: [2]?[]const u8,
};

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

pub fn parseTicker(ticker: []const u8) TickerInfo {
    inline for (parser_table) |entry| {
        if (std.mem.startsWith(u8, ticker, entry.prefix)) {
            return entry.parse(ticker);
        }
    }
    return .{
        .sport = .unknown,
        .game_date_iso = null,
        .game_time_iso = null,
        .team_codes = .{ null, null },
    };
}

pub fn sportFromPrefix(ticker: []const u8) Sport {
    inline for (parser_table) |entry| {
        if (std.mem.startsWith(u8, ticker, entry.prefix)) return entry.sport;
    }
    return .unknown;
}

/// Typical game duration in minutes. Used to compute the in_game window
/// end-time given the start time. These are *median* durations including
/// commercial breaks / inning changes / etc.
pub fn typicalGameDurationMin(sport: Sport) u32 {
    return switch (sport) {
        .nba => 150, // 4 × 12min quarters + halftime + commercials ≈ 2.5h
        .wnba => 130,
        .mlb => 180, // 9 innings, regular pace
        .nfl => 200, // 4 × 15min quarters but lots of stoppages
        .nhl => 150, // 3 × 20min periods + intermissions
        .mls, .soccer_intl => 120, // 90min regulation + injury time + halftime
        .atp, .wta => 180, // highly variable; median for R16 best-of-3
        .unknown => 0,
    };
}

/// Default tip-off time in ET (24h HHMM) when not encoded in the ticker.
/// Operator-tunable via daemon flags in a follow-up; defaults here cover
/// the median case.
pub fn defaultTipTimeEt(sport: Sport) struct { hour: u8, minute: u8 } {
    return switch (sport) {
        .nba, .wnba => .{ .hour = 19, .minute = 30 }, // evening tip
        .nhl => .{ .hour = 19, .minute = 0 },
        .nfl => .{ .hour = 13, .minute = 0 }, // afternoon games dominate
        .mlb => .{ .hour = 19, .minute = 5 }, // evening fallback when not in ticker
        .mls, .soccer_intl => .{ .hour = 19, .minute = 30 },
        .atp, .wta => .{ .hour = 11, .minute = 0 }, // ATP tour first matches typically 11am local
        .unknown => .{ .hour = 12, .minute = 0 },
    };
}

pub fn pollInterval(phase: GamePhase) PollInterval {
    return switch (phase) {
        .scheduled => .sleep,
        .pre_game => .standard,
        .near_game => .elevated,
        .in_game => .aggressive,
        .post_game => .elevated,
        .finalized => .standard, // resolution pending; stay reachable
        .unknown => .standard,
    };
}

/// Compute the game phase given the market state and the current time.
pub fn classify(market: markets_mod.Market, now_ms: i64) GamePhase {
    // Hard override: Kalshi has already determined / finalized the market.
    if (std.mem.eql(u8, market.status, "determined") or
        std.mem.eql(u8, market.status, "finalized"))
    {
        return .finalized;
    }

    const info = parseTicker(market.ticker);
    if (info.sport == .unknown or info.game_date_iso == null) return .unknown;

    const start_ms = computeGameStartMs(info) orelse return .unknown;
    const duration_min = typicalGameDurationMin(info.sport);
    const end_ms = start_ms + @as(i64, duration_min) * 60_000;
    const post_game_end_ms = end_ms + 2 * 60 * 60_000; // 2h post-game

    const minutes_to_start = @divFloor(start_ms - now_ms, 60_000);

    if (now_ms >= start_ms and now_ms < end_ms) return .in_game;
    if (now_ms >= end_ms and now_ms < post_game_end_ms) return .post_game;
    if (now_ms >= post_game_end_ms) return .finalized;
    if (minutes_to_start <= 60) return .near_game;
    if (minutes_to_start <= 24 * 60) return .pre_game;
    return .scheduled;
}

// ---------------------------------------------------------------------------
// Parser dispatch table
// ---------------------------------------------------------------------------

const ParserEntry = struct {
    prefix: []const u8,
    sport: Sport,
    parse: *const fn (ticker: []const u8) TickerInfo,
};

const parser_table = [_]ParserEntry{
    // ORDER MATTERS — longer prefixes first so KXNBATEAMTOTAL doesn't
    // false-match the KXNBA short prefix (the longer parser is more
    // specific).
    .{ .prefix = "KXNBATEAMTOTAL-", .sport = .nba, .parse = parseNbaDateOnly },
    .{ .prefix = "KXNBASPREAD-", .sport = .nba, .parse = parseNbaDateOnly },
    .{ .prefix = "KXNBATOTAL-", .sport = .nba, .parse = parseNbaDateOnly },
    .{ .prefix = "KXWNBAGAME-", .sport = .wnba, .parse = parseNbaDateOnly },
    .{ .prefix = "KXMLBTEAMTOTAL-", .sport = .mlb, .parse = parseMlbDateTime },
    .{ .prefix = "KXMLBSPREAD-", .sport = .mlb, .parse = parseMlbDateTime },
    .{ .prefix = "KXMLBTOTAL-", .sport = .mlb, .parse = parseMlbDateTime },
    .{ .prefix = "KXATPMATCH-", .sport = .atp, .parse = parseTennisDateOnly },
    .{ .prefix = "KXWTAMATCH-", .sport = .wta, .parse = parseTennisDateOnly },
    .{ .prefix = "KXBELGIANPLGAME-", .sport = .soccer_intl, .parse = parseNbaDateOnly },
    .{ .prefix = "KXVTBGAME-", .sport = .soccer_intl, .parse = parseNbaDateOnly },
};

// ---------------------------------------------------------------------------
// Sport-specific parsers
//
// Each parser is permissive: returns the best-effort TickerInfo. If date
// extraction fails, returns null fields rather than erroring.
// ---------------------------------------------------------------------------

/// NBA / WNBA / soccer pattern: `<PREFIX>-{YYMMMDD}{T1}{T2}-{rest}`.
/// Date is exactly 7 characters: 2 digits year, 3 letters month, 2 digits day.
fn parseNbaDateOnly(ticker: []const u8) TickerInfo {
    const prefix_end = std.mem.indexOfScalar(u8, ticker, '-') orelse {
        return emptyInfo(.nba);
    };
    const after_prefix_start = prefix_end + 1;
    // Find the next dash — that's the boundary between the {YYMMMDD}{T1}{T2}
    // block and the rest.
    const next_dash = std.mem.indexOfScalarPos(u8, ticker, after_prefix_start, '-') orelse {
        return emptyInfo(sportFromPrefix(ticker));
    };
    const block = ticker[after_prefix_start..next_dash];
    if (block.len < 7) return emptyInfo(sportFromPrefix(ticker));

    const date_iso = parseKalshiDate(block[0..7]) catch return emptyInfo(sportFromPrefix(ticker));
    const teams = parseTeamCodes(block[7..]);
    return .{
        .sport = sportFromPrefix(ticker),
        .game_date_iso = date_iso,
        .game_time_iso = null,
        .team_codes = teams,
    };
}

/// MLB pattern: `<PREFIX>-{YYMMMDD}{HHMM}{T1}{T2}-{rest}`.
/// Date 7 chars + time 4 chars (HHMM) precedes team codes.
fn parseMlbDateTime(ticker: []const u8) TickerInfo {
    const prefix_end = std.mem.indexOfScalar(u8, ticker, '-') orelse return emptyInfo(.mlb);
    const after_prefix_start = prefix_end + 1;
    const next_dash = std.mem.indexOfScalarPos(u8, ticker, after_prefix_start, '-') orelse {
        return emptyInfo(.mlb);
    };
    const block = ticker[after_prefix_start..next_dash];
    if (block.len < 11) return emptyInfo(.mlb);

    const date_iso = parseKalshiDate(block[0..7]) catch return emptyInfo(.mlb);
    const time_iso = parseKalshiTime(block[7..11]) catch null;
    const teams = parseTeamCodes(block[11..]);
    return .{
        .sport = .mlb,
        .game_date_iso = date_iso,
        .game_time_iso = time_iso,
        .team_codes = teams,
    };
}

/// ATP / WTA pattern: `<PREFIX>-{YYMMMDD}{P1}{P2}-{rest}`.
/// Player codes are typically 3 letters (uppercase) but length varies.
fn parseTennisDateOnly(ticker: []const u8) TickerInfo {
    return parseNbaDateOnly(ticker); // same structural pattern
}

// ---------------------------------------------------------------------------
// Date / time parsing helpers
// ---------------------------------------------------------------------------

const month_table = [_]struct { name: []const u8, num: u8 }{
    .{ .name = "JAN", .num = 1 },
    .{ .name = "FEB", .num = 2 },
    .{ .name = "MAR", .num = 3 },
    .{ .name = "APR", .num = 4 },
    .{ .name = "MAY", .num = 5 },
    .{ .name = "JUN", .num = 6 },
    .{ .name = "JUL", .num = 7 },
    .{ .name = "AUG", .num = 8 },
    .{ .name = "SEP", .num = 9 },
    .{ .name = "OCT", .num = 10 },
    .{ .name = "NOV", .num = 11 },
    .{ .name = "DEC", .num = 12 },
};

/// Parse "26MAY21" → "2026-05-21". Returns the literal arena-free
/// string slice using a hidden module-level scratch buffer.
fn parseKalshiDate(s: []const u8) ![]const u8 {
    if (s.len != 7) return error.InvalidDate;
    const year_2digit = std.fmt.parseInt(u32, s[0..2], 10) catch return error.InvalidDate;
    const month_str = s[2..5];
    const day = std.fmt.parseInt(u32, s[5..7], 10) catch return error.InvalidDate;

    var month_num: u8 = 0;
    for (month_table) |m| {
        if (std.mem.eql(u8, m.name, month_str)) {
            month_num = m.num;
            break;
        }
    }
    if (month_num == 0) return error.InvalidDate;

    // Format into the thread-local buffer.
    const Holder = struct {
        threadlocal var buf: [10]u8 = undefined; // "YYYY-MM-DD"
    };
    const year_full = 2000 + year_2digit;
    return std.fmt.bufPrint(&Holder.buf, "{d:0>4}-{d:0>2}-{d:0>2}", .{ year_full, month_num, day }) catch return error.InvalidDate;
}

/// Parse "1305" → "13:05" (Eastern Time, 24h format).
fn parseKalshiTime(s: []const u8) ![]const u8 {
    if (s.len != 4) return error.InvalidTime;
    const hour = std.fmt.parseInt(u8, s[0..2], 10) catch return error.InvalidTime;
    const min = std.fmt.parseInt(u8, s[2..4], 10) catch return error.InvalidTime;
    if (hour > 23 or min > 59) return error.InvalidTime;
    const Holder = struct {
        threadlocal var buf: [5]u8 = undefined;
    };
    return std.fmt.bufPrint(&Holder.buf, "{d:0>2}:{d:0>2}", .{ hour, min }) catch return error.InvalidTime;
}

/// Best-effort team-code extraction. Splits a block like "CLENYK" or
/// "RAFCWES" by trying common code lengths (3 chars then 4 chars).
fn parseTeamCodes(block: []const u8) [2]?[]const u8 {
    if (block.len < 6) return .{ null, null };
    // Common case: 3 + 3
    if (block.len == 6) return .{ block[0..3], block[3..6] };
    // 4 + 4 (RAFCWES = 4 chars + 4 chars? actually that's 7, hmm)
    if (block.len == 8) return .{ block[0..4], block[4..8] };
    // Fall through: take first 3 + remaining
    return .{ block[0..3], block[3..] };
}

fn emptyInfo(sport: Sport) TickerInfo {
    return .{
        .sport = sport,
        .game_date_iso = null,
        .game_time_iso = null,
        .team_codes = .{ null, null },
    };
}

// ---------------------------------------------------------------------------
// Time math
// ---------------------------------------------------------------------------

/// Compute the game's start time as Unix ms. Uses the parsed date
/// (Eastern Time) + parsed time (if any) or sport default, converts ET
/// → UTC by subtracting 4h (EDT). DST-aware conversion is a follow-up.
fn computeGameStartMs(info: TickerInfo) ?i64 {
    const date_iso = info.game_date_iso orelse return null;
    if (date_iso.len != 10) return null;

    const year = std.fmt.parseInt(i64, date_iso[0..4], 10) catch return null;
    const month = std.fmt.parseInt(u8, date_iso[5..7], 10) catch return null;
    const day = std.fmt.parseInt(u8, date_iso[8..10], 10) catch return null;

    var hour: u8 = 0;
    var minute: u8 = 0;
    if (info.game_time_iso) |t| {
        if (t.len == 5) {
            hour = std.fmt.parseInt(u8, t[0..2], 10) catch hour;
            minute = std.fmt.parseInt(u8, t[3..5], 10) catch minute;
        }
    } else {
        const def = defaultTipTimeEt(info.sport);
        hour = def.hour;
        minute = def.minute;
    }

    // Compute Unix ms from y/m/d/h/m. Use days-since-epoch math; assumes
    // proleptic Gregorian, ET → UTC offset = +4h (EDT).
    const days = daysFromCivil(year, month, day);
    const utc_hour = @as(i64, hour) + 4; // EDT → UTC
    const ms_in_day: i64 = utc_hour * 3600 * 1000 + @as(i64, minute) * 60 * 1000;
    return days * 86_400_000 + ms_in_day;
}

/// Howard Hinnant's `days_from_civil` algorithm — converts (y, m, d)
/// proleptic Gregorian to days-since-1970-01-01.
fn daysFromCivil(y_in: i64, m_in: u8, d_in: u8) i64 {
    var y: i64 = y_in;
    if (m_in <= 2) y -= 1;
    const m: i64 = m_in;
    const d: i64 = d_in;
    const era: i64 = @divFloor(if (y >= 0) y else y - 399, 400);
    const yoe: i64 = y - era * 400;
    const m_adj: i64 = if (m > 2) m - 3 else m + 9;
    const doy: i64 = @divTrunc(153 * m_adj + 2, 5) + d - 1;
    const doe: i64 = yoe * 365 + @divTrunc(yoe, 4) - @divTrunc(yoe, 100) + doy;
    return era * 146_097 + doe - 719_468;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "parseTicker — NBA spread (date only, 3+3 team codes)" {
    const info = parseTicker("KXNBASPREAD-26MAY21CLENYK-NYK2");
    try std.testing.expectEqual(Sport.nba, info.sport);
    try std.testing.expectEqualStrings("2026-05-21", info.game_date_iso.?);
    try std.testing.expectEqual(@as(?[]const u8, null), info.game_time_iso);
    try std.testing.expectEqualStrings("CLE", info.team_codes[0].?);
    try std.testing.expectEqualStrings("NYK", info.team_codes[1].?);
}

test "parseTicker — NBA team total (longer prefix)" {
    const info = parseTicker("KXNBATEAMTOTAL-26MAY21CLENYK-NYK97");
    try std.testing.expectEqual(Sport.nba, info.sport);
    try std.testing.expectEqualStrings("2026-05-21", info.game_date_iso.?);
}

test "parseTicker — NBA total" {
    const info = parseTicker("KXNBATOTAL-26MAY21CLENYK-205");
    try std.testing.expectEqual(Sport.nba, info.sport);
    try std.testing.expectEqualStrings("2026-05-21", info.game_date_iso.?);
}

test "parseTicker — MLB spread (date + time)" {
    const info = parseTicker("KXMLBSPREAD-26MAY201305CINPHI-CIN2");
    try std.testing.expectEqual(Sport.mlb, info.sport);
    try std.testing.expectEqualStrings("2026-05-20", info.game_date_iso.?);
    try std.testing.expectEqualStrings("13:05", info.game_time_iso.?);
    try std.testing.expectEqualStrings("CIN", info.team_codes[0].?);
    try std.testing.expectEqualStrings("PHI", info.team_codes[1].?);
}

test "parseTicker — ATP match" {
    const info = parseTicker("KXATPMATCH-26MAY20FRIPOP-POP");
    try std.testing.expectEqual(Sport.atp, info.sport);
    try std.testing.expectEqualStrings("2026-05-20", info.game_date_iso.?);
    try std.testing.expectEqualStrings("FRI", info.team_codes[0].?);
    try std.testing.expectEqualStrings("POP", info.team_codes[1].?);
}

test "parseTicker — WTA match" {
    const info = parseTicker("KXWTAMATCH-26MAY20PARTEI-TEI");
    try std.testing.expectEqual(Sport.wta, info.sport);
    try std.testing.expectEqualStrings("2026-05-20", info.game_date_iso.?);
}

test "parseTicker — soccer (Belgian league)" {
    const info = parseTicker("KXBELGIANPLGAME-26MAY23RAFCWES-RAFC");
    try std.testing.expectEqual(Sport.soccer_intl, info.sport);
    try std.testing.expectEqualStrings("2026-05-23", info.game_date_iso.?);
}

test "parseTicker — non-sport returns unknown" {
    const info = parseTicker("KXBTCD-26MAY2017-T79499.99");
    try std.testing.expectEqual(Sport.unknown, info.sport);
    try std.testing.expectEqual(@as(?[]const u8, null), info.game_date_iso);
}

test "parseTicker — malformed sport prefix returns unknown info" {
    const info = parseTicker("KXNBASPREAD-malformed");
    try std.testing.expectEqual(Sport.nba, info.sport);
    try std.testing.expectEqual(@as(?[]const u8, null), info.game_date_iso);
}

test "parseTicker — empty string" {
    const info = parseTicker("");
    try std.testing.expectEqual(Sport.unknown, info.sport);
}

test "parseKalshiDate — known months" {
    try std.testing.expectEqualStrings("2026-05-21", try parseKalshiDate("26MAY21"));
    try std.testing.expectEqualStrings("2026-01-15", try parseKalshiDate("26JAN15"));
    try std.testing.expectEqualStrings("2026-12-31", try parseKalshiDate("26DEC31"));
}

test "parseKalshiDate — invalid month rejected" {
    try std.testing.expectError(error.InvalidDate, parseKalshiDate("26XYZ21"));
}

test "parseKalshiDate — wrong length rejected" {
    try std.testing.expectError(error.InvalidDate, parseKalshiDate("26MAY"));
}

test "parseKalshiTime — basic" {
    try std.testing.expectEqualStrings("13:05", try parseKalshiTime("1305"));
    try std.testing.expectEqualStrings("00:00", try parseKalshiTime("0000"));
    try std.testing.expectEqualStrings("23:59", try parseKalshiTime("2359"));
}

test "parseKalshiTime — out of range rejected" {
    try std.testing.expectError(error.InvalidTime, parseKalshiTime("2500"));
    try std.testing.expectError(error.InvalidTime, parseKalshiTime("1199"));
}

test "pollInterval mapping" {
    try std.testing.expectEqual(PollInterval.sleep, pollInterval(.scheduled));
    try std.testing.expectEqual(PollInterval.standard, pollInterval(.pre_game));
    try std.testing.expectEqual(PollInterval.elevated, pollInterval(.near_game));
    try std.testing.expectEqual(PollInterval.aggressive, pollInterval(.in_game));
    try std.testing.expectEqual(PollInterval.elevated, pollInterval(.post_game));
    try std.testing.expectEqual(PollInterval.standard, pollInterval(.finalized));
    try std.testing.expectEqual(PollInterval.standard, pollInterval(.unknown));
}

test "typicalGameDurationMin sanity" {
    try std.testing.expect(typicalGameDurationMin(.nba) > 90);
    try std.testing.expect(typicalGameDurationMin(.mlb) > 120);
    try std.testing.expectEqual(@as(u32, 0), typicalGameDurationMin(.unknown));
}

test "classify — finalized status overrides date math" {
    const market: markets_mod.Market = .{
        .ticker = "KXNBASPREAD-26MAY21CLENYK-NYK2",
        .status = "finalized",
        .close_time = "2026-06-05T00:00:00Z",
    };
    // Even at a "scheduled" time, finalized status wins.
    const phase = classify(market, 1_000_000_000_000);
    try std.testing.expectEqual(GamePhase.finalized, phase);
}

test "classify — non-sport ticker returns unknown" {
    const market: markets_mod.Market = .{
        .ticker = "KXBTCD-26MAY2017-T79499.99",
        .status = "active",
        .close_time = "2026-05-20T21:00:00Z",
    };
    try std.testing.expectEqual(GamePhase.unknown, classify(market, 1_000_000_000_000));
}

test "classify — NBA game scheduled (>24h out)" {
    // Game on 2026-05-21 at 19:30 ET (= 23:30 UTC).
    const game_start_utc_ms: i64 = computeGameStartMs(.{
        .sport = .nba,
        .game_date_iso = "2026-05-21",
        .game_time_iso = null,
        .team_codes = .{ null, null },
    }).?;
    const now_ms = game_start_utc_ms - 48 * 3600 * 1000; // 48h before tip

    const market: markets_mod.Market = .{
        .ticker = "KXNBASPREAD-26MAY21CLENYK-NYK2",
        .status = "active",
        .close_time = "2026-06-05T00:00:00Z",
    };
    try std.testing.expectEqual(GamePhase.scheduled, classify(market, now_ms));
}

test "classify — NBA game near (within 1h)" {
    const game_start_utc_ms: i64 = computeGameStartMs(.{
        .sport = .nba,
        .game_date_iso = "2026-05-21",
        .game_time_iso = null,
        .team_codes = .{ null, null },
    }).?;
    const now_ms = game_start_utc_ms - 30 * 60 * 1000; // 30min before tip

    const market: markets_mod.Market = .{
        .ticker = "KXNBASPREAD-26MAY21CLENYK-NYK2",
        .status = "active",
        .close_time = "",
    };
    try std.testing.expectEqual(GamePhase.near_game, classify(market, now_ms));
}

test "classify — NBA game in progress" {
    const game_start_utc_ms: i64 = computeGameStartMs(.{
        .sport = .nba,
        .game_date_iso = "2026-05-21",
        .game_time_iso = null,
        .team_codes = .{ null, null },
    }).?;
    const now_ms = game_start_utc_ms + 60 * 60 * 1000; // 1h into the game (within 2.5h window)

    const market: markets_mod.Market = .{
        .ticker = "KXNBASPREAD-26MAY21CLENYK-NYK2",
        .status = "active",
        .close_time = "",
    };
    try std.testing.expectEqual(GamePhase.in_game, classify(market, now_ms));
}

test "classify — NBA game post-game window" {
    const game_start_utc_ms: i64 = computeGameStartMs(.{
        .sport = .nba,
        .game_date_iso = "2026-05-21",
        .game_time_iso = null,
        .team_codes = .{ null, null },
    }).?;
    // 3h after tip — past 2.5h NBA window, within 2h post-game.
    const now_ms = game_start_utc_ms + 3 * 60 * 60 * 1000;

    const market: markets_mod.Market = .{
        .ticker = "KXNBASPREAD-26MAY21CLENYK-NYK2",
        .status = "active",
        .close_time = "",
    };
    try std.testing.expectEqual(GamePhase.post_game, classify(market, now_ms));
}

test "classify — MLB game uses ticker time" {
    // MLB game at 13:05 ET on 2026-05-20.
    const game_start_utc_ms: i64 = computeGameStartMs(.{
        .sport = .mlb,
        .game_date_iso = "2026-05-20",
        .game_time_iso = "13:05",
        .team_codes = .{ null, null },
    }).?;
    const now_ms = game_start_utc_ms + 90 * 60 * 1000; // 90min in — inside MLB 3h window

    const market: markets_mod.Market = .{
        .ticker = "KXMLBSPREAD-26MAY201305CINPHI-CIN2",
        .status = "active",
        .close_time = "",
    };
    try std.testing.expectEqual(GamePhase.in_game, classify(market, now_ms));
}

test "daysFromCivil — epoch and known dates" {
    try std.testing.expectEqual(@as(i64, 0), daysFromCivil(1970, 1, 1));
    try std.testing.expectEqual(@as(i64, 365), daysFromCivil(1971, 1, 1));
    // 2026-05-21 should be 20594 days after epoch
    const days_2026 = daysFromCivil(2026, 5, 21);
    try std.testing.expect(days_2026 > 20_000 and days_2026 < 21_000);
}

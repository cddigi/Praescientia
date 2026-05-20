//! Kalshi `/portfolio/*` endpoints — all require authentication.
//!
//! Position/settlement/fill entries are kept as `std.json.Value` rather than
//! frozen structs: the demo account at fixture-capture time was empty, so the
//! real per-entry shape can't be locked down without speculative typing.

const std = @import("std");
const client_mod = @import("client.zig");

const Allocator = std.mem.Allocator;
const Client = client_mod.Client;
const QueryParam = client_mod.QueryParam;

pub const BalanceBreakdown = struct {
    balance: []const u8 = "",
    exchange_index: i64 = 0,
};

pub const Balance = struct {
    balance: i64,
    balance_breakdown: []BalanceBreakdown = &.{},
    portfolio_value: i64 = 0,
    updated_ts: i64 = 0,
};

pub const PositionsList = struct {
    cursor: []const u8 = "",
    event_positions: []std.json.Value = &.{},
    market_positions: []std.json.Value = &.{},
};

pub const SettlementsList = struct {
    cursor: []const u8 = "",
    settlements: []std.json.Value = &.{},
};

/// Typed shape for one record returned by `/portfolio/settlements`.
///
/// Kalshi documents the response as a per-market record with both sides'
/// counts and costs and a `market_result` describing how the market settled.
/// `revenue` is the cash credited to the account from this settlement; the
/// per-side P&L split is derived in `src/kb/settlements.zig::transform`.
///
/// `market_result` is `"yes"`, `"no"`, or `"void"`. Voided markets do not
/// have a winning side — the transformer skips them rather than synthesizing
/// a phantom outcome.
pub const SettlementRecord = struct {
    ticker: []const u8,
    market_result: []const u8,
    yes_count: u32 = 0,
    no_count: u32 = 0,
    yes_total_cost: i64 = 0,
    no_total_cost: i64 = 0,
    revenue: i64 = 0,
    /// ISO 8601, e.g. `2026-05-19T12:00:00Z` or `2026-05-19T14:15:00.123Z`.
    settled_time: []const u8 = "",
};

pub const SettlementsListTyped = struct {
    cursor: []const u8 = "",
    settlements: []SettlementRecord = &.{},
};

pub const FillsList = struct {
    cursor: []const u8 = "",
    fills: []std.json.Value = &.{},
};

pub const ListOptions = struct {
    limit: ?u32 = null,
    cursor: ?[]const u8 = null,
    ticker: ?[]const u8 = null,
    event_ticker: ?[]const u8 = null,
    min_ts: ?i64 = null,
    max_ts: ?i64 = null,
};

/// GET /portfolio/balance
pub fn balance(client: *Client, arena: Allocator) !Balance {
    return getJson(Balance, client, arena, "/portfolio/balance", &.{});
}

/// GET /portfolio/positions
pub fn positions(client: *Client, arena: Allocator, opts: ListOptions) !PositionsList {
    return getJson(PositionsList, client, arena, "/portfolio/positions", try queryFromList(arena, opts));
}

/// GET /portfolio/settlements — opaque-value variant; preserves any
/// undocumented fields that show up at runtime.
pub fn settlements(client: *Client, arena: Allocator, opts: ListOptions) !SettlementsList {
    return getJson(SettlementsList, client, arena, "/portfolio/settlements", try queryFromList(arena, opts));
}

/// GET /portfolio/settlements — typed variant. The orchestrator uses this
/// path because it needs deterministic per-field access (held side, counts,
/// costs) to feed `src/kb/settlements.zig::transform`. Unknown fields are
/// ignored so a server-side schema addition won't break the orchestrator.
pub fn settlementsTyped(client: *Client, arena: Allocator, opts: ListOptions) !SettlementsListTyped {
    return getJson(SettlementsListTyped, client, arena, "/portfolio/settlements", try queryFromList(arena, opts));
}

/// GET /portfolio/fills
pub fn fills(client: *Client, arena: Allocator, opts: ListOptions) !FillsList {
    return getJson(FillsList, client, arena, "/portfolio/fills", try queryFromList(arena, opts));
}

/// GET /portfolio/orders/resting_value — total value of all resting orders.
pub fn restingValue(client: *Client, arena: Allocator) !std.json.Value {
    return getJsonValue(client, arena, "/portfolio/orders/resting_value", &.{});
}

/// GET /portfolio/subaccounts/balances — balances for all subaccounts.
pub fn subaccountsBalances(client: *Client, arena: Allocator) !std.json.Value {
    return getJsonValue(client, arena, "/portfolio/subaccounts/balances", &.{});
}

pub const SubaccountTransfersOptions = struct {
    limit: ?u32 = null,
    cursor: ?[]const u8 = null,
};

/// GET /portfolio/subaccounts/transfers
pub fn listSubaccountTransfers(client: *Client, arena: Allocator, opts: SubaccountTransfersOptions) !std.json.Value {
    var q: std.array_list.Managed(QueryParam) = .init(arena);
    if (opts.limit) |v| try q.append(.{ .key = "limit", .value = try std.fmt.allocPrint(arena, "{d}", .{v}) });
    if (opts.cursor) |v| try q.append(.{ .key = "cursor", .value = v });
    return getJsonValue(client, arena, "/portfolio/subaccounts/transfers", q.items);
}

/// GET /portfolio/subaccounts/{subaccount_id}/netting
pub fn getNetting(client: *Client, arena: Allocator, subaccount_id: []const u8) !std.json.Value {
    const path = try std.fmt.allocPrint(arena, "/portfolio/subaccounts/{s}/netting", .{subaccount_id});
    return getJsonValue(client, arena, path, &.{});
}

/// POST /portfolio/subaccounts — body: {"name":"..."}
pub fn createSubaccount(client: *Client, arena: Allocator, name: []const u8) !std.json.Value {
    if (!client.hasCredentials()) return error.MissingCredentials;
    const Body = struct { name: []const u8 };
    var aw: std.Io.Writer.Allocating = .init(arena);
    try std.json.Stringify.value(Body{ .name = name }, .{ .whitespace = .minified, .emit_null_optional_fields = false }, &aw.writer);
    const resp = try client.request(arena, .{
        .path = "/portfolio/subaccounts",
        .method = .POST,
        .body = aw.written(),
    });
    if (!resp.isSuccess()) return error.HttpStatus;
    return std.json.parseFromSliceLeaky(std.json.Value, arena, resp.body, .{});
}

/// POST /portfolio/subaccounts/transfers — body:
/// {"from_subaccount_id":"...","to_subaccount_id":"...","amount":N}
pub fn transferBetweenSubaccounts(
    client: *Client,
    arena: Allocator,
    from_id: []const u8,
    to_id: []const u8,
    amount_cents: i64,
) !std.json.Value {
    if (!client.hasCredentials()) return error.MissingCredentials;
    const Body = struct {
        from_subaccount_id: []const u8,
        to_subaccount_id: []const u8,
        amount: i64,
    };
    var aw: std.Io.Writer.Allocating = .init(arena);
    try std.json.Stringify.value(
        Body{ .from_subaccount_id = from_id, .to_subaccount_id = to_id, .amount = amount_cents },
        .{ .whitespace = .minified, .emit_null_optional_fields = false },
        &aw.writer,
    );
    const resp = try client.request(arena, .{
        .path = "/portfolio/subaccounts/transfers",
        .method = .POST,
        .body = aw.written(),
    });
    if (!resp.isSuccess()) return error.HttpStatus;
    return std.json.parseFromSliceLeaky(std.json.Value, arena, resp.body, .{});
}

/// PUT /portfolio/subaccounts/{subaccount_id}/netting — body: {"netting_enabled":bool}
pub fn setNetting(
    client: *Client,
    arena: Allocator,
    subaccount_id: []const u8,
    enabled: bool,
) !std.json.Value {
    if (!client.hasCredentials()) return error.MissingCredentials;
    const Body = struct { netting_enabled: bool };
    var aw: std.Io.Writer.Allocating = .init(arena);
    try std.json.Stringify.value(
        Body{ .netting_enabled = enabled },
        .{ .whitespace = .minified, .emit_null_optional_fields = false },
        &aw.writer,
    );
    const path = try std.fmt.allocPrint(arena, "/portfolio/subaccounts/{s}/netting", .{subaccount_id});
    const resp = try client.request(arena, .{
        .path = path,
        .method = .PUT,
        .body = aw.written(),
    });
    if (!resp.isSuccess()) return error.HttpStatus;
    return std.json.parseFromSliceLeaky(std.json.Value, arena, resp.body, .{});
}

fn getJsonValue(
    client: *Client,
    arena: Allocator,
    path: []const u8,
    query: []const QueryParam,
) !std.json.Value {
    if (!client.hasCredentials()) return error.MissingCredentials;
    const resp = try client.request(arena, .{ .path = path, .query = query });
    if (!resp.isSuccess()) return error.HttpStatus;
    return std.json.parseFromSliceLeaky(std.json.Value, arena, resp.body, .{});
}

fn getJson(
    comptime T: type,
    client: *Client,
    arena: Allocator,
    path: []const u8,
    query: []const QueryParam,
) !T {
    if (!client.hasCredentials()) return error.MissingCredentials;
    const resp = try client.request(arena, .{ .path = path, .query = query });
    if (!resp.isSuccess()) return error.HttpStatus;
    return resp.parseInto(T, arena);
}

fn queryFromList(arena: Allocator, opts: ListOptions) ![]const QueryParam {
    var q: std.array_list.Managed(QueryParam) = .init(arena);
    if (opts.limit) |v| try q.append(.{ .key = "limit", .value = try std.fmt.allocPrint(arena, "{d}", .{v}) });
    if (opts.cursor) |v| try q.append(.{ .key = "cursor", .value = v });
    if (opts.ticker) |v| try q.append(.{ .key = "ticker", .value = v });
    if (opts.event_ticker) |v| try q.append(.{ .key = "event_ticker", .value = v });
    if (opts.min_ts) |v| try q.append(.{ .key = "min_ts", .value = try std.fmt.allocPrint(arena, "{d}", .{v}) });
    if (opts.max_ts) |v| try q.append(.{ .key = "max_ts", .value = try std.fmt.allocPrint(arena, "{d}", .{v}) });
    return q.items;
}

const fixture_balance = @embedFile("testdata/portfolio_balance.json");
const fixture_positions = @embedFile("testdata/portfolio_positions.json");
const fixture_settlements = @embedFile("testdata/portfolio_settlements.json");
const fixture_fills = @embedFile("testdata/portfolio_fills.json");

test "parses /portfolio/balance fixture" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const parsed = try std.json.parseFromSliceLeaky(Balance, a, fixture_balance, .{ .ignore_unknown_fields = true });
    try std.testing.expect(parsed.balance >= 0);
    try std.testing.expect(parsed.balance_breakdown.len > 0);
    try std.testing.expectEqualStrings("100.0000", parsed.balance_breakdown[0].balance);
}

test "parses /portfolio/positions fixture (empty arrays)" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const parsed = try std.json.parseFromSliceLeaky(PositionsList, a, fixture_positions, .{ .ignore_unknown_fields = true });
    try std.testing.expectEqual(@as(usize, 0), parsed.market_positions.len);
    try std.testing.expectEqual(@as(usize, 0), parsed.event_positions.len);
}

test "parses /portfolio/settlements fixture (untyped values)" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const parsed = try std.json.parseFromSliceLeaky(SettlementsList, a, fixture_settlements, .{ .ignore_unknown_fields = true });
    try std.testing.expectEqualStrings("next-page-token", parsed.cursor);
    try std.testing.expectEqual(@as(usize, 4), parsed.settlements.len);
}

test "parses /portfolio/settlements fixture (typed records)" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const parsed = try std.json.parseFromSliceLeaky(SettlementsListTyped, a, fixture_settlements, .{ .ignore_unknown_fields = true });
    try std.testing.expectEqualStrings("next-page-token", parsed.cursor);
    try std.testing.expectEqual(@as(usize, 4), parsed.settlements.len);

    // First record: yes-resolved, only yes side held.
    try std.testing.expectEqualStrings("KX-YES-WIN", parsed.settlements[0].ticker);
    try std.testing.expectEqualStrings("yes", parsed.settlements[0].market_result);
    try std.testing.expectEqual(@as(u32, 5), parsed.settlements[0].yes_count);
    try std.testing.expectEqual(@as(u32, 0), parsed.settlements[0].no_count);
    try std.testing.expectEqual(@as(i64, 150), parsed.settlements[0].yes_total_cost);
    try std.testing.expectEqual(@as(i64, 500), parsed.settlements[0].revenue);

    // Both-held record covers the split case.
    try std.testing.expectEqualStrings("KX-BOTH-HELD", parsed.settlements[2].ticker);
    try std.testing.expectEqual(@as(u32, 2), parsed.settlements[2].yes_count);
    try std.testing.expectEqual(@as(u32, 1), parsed.settlements[2].no_count);

    // Voided record's market_result is preserved verbatim.
    try std.testing.expectEqualStrings("void", parsed.settlements[3].market_result);
}

test "parses /portfolio/fills fixture" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const parsed = try std.json.parseFromSliceLeaky(FillsList, a, fixture_fills, .{ .ignore_unknown_fields = true });
    try std.testing.expectEqual(@as(usize, 0), parsed.fills.len);
}

test {
    _ = restingValue;
    _ = subaccountsBalances;
    _ = listSubaccountTransfers;
    _ = getNetting;
    _ = createSubaccount;
    _ = transferBetweenSubaccounts;
    _ = setNetting;
}

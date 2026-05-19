//! market + thesis manifest schemas.
//!
//! markets/<TICKER>/manifest.json:
//!   {"kind":"market","ticker":"KXBTC-...","trigger":{"price_delta_cents":1}}
//!
//! theses/<id>/manifest.json:
//!   {"kind":"thesis","id":"fed-cuts-june-2026","description":"...",
//!    "market_set":["KXFED-JUN-CUT","KXRECESSION-Q2"],
//!    "rollup_fn":"weighted_avg_v1","weights":{"KXFED-JUN-CUT":7000,"KXRECESSION-Q2":3000},
//!    "trigger":{"confidence_delta_bp":500}}

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const MarketManifest = struct {
    allocator: Allocator,
    ticker: []u8,
    price_delta_cents: u32,

    pub fn deinit(self: *MarketManifest) void {
        self.allocator.free(self.ticker);
    }
};

pub const ThesisManifest = struct {
    allocator: Allocator,
    id: []u8,
    description: []u8,
    rollup_fn: []u8,
    market_set: [][]u8,
    weights_bp: []u32, // parallel to market_set
    confidence_delta_bp: u32,

    pub fn deinit(self: *ThesisManifest) void {
        self.allocator.free(self.id);
        self.allocator.free(self.description);
        self.allocator.free(self.rollup_fn);
        for (self.market_set) |t| self.allocator.free(t);
        self.allocator.free(self.market_set);
        self.allocator.free(self.weights_bp);
    }
};

pub fn parseMarket(allocator: Allocator, json: []const u8) !MarketManifest {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    const kind = (root.get("kind") orelse return error.MissingKind).string;
    if (!std.mem.eql(u8, kind, "market")) return error.WrongManifestKind;
    const ticker_v = root.get("ticker") orelse return error.MissingTicker;
    const trigger = (root.get("trigger") orelse return error.MissingTrigger).object;
    const pd = trigger.get("price_delta_cents") orelse return error.MissingPriceDelta;
    return .{
        .allocator = allocator,
        .ticker = try allocator.dupe(u8, ticker_v.string),
        .price_delta_cents = @intCast(pd.integer),
    };
}

pub fn parseThesis(allocator: Allocator, json: []const u8) !ThesisManifest {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    const kind = (root.get("kind") orelse return error.MissingKind).string;
    if (!std.mem.eql(u8, kind, "thesis")) return error.WrongManifestKind;

    const id_v = root.get("id") orelse return error.MissingId;
    const description_v = root.get("description") orelse return error.MissingDescription;
    const rollup_fn_v = root.get("rollup_fn") orelse return error.MissingRollupFn;
    const market_arr = (root.get("market_set") orelse return error.MissingMarketSet).array;
    const weights_obj = (root.get("weights") orelse return error.MissingWeights).object;
    const trigger = (root.get("trigger") orelse return error.MissingTrigger).object;
    const cd = trigger.get("confidence_delta_bp") orelse return error.MissingConfidenceDelta;

    const market_set = try allocator.alloc([]u8, market_arr.items.len);
    errdefer allocator.free(market_set);
    const weights = try allocator.alloc(u32, market_arr.items.len);
    errdefer allocator.free(weights);

    for (market_arr.items, 0..) |item, i| {
        market_set[i] = try allocator.dupe(u8, item.string);
        const w = weights_obj.get(item.string) orelse return error.MissingTickerWeight;
        weights[i] = @intCast(w.integer);
    }

    return .{
        .allocator = allocator,
        .id = try allocator.dupe(u8, id_v.string),
        .description = try allocator.dupe(u8, description_v.string),
        .rollup_fn = try allocator.dupe(u8, rollup_fn_v.string),
        .market_set = market_set,
        .weights_bp = weights,
        .confidence_delta_bp = @intCast(cd.integer),
    };
}

/// Semantic checks on top of parseMarket. Length, charset, and range.
pub fn validateMarket(m: *const MarketManifest) !void {
    if (m.ticker.len == 0 or m.ticker.len > 64) return error.TickerLengthOutOfRange;
    for (m.ticker) |c| {
        // Real Kalshi tickers include `.` in numeric threshold suffixes
        // (e.g. KXTEMPNYCH-26MAY1821-T87.99). Allow it alongside the
        // alphanumeric + hyphen baseline.
        const ok = (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '-' or c == '.';
        if (!ok) return error.TickerHasInvalidChar;
    }
    if (m.price_delta_cents == 0 or m.price_delta_cents > 100) return error.PriceDeltaOutOfRange;
}

test "validateMarket accepts a well-formed manifest" {
    const json = "{\"kind\":\"market\",\"ticker\":\"KXBTC-26\",\"trigger\":{\"price_delta_cents\":1}}";
    var m = try parseMarket(std.testing.allocator, json);
    defer m.deinit();
    try validateMarket(&m);
}

test "validateMarket rejects an empty ticker" {
    const json = "{\"kind\":\"market\",\"ticker\":\"\",\"trigger\":{\"price_delta_cents\":1}}";
    var m = try parseMarket(std.testing.allocator, json);
    defer m.deinit();
    try std.testing.expectError(error.TickerLengthOutOfRange, validateMarket(&m));
}

test "validateMarket rejects a ticker with invalid characters" {
    const json = "{\"kind\":\"market\",\"ticker\":\"kx bad\",\"trigger\":{\"price_delta_cents\":1}}";
    var m = try parseMarket(std.testing.allocator, json);
    defer m.deinit();
    try std.testing.expectError(error.TickerHasInvalidChar, validateMarket(&m));
}

test "validateMarket accepts tickers with `.` in threshold suffixes" {
    // Real Kalshi ticker shape — e.g. KXTEMPNYCH-26MAY1821-T87.99
    const json = "{\"kind\":\"market\",\"ticker\":\"KXTEMPNYCH-26MAY1821-T87.99\",\"trigger\":{\"price_delta_cents\":1}}";
    var m = try parseMarket(std.testing.allocator, json);
    defer m.deinit();
    try validateMarket(&m);
}

test "validateMarket rejects price_delta_cents = 0" {
    const json = "{\"kind\":\"market\",\"ticker\":\"KX\",\"trigger\":{\"price_delta_cents\":0}}";
    var m = try parseMarket(std.testing.allocator, json);
    defer m.deinit();
    try std.testing.expectError(error.PriceDeltaOutOfRange, validateMarket(&m));
}

test "parseMarket extracts ticker + price_delta_cents" {
    const json =
        \\{"kind":"market","ticker":"KXBTC-26APR10-T100000","trigger":{"price_delta_cents":1}}
    ;
    var m = try parseMarket(std.testing.allocator, json);
    defer m.deinit();
    try std.testing.expectEqualStrings("KXBTC-26APR10-T100000", m.ticker);
    try std.testing.expectEqual(@as(u32, 1), m.price_delta_cents);
}

test "parseMarket returns MissingTicker when ticker is absent" {
    const json = "{\"kind\":\"market\",\"trigger\":{\"price_delta_cents\":1}}";
    try std.testing.expectError(error.MissingTicker, parseMarket(std.testing.allocator, json));
}

test "parseMarket returns MissingTrigger when trigger is absent" {
    const json = "{\"kind\":\"market\",\"ticker\":\"KXTEST\"}";
    try std.testing.expectError(error.MissingTrigger, parseMarket(std.testing.allocator, json));
}

test "parseMarket returns MissingPriceDelta when trigger.price_delta_cents is absent" {
    const json = "{\"kind\":\"market\",\"ticker\":\"KXTEST\",\"trigger\":{}}";
    try std.testing.expectError(error.MissingPriceDelta, parseMarket(std.testing.allocator, json));
}

/// Semantic checks on top of parseThesis. Length/charset on id and description,
/// non-empty market_set with weights summing to 10000 bp, range on confidence_delta_bp.
pub fn validateThesis(t: *const ThesisManifest) !void {
    if (t.id.len == 0 or t.id.len > 64) return error.ThesisIdInvalid;
    for (t.id) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '-';
        if (!ok) return error.ThesisIdInvalid;
    }
    if (t.description.len == 0 or t.description.len > 512) return error.DescriptionLengthOutOfRange;
    if (t.market_set.len == 0) return error.EmptyMarketSet;
    if (t.market_set.len != t.weights_bp.len) return error.WeightSetMismatch;
    var sum: u64 = 0;
    for (t.weights_bp) |w| sum += w;
    if (sum != 10000) return error.WeightSumMismatch;
    if (t.confidence_delta_bp == 0 or t.confidence_delta_bp > 10000) return error.ConfidenceDeltaOutOfRange;
    if (t.rollup_fn.len == 0) return error.MissingRollupFn;
}

test "validateThesis accepts a well-formed manifest" {
    const json =
        \\{"kind":"thesis","id":"fed-cuts","description":"x","market_set":["A","B"],
        \\"rollup_fn":"weighted_avg_v1","weights":{"A":7000,"B":3000},
        \\"trigger":{"confidence_delta_bp":500}}
    ;
    var t = try parseThesis(std.testing.allocator, json);
    defer t.deinit();
    try validateThesis(&t);
}

test "validateThesis rejects weights that don't sum to 10000" {
    const json =
        \\{"kind":"thesis","id":"t","description":"x","market_set":["A","B"],
        \\"rollup_fn":"f","weights":{"A":7000,"B":2000},
        \\"trigger":{"confidence_delta_bp":500}}
    ;
    var t = try parseThesis(std.testing.allocator, json);
    defer t.deinit();
    try std.testing.expectError(error.WeightSumMismatch, validateThesis(&t));
}

test "validateThesis rejects an empty market_set" {
    const json =
        \\{"kind":"thesis","id":"t","description":"x","market_set":[],
        \\"rollup_fn":"f","weights":{},"trigger":{"confidence_delta_bp":500}}
    ;
    var t = try parseThesis(std.testing.allocator, json);
    defer t.deinit();
    try std.testing.expectError(error.EmptyMarketSet, validateThesis(&t));
}

test "validateThesis rejects id with uppercase" {
    const json =
        \\{"kind":"thesis","id":"FED","description":"x","market_set":["A"],
        \\"rollup_fn":"f","weights":{"A":10000},"trigger":{"confidence_delta_bp":500}}
    ;
    var t = try parseThesis(std.testing.allocator, json);
    defer t.deinit();
    try std.testing.expectError(error.ThesisIdInvalid, validateThesis(&t));
}

test "validateThesis rejects confidence_delta_bp = 0" {
    const json =
        \\{"kind":"thesis","id":"t","description":"x","market_set":["A"],
        \\"rollup_fn":"f","weights":{"A":10000},"trigger":{"confidence_delta_bp":0}}
    ;
    var t = try parseThesis(std.testing.allocator, json);
    defer t.deinit();
    try std.testing.expectError(error.ConfidenceDeltaOutOfRange, validateThesis(&t));
}

test "parseThesis returns MissingId when id is absent" {
    const json =
        \\{"kind":"thesis","description":"x","market_set":["A"],"rollup_fn":"f",
        \\"weights":{"A":10000},"trigger":{"confidence_delta_bp":500}}
    ;
    try std.testing.expectError(error.MissingId, parseThesis(std.testing.allocator, json));
}

test "parseThesis returns MissingMarketSet when market_set is absent" {
    const json =
        \\{"kind":"thesis","id":"t","description":"x","rollup_fn":"f",
        \\"weights":{},"trigger":{"confidence_delta_bp":500}}
    ;
    try std.testing.expectError(error.MissingMarketSet, parseThesis(std.testing.allocator, json));
}

test "parseThesis returns MissingWeights when weights is absent" {
    const json =
        \\{"kind":"thesis","id":"t","description":"x","market_set":["A"],
        \\"rollup_fn":"f","trigger":{"confidence_delta_bp":500}}
    ;
    try std.testing.expectError(error.MissingWeights, parseThesis(std.testing.allocator, json));
}

test "parseThesis returns MissingConfidenceDelta when trigger.confidence_delta_bp is absent" {
    const json =
        \\{"kind":"thesis","id":"t","description":"x","market_set":["A"],
        \\"rollup_fn":"f","weights":{"A":10000},"trigger":{}}
    ;
    try std.testing.expectError(error.MissingConfidenceDelta, parseThesis(std.testing.allocator, json));
}

test "parseThesis reads market_set + weights in parallel" {
    const json =
        \\{"kind":"thesis","id":"fed-cuts-june-2026","description":"Fed cuts in June",
        \\"market_set":["KXFED-JUN-CUT","KXRECESSION-Q2"],"rollup_fn":"weighted_avg_v1",
        \\"weights":{"KXFED-JUN-CUT":7000,"KXRECESSION-Q2":3000},
        \\"trigger":{"confidence_delta_bp":500}}
    ;
    var t = try parseThesis(std.testing.allocator, json);
    defer t.deinit();
    try std.testing.expectEqualStrings("fed-cuts-june-2026", t.id);
    try std.testing.expectEqual(@as(usize, 2), t.market_set.len);
    try std.testing.expectEqualStrings("KXFED-JUN-CUT", t.market_set[0]);
    try std.testing.expectEqual(@as(u32, 7000), t.weights_bp[0]);
}

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
    if (!std.mem.eql(u8, root.get("kind").?.string, "thesis")) return error.WrongManifestKind;

    const market_arr = root.get("market_set").?.array;
    const market_set = try allocator.alloc([]u8, market_arr.items.len);
    errdefer allocator.free(market_set);
    const weights = try allocator.alloc(u32, market_arr.items.len);
    errdefer allocator.free(weights);

    const weights_obj = root.get("weights").?.object;
    for (market_arr.items, 0..) |item, i| {
        market_set[i] = try allocator.dupe(u8, item.string);
        weights[i] = @intCast(weights_obj.get(item.string).?.integer);
    }

    return .{
        .allocator = allocator,
        .id = try allocator.dupe(u8, root.get("id").?.string),
        .description = try allocator.dupe(u8, root.get("description").?.string),
        .rollup_fn = try allocator.dupe(u8, root.get("rollup_fn").?.string),
        .market_set = market_set,
        .weights_bp = weights,
        .confidence_delta_bp = @intCast(root.get("trigger").?.object.get("confidence_delta_bp").?.integer),
    };
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

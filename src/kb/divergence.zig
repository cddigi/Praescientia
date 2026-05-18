//! kb.divergence — compare prediction chains against reality chains.
//!
//! Two complementary views:
//!   - temporalDivergence: walks predictions in order, pairs each with the
//!     most-recent reality entry whose ts ≤ prediction.ts, and returns the
//!     index of the first prediction whose |delta| crosses `threshold_bp`.
//!     Used while the market is live — "when did our belief drift?"
//!   - outcomeDivergence (Task 4.2): given a resolution, finds the last
//!     prediction that disagreed with the eventual outcome.

const std = @import("std");
const Allocator = std.mem.Allocator;
const chain_mod = @import("chain.zig");
const txlog = @import("../txlog.zig");

pub const TemporalDivergence = struct {
    /// Index of the first prediction (within `prediction.log.items.items`)
    /// whose belief diverged from the matched reality by ≥ threshold_bp.
    /// `null` when no prediction crossed the threshold.
    first_drift_idx: ?usize,
    /// Drift at `first_drift_idx`, in basis points (1 cent = 100 bp).
    drift_amount_bp: u32,
    /// Echoed back so the caller can format a one-liner without re-passing it.
    threshold_bp: u32,
};

/// Compute the first temporal divergence between a prediction chain and a
/// reality chain. Both payloads must carry numeric `yes_bid_cents` and `ts`
/// fields; entries missing either are skipped.
pub fn temporalDivergence(
    allocator: Allocator,
    prediction: *const chain_mod.Chain,
    reality: *const chain_mod.Chain,
    threshold_bp: u32,
) !TemporalDivergence {
    for (prediction.log.items.items, 0..) |pred_tx, idx| {
        const pred = try parsePayload(allocator, pred_tx.payload);
        const pb = pred.yes_bid_cents orelse continue;

        // Find the most-recent reality entry with ts ≤ pred.ts.
        var reality_bid: ?u32 = null;
        for (reality.log.items.items) |real_tx| {
            const real = try parsePayload(allocator, real_tx.payload);
            if (real.ts > pred.ts) break;
            if (real.yes_bid_cents) |rb| reality_bid = rb;
        }
        const rb = reality_bid orelse continue;

        const delta_cents: u32 = if (pb > rb) pb - rb else rb - pb;
        const delta_bp: u32 = delta_cents * 100;
        if (delta_bp >= threshold_bp) {
            return .{
                .first_drift_idx = idx,
                .drift_amount_bp = delta_bp,
                .threshold_bp = threshold_bp,
            };
        }
    }
    return .{ .first_drift_idx = null, .drift_amount_bp = 0, .threshold_bp = threshold_bp };
}

// --- helpers shared with Task 4.2 ----------------------------------------

/// Minimal payload view used by the divergence helpers.
const PayloadView = struct {
    ts: u64,
    yes_bid_cents: ?u32,
    confidence_bp: ?u32,
    resolved_yes: ?bool,
};

fn parsePayload(allocator: Allocator, payload: []const u8) !PayloadView {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    const ts: u64 = if (obj.get("ts")) |v| @intCast(v.integer) else 0;
    const yes_bid: ?u32 = if (obj.get("yes_bid_cents")) |v|
        @intCast(v.integer)
    else
        null;
    const conf: ?u32 = if (obj.get("confidence_bp")) |v|
        @intCast(v.integer)
    else
        null;
    const resolved: ?bool = if (obj.get("resolved_yes")) |v| v.bool else null;
    return .{
        .ts = ts,
        .yes_bid_cents = yes_bid,
        .confidence_bp = conf,
        .resolved_yes = resolved,
    };
}

pub const OutcomeDivergence = struct {
    /// Index of the last prediction (within `prediction.log.items.items`) that
    /// disagreed with the eventual outcome. `null` when every prediction agreed.
    /// Predictions without `confidence_bp` are skipped.
    first_wrong_idx: ?usize,
    /// Echoed back so the caller can format a one-liner.
    resolved_yes: bool,
};

/// Given a market's terminal outcome (`resolved_yes`), find the most-recent
/// prediction that disagreed with that outcome. A prediction agrees with
/// `yes` when `confidence_bp > 5000`, with `no` when `confidence_bp < 5000`.
/// Exactly 5000 is treated as undecided — disagreement.
pub fn outcomeDivergence(
    allocator: Allocator,
    prediction: *const chain_mod.Chain,
    resolved_yes: bool,
) !OutcomeDivergence {
    var i: usize = prediction.log.items.items.len;
    while (i > 0) {
        i -= 1;
        const tx = prediction.log.items.items[i];
        const v = try parsePayload(allocator, tx.payload);
        const conf = v.confidence_bp orelse continue;
        const agrees = if (resolved_yes) conf > 5000 else conf < 5000;
        if (!agrees) return .{ .first_wrong_idx = i, .resolved_yes = resolved_yes };
    }
    return .{ .first_wrong_idx = null, .resolved_yes = resolved_yes };
}

// --- tests ---------------------------------------------------------------

fn appendCanonical(log: *txlog.TxLog, payload: []const u8) !void {
    _ = try log.append(payload);
}

test "temporalDivergence finds first prediction whose belief diverges from reality past threshold" {
    // Both chains have aligned timestamps. Reality stays at 55c past t=200;
    // prediction overshoots to 70c at t=300. Threshold = 1000 bp (= 10c).
    // Drift at idx 2: |70 - 55| * 100 = 1500 bp ≥ 1000 → first_drift_idx = 2.
    var reality_log: txlog.TxLog = .init(std.testing.allocator);
    defer reality_log.deinit();
    try appendCanonical(&reality_log, "{\"ts\":100,\"yes_bid_cents\":50}");
    try appendCanonical(&reality_log, "{\"ts\":200,\"yes_bid_cents\":55}");
    try appendCanonical(&reality_log, "{\"ts\":300,\"yes_bid_cents\":55}");

    var pred_log: txlog.TxLog = .init(std.testing.allocator);
    defer pred_log.deinit();
    try appendCanonical(&pred_log, "{\"ts\":100,\"yes_bid_cents\":50}");
    try appendCanonical(&pred_log, "{\"ts\":200,\"yes_bid_cents\":55}");
    try appendCanonical(&pred_log, "{\"ts\":300,\"yes_bid_cents\":70}");

    const reality_chain: chain_mod.Chain = .{
        .allocator = std.testing.allocator,
        .log = reality_log,
        .branch_name = try std.testing.allocator.dupe(u8, "main"),
    };
    defer std.testing.allocator.free(reality_chain.branch_name);
    const pred_chain: chain_mod.Chain = .{
        .allocator = std.testing.allocator,
        .log = pred_log,
        .branch_name = try std.testing.allocator.dupe(u8, "main"),
    };
    defer std.testing.allocator.free(pred_chain.branch_name);

    const d = try temporalDivergence(std.testing.allocator, &pred_chain, &reality_chain, 1000);
    try std.testing.expectEqual(@as(?usize, 2), d.first_drift_idx);
    try std.testing.expectEqual(@as(u32, 1500), d.drift_amount_bp);
    try std.testing.expectEqual(@as(u32, 1000), d.threshold_bp);
}

test "outcomeDivergence finds last wrong prediction before settling" {
    // Predictions: 4000, 5500, 6500, 7000 bp confidence on yes; resolution=yes.
    // 4000 < 5000 → disagrees; the next three all agree. Last wrong = idx 0.
    var pred_log: txlog.TxLog = .init(std.testing.allocator);
    defer pred_log.deinit();
    try appendCanonical(&pred_log, "{\"confidence_bp\":4000,\"ts\":100}");
    try appendCanonical(&pred_log, "{\"confidence_bp\":5500,\"ts\":200}");
    try appendCanonical(&pred_log, "{\"confidence_bp\":6500,\"ts\":300}");
    try appendCanonical(&pred_log, "{\"confidence_bp\":7000,\"ts\":400}");

    const pred_chain: chain_mod.Chain = .{
        .allocator = std.testing.allocator,
        .log = pred_log,
        .branch_name = try std.testing.allocator.dupe(u8, "main"),
    };
    defer std.testing.allocator.free(pred_chain.branch_name);

    const d = try outcomeDivergence(std.testing.allocator, &pred_chain, true);
    try std.testing.expectEqual(@as(?usize, 0), d.first_wrong_idx);
    try std.testing.expectEqual(true, d.resolved_yes);
}

test "outcomeDivergence returns null when every prediction agrees with outcome" {
    var pred_log: txlog.TxLog = .init(std.testing.allocator);
    defer pred_log.deinit();
    try appendCanonical(&pred_log, "{\"confidence_bp\":5500,\"ts\":100}");
    try appendCanonical(&pred_log, "{\"confidence_bp\":7000,\"ts\":200}");

    const pred_chain: chain_mod.Chain = .{
        .allocator = std.testing.allocator,
        .log = pred_log,
        .branch_name = try std.testing.allocator.dupe(u8, "main"),
    };
    defer std.testing.allocator.free(pred_chain.branch_name);

    const d = try outcomeDivergence(std.testing.allocator, &pred_chain, true);
    try std.testing.expectEqual(@as(?usize, null), d.first_wrong_idx);
}

test "outcomeDivergence with resolved_no flips the agreement direction" {
    var pred_log: txlog.TxLog = .init(std.testing.allocator);
    defer pred_log.deinit();
    try appendCanonical(&pred_log, "{\"confidence_bp\":8000,\"ts\":100}"); // wrong: predicted yes, resolved no
    try appendCanonical(&pred_log, "{\"confidence_bp\":3000,\"ts\":200}"); // right
    try appendCanonical(&pred_log, "{\"confidence_bp\":2000,\"ts\":300}"); // right

    const pred_chain: chain_mod.Chain = .{
        .allocator = std.testing.allocator,
        .log = pred_log,
        .branch_name = try std.testing.allocator.dupe(u8, "main"),
    };
    defer std.testing.allocator.free(pred_chain.branch_name);

    const d = try outcomeDivergence(std.testing.allocator, &pred_chain, false);
    try std.testing.expectEqual(@as(?usize, 0), d.first_wrong_idx);
}

test "temporalDivergence returns null when chains agree within threshold" {
    var reality_log: txlog.TxLog = .init(std.testing.allocator);
    defer reality_log.deinit();
    try appendCanonical(&reality_log, "{\"ts\":100,\"yes_bid_cents\":50}");
    try appendCanonical(&reality_log, "{\"ts\":200,\"yes_bid_cents\":55}");

    var pred_log: txlog.TxLog = .init(std.testing.allocator);
    defer pred_log.deinit();
    try appendCanonical(&pred_log, "{\"ts\":100,\"yes_bid_cents\":51}");
    try appendCanonical(&pred_log, "{\"ts\":200,\"yes_bid_cents\":56}");

    const reality_chain: chain_mod.Chain = .{
        .allocator = std.testing.allocator,
        .log = reality_log,
        .branch_name = try std.testing.allocator.dupe(u8, "main"),
    };
    defer std.testing.allocator.free(reality_chain.branch_name);
    const pred_chain: chain_mod.Chain = .{
        .allocator = std.testing.allocator,
        .log = pred_log,
        .branch_name = try std.testing.allocator.dupe(u8, "main"),
    };
    defer std.testing.allocator.free(pred_chain.branch_name);

    // 1c off = 100 bp; threshold 200 bp → no divergence.
    const d = try temporalDivergence(std.testing.allocator, &pred_chain, &reality_chain, 200);
    try std.testing.expectEqual(@as(?usize, null), d.first_drift_idx);
}

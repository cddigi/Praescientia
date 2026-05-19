//! kb.ticks — tick primitives for the autonomous prediction agent.
//!
//! Each tick is a single state transition with a ULID identifier. The
//! orchestrator snapshots chain heads before and after, writes events to
//! a per-tick JSONL file, and tracks rejected sub-agent decisions on the
//! side. All paths live under `<kb_root>/.ticks/`.
//!
//! This module owns just the primitives — types, ULIDs, paths, and
//! schema/cap validation. The `praescientia-ticks` CLI (Stage 2) and the
//! orchestrate skill (Stage 5) compose them.

const std = @import("std");
const Allocator = std.mem.Allocator;

const txlog = @import("../txlog.zig");
const chain_mod = @import("chain.zig");
const branches_mod = @import("branches.zig");
const manifest_mod = @import("manifest.zig");
const state_chain = @import("../state_chain.zig");
const Hash = state_chain.Hash;

/// Length of the ULID portion of a tick id (Crockford-base32, 26 chars).
pub const tick_id_len: usize = 26;

/// One tick. Created at the start of a tick; the `id` is the audit anchor
/// for every artifact the tick produces (chain entries, snapshot files,
/// rejection logs, client_order_ids).
pub const Tick = struct {
    id: [tick_id_len]u8,

    /// Generate a fresh tick. ULID body = 48-bit Unix-ms timestamp + 80-bit
    /// CSPRNG randomness. Monotonic across ms boundaries but not within a
    /// single ms — fine for tick cadences measured in minutes.
    pub fn init() Tick {
        var tick: Tick = undefined;
        var tx_buf: [txlog.tx_id_len]u8 = undefined;
        txlog.generateTxId(&tx_buf);
        // generateTxId emits "tx_<26-char ULID>"; we only need the ULID body.
        @memcpy(&tick.id, tx_buf[3..][0..tick_id_len]);
        return tick;
    }

    /// Compose the on-disk path for one of the tick's artifact files.
    /// `buf` must be large enough to hold the full path; on overflow returns
    /// `error.NoSpaceLeft` (the `std.fmt.bufPrint` contract).
    pub fn path(self: *const Tick, buf: []u8, kb_root: []const u8, kind: PathKind) ![]u8 {
        return std.fmt.bufPrint(buf, "{s}/.ticks/{s}.{s}.{s}", .{
            kb_root,
            self.id[0..],
            @tagName(kind),
            kind.extension(),
        });
    }
};

/// The four per-tick artifact kinds. Determines both the filename suffix
/// and the file extension (`events` is JSONL; everything else is single-
/// object JSON).
pub const PathKind = enum {
    pre,
    post,
    events,
    rejected,

    fn extension(self: PathKind) []const u8 {
        return switch (self) {
            .events => "jsonl",
            .pre, .post, .rejected => "json",
        };
    }
};

// ---------------------------------------------------------------------------
// Chain-head snapshots
// ---------------------------------------------------------------------------

/// Per-chain snapshot entry. Identifies one chain by its kb_root-relative
/// path and captures the active-branch head at snapshot time. Used as both
/// the pre-tick rollback anchor and the post-tick "what changed" delta.
///
/// `scope_path` and `branch` are owned by `allocator`; free via `free(allocator)`
/// or by calling `freeSnapshot(allocator, slice)`.
pub const SnapshotEntry = struct {
    /// kb_root-relative chain directory path. Examples:
    ///   - "commentary/global"
    ///   - "markets/SAMPLE/reality"
    ///   - "theses/sample/prediction"
    scope_path: []const u8,
    /// Active branch name (typically "main").
    branch: []const u8,
    /// Hex-encoded head hash, or null for an empty chain.
    head_hash: ?[64]u8,
    /// Number of entries in the active branch.
    length: usize,

    pub fn free(self: SnapshotEntry, allocator: Allocator) void {
        allocator.free(self.scope_path);
        allocator.free(self.branch);
    }
};

/// Free every owned string in a snapshot slice plus the slice itself.
pub fn freeSnapshot(allocator: Allocator, entries: []SnapshotEntry) void {
    for (entries) |e| e.free(allocator);
    allocator.free(entries);
}

/// Walk the chain tree under `kb_root` and return one entry per chain.
/// Visits, in this order before sorting:
///
///   commentary/global/             (if present — only created on first write)
///   markets/<TICKER>/reality/
///   markets/<TICKER>/commentary/
///   theses/<id>/reality/
///   theses/<id>/prediction/
///   theses/<id>/commentary/
///
/// The returned slice is sorted alphabetically by `scope_path` for
/// canonical/deterministic output. A missing chain dir under a market or
/// thesis is silently skipped — it may simply not have been admitted yet.
/// Caller owns the returned slice; use `freeSnapshot` to release.
pub fn snapshotHeads(allocator: Allocator, io: std.Io, kb_root: std.Io.Dir) ![]SnapshotEntry {
    var list: std.array_list.Managed(SnapshotEntry) = .init(allocator);
    errdefer {
        for (list.items) |e| e.free(allocator);
        list.deinit();
    }

    // Global commentary — optional, created on first write.
    try collectChainIfPresent(allocator, io, kb_root, "commentary/global", &list);

    // Markets — each one has reality/ and commentary/.
    try collectGroup(allocator, io, kb_root, "markets", &[_][]const u8{ "reality", "commentary" }, &list);

    // Theses — each one has reality/, prediction/, and commentary/.
    try collectGroup(allocator, io, kb_root, "theses", &[_][]const u8{ "reality", "prediction", "commentary" }, &list);

    const entries = try list.toOwnedSlice();
    errdefer freeSnapshot(allocator, entries);

    std.mem.sort(SnapshotEntry, entries, {}, snapshotEntryLessThan);
    return entries;
}

fn snapshotEntryLessThan(_: void, a: SnapshotEntry, b: SnapshotEntry) bool {
    return std.mem.lessThan(u8, a.scope_path, b.scope_path);
}

fn collectGroup(
    allocator: Allocator,
    io: std.Io,
    kb_root: std.Io.Dir,
    group: []const u8, // "markets" or "theses"
    chain_kinds: []const []const u8,
    list: *std.array_list.Managed(SnapshotEntry),
) !void {
    var group_dir = kb_root.openDir(io, group, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer group_dir.close(io);

    var iter = group_dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind != .directory) continue;

        for (chain_kinds) |kind| {
            var path_buf: [512]u8 = undefined;
            const rel = try std.fmt.bufPrint(&path_buf, "{s}/{s}/{s}", .{ group, entry.name, kind });
            try collectChainIfPresent(allocator, io, kb_root, rel, list);
        }
    }
}

fn collectChainIfPresent(
    allocator: Allocator,
    io: std.Io,
    kb_root: std.Io.Dir,
    scope_path: []const u8,
    list: *std.array_list.Managed(SnapshotEntry),
) !void {
    var chain_dir = kb_root.openDir(io, scope_path, .{ .iterate = false }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer chain_dir.close(io);

    // Load branches.json to learn the active branch.
    const branches_data = chain_dir.readFileAlloc(io, "branches.json", allocator, .unlimited) catch |err| switch (err) {
        error.FileNotFound => return, // partially-initialized chain dir — skip.
        else => return err,
    };
    defer allocator.free(branches_data);

    var bf = try branches_mod.parseSlice(allocator, branches_data);
    defer bf.deinit();

    const active = bf.active;

    // Read the active branch to extract head + length.
    var chain = try chain_mod.openRead(allocator, io, chain_dir, active);
    defer chain.deinit();

    var head_hex: ?[64]u8 = null;
    if (chain.head()) |h| {
        var buf: [64]u8 = undefined;
        hexEncodeHash(h, &buf);
        head_hex = buf;
    }

    try list.append(.{
        .scope_path = try allocator.dupe(u8, scope_path),
        .branch = try allocator.dupe(u8, active),
        .head_hash = head_hex,
        .length = chain.len(),
    });
}

fn hexEncodeHash(hash: Hash, out: *[64]u8) void {
    const hex = "0123456789abcdef";
    for (hash, 0..) |b, i| {
        out[i * 2] = hex[b >> 4];
        out[i * 2 + 1] = hex[b & 0xf];
    }
}

// ---------------------------------------------------------------------------
// Order intents
// ---------------------------------------------------------------------------

/// YES or NO side of a binary Kalshi market.
pub const Side = enum { yes, no };

/// Order operation. Matches the verbs `praescientia-orders` exposes.
pub const Action = enum { buy, sell, cancel, amend };

/// One order operation proposed by a sub-agent. The orchestrator validates
/// every field before translating into a Kalshi API call.
pub const OrderIntent = struct {
    ticker: []const u8,
    side: Side,
    action: Action,
    size: u32,
    limit_cents: u8,
    reason: []const u8 = "",
};

/// Tagged reasons for rejecting an `OrderIntent`. Maps 1:1 to the
/// rejection categories documented in the design's §6.
pub const ValidationError = error{
    /// `intent.ticker` is not in the thesis's `market_set` whitelist.
    TickerNotInManifest,
    /// `intent.size` exceeds the per-market position cap.
    SizeOverPerMarketCap,
    /// `intent.limit_cents` is outside Kalshi's `[1, 99]` range.
    LimitOutOfRange,
    /// `intent.size == 0` — Kalshi rejects these and we shouldn't ship them.
    SizeNonPositive,
    /// Combined cost of this order plus already-committed bankroll for this
    /// tick exceeds the per-thesis cap.
    BankrollCapExceeded,
};

/// State the validator needs beyond the intent itself. The orchestrator
/// computes this once per thesis per tick from current portfolio + manifest.
pub const PositionState = struct {
    /// Maximum contracts allowed in a single market position. §6 default 100.
    per_market_cap: u32 = 100,
    /// Per-thesis bankroll cap in cents, derived from `bankroll_cap_bp` and
    /// the current account balance.
    bankroll_cap_cents: u64,
    /// Cents already committed by earlier orders this tick on this thesis.
    /// Lets the validator catch the second order in a sequence that would
    /// individually fit but collectively breach the cap.
    bankroll_used_cents: u64 = 0,
};

/// Enforce §6 rules on a single order intent against the responsible
/// thesis's manifest and current position state. Returns nothing on success;
/// returns a tagged `ValidationError` otherwise. The orchestrator records
/// the rejection reason in `kb/.ticks/{tick_id}.rejected.json` and skips
/// that order without crashing the tick.
///
/// `buy` is the only action whose `size * limit_cents` charges the bankroll
/// — sells, cancels, and amends either release capital or are net-neutral
/// for this conservative gate.
pub fn validateOrderIntent(
    intent: OrderIntent,
    manifest: *const manifest_mod.ThesisManifest,
    state: PositionState,
) ValidationError!void {
    if (intent.size == 0) return ValidationError.SizeNonPositive;
    if (intent.size > state.per_market_cap) return ValidationError.SizeOverPerMarketCap;
    if (intent.limit_cents < 1 or intent.limit_cents > 99) return ValidationError.LimitOutOfRange;

    var found = false;
    for (manifest.market_set) |t| {
        if (std.mem.eql(u8, t, intent.ticker)) {
            found = true;
            break;
        }
    }
    if (!found) return ValidationError.TickerNotInManifest;

    if (intent.action == .buy) {
        const cost: u64 = @as(u64, intent.size) * @as(u64, intent.limit_cents);
        if (state.bankroll_used_cents +| cost > state.bankroll_cap_cents) {
            return ValidationError.BankrollCapExceeded;
        }
    }
}

// ---------------------------------------------------------------------------
// Client order ids
// ---------------------------------------------------------------------------

/// Kalshi accepts up to 64 bytes in `client_order_id`. The format we ship
/// below is 35 bytes wide so we never need to worry in practice.
pub const client_order_id_max_bytes: usize = 64;

pub const ClientOrderIdError = error{
    /// One of `tick_id`, `thesis`, or `ticker` was empty. The format
    /// requires all three to produce a sensible hash input.
    EmptyComponent,
    /// The caller's `out` buffer is smaller than the format requires.
    BufferTooSmall,
    /// The composed id exceeded `client_order_id_max_bytes` (would happen
    /// only if `tick_id` itself is pathological — kept as a defensive
    /// guard so a future tick_id shape change doesn't silently overflow).
    ClientOrderIdOverflow,
};

/// Build a deterministic, replay-safe `client_order_id` for a Kalshi
/// order. Format: `"{tick_id}-{8-hex-fnv1a32(thesis|ticker|side|action)}"`.
///
/// The format diverges from the design's literal `"tick-{tick_id}-{thesis}
/// -{ticker}-{side}-{action}"` because realistic Kalshi tickers (e.g.
/// `KXNBASPREAD-26MAY20SASOKC-SAS13`) push the readable form past the 64-byte
/// API cap. The 8-hex discriminator preserves replay-safety
/// (same tuple → same hash → same id) and per-tick uniqueness; readable
/// thesis/ticker grep-ability moves to the orchestrator's sidecar
/// `kb/.ticks/{tick_id}.order_map.json`, which maps id → readable tuple.
pub fn clientOrderId(
    out: []u8,
    tick_id: []const u8,
    thesis: []const u8,
    ticker: []const u8,
    side: Side,
    action: Action,
) ClientOrderIdError![]u8 {
    if (tick_id.len == 0 or thesis.len == 0 or ticker.len == 0) {
        return ClientOrderIdError.EmptyComponent;
    }

    // FNV-1a 32-bit over thesis|ticker|side|action. The `|` separators
    // prevent ambiguity like "ab"+"c" hashing identically to "a"+"bc".
    var hasher = std.hash.Fnv1a_32.init();
    hasher.update(thesis);
    hasher.update("|");
    hasher.update(ticker);
    hasher.update("|");
    hasher.update(@tagName(side));
    hasher.update("|");
    hasher.update(@tagName(action));
    const digest: u32 = hasher.final();

    const result = std.fmt.bufPrint(out, "{s}-{x:0>8}", .{ tick_id, digest }) catch {
        return ClientOrderIdError.BufferTooSmall;
    };
    if (result.len > client_order_id_max_bytes) {
        return ClientOrderIdError.ClientOrderIdOverflow;
    }
    return result;
}

// ---------------------------------------------------------------------------
// Clamping
// ---------------------------------------------------------------------------

/// Why an order's size got clamped down from what the sub-agent proposed.
/// `null` in `ClampResult.reason` means no clamp was needed.
pub const ClampReason = enum {
    /// Sub-agent asked for more contracts than the per-market position cap.
    PerMarketCap,
    /// Order would breach the per-thesis bankroll cap; reduced to fit.
    BankrollCap,
    /// Demo/live balance can't cover the requested size; reduced to fit.
    InsufficientBalance,
};

pub const ClampResult = struct {
    /// Clamped size (≤ original). May be 0 if the gate was fully shut.
    size: u32,
    /// Which constraint determined the clamp, or `null` if nothing bound.
    reason: ?ClampReason,
};

pub const ClampConfig = struct {
    /// Max contracts allowed in a single market position. §6 default 100.
    per_market_cap: u32 = 100,
    /// Cents still available for this thesis after prior-tick commitments.
    bankroll_remaining_cents: u64,
    /// Total account balance in cents.
    balance_cents: u64,
};

/// Compute the largest size we'd ship to Kalshi for this intent, given the
/// active caps. Used by the orchestrator's executor to do best-effort
/// execution instead of rejecting the order outright. The reason field
/// surfaces the binding constraint so it can be logged in the tick's
/// events JSONL.
///
/// Non-buy actions (sell, cancel, amend) don't consume capital and are
/// returned unchanged. A zero-size intent is also returned unchanged.
pub fn clampOrderSize(intent: OrderIntent, cfg: ClampConfig) ClampResult {
    if (intent.action != .buy) return .{ .size = intent.size, .reason = null };
    if (intent.size == 0 or intent.limit_cents == 0) {
        return .{ .size = intent.size, .reason = null };
    }

    const per_unit: u64 = @as(u64, intent.limit_cents);
    const max_bankroll: u32 = @intCast(@min(cfg.bankroll_remaining_cents / per_unit, @as(u64, std.math.maxInt(u32))));
    const max_balance: u32 = @intCast(@min(cfg.balance_cents / per_unit, @as(u64, std.math.maxInt(u32))));

    var size = intent.size;
    var reason: ?ClampReason = null;

    // Apply caps in policy precedence: per-market hard cap, then bankroll,
    // then account balance. Later binding constraints overwrite the reason
    // so the recorded reason names the constraint that actually shaped
    // the final size.
    if (cfg.per_market_cap < size) {
        size = cfg.per_market_cap;
        reason = .PerMarketCap;
    }
    if (max_bankroll < size) {
        size = max_bankroll;
        reason = .BankrollCap;
    }
    if (max_balance < size) {
        size = max_balance;
        reason = .InsufficientBalance;
    }

    return .{ .size = size, .reason = reason };
}

/// Write a canonical-JSON encoding of a snapshot slice. Top-level shape:
///
///   {"entries":[
///     {"branch":"main","head_hash":"<hex>|null","length":N,"scope_path":"..."},
///     ...
///   ]}
///
/// Keys alphabetical, no whitespace. Caller is responsible for entries
/// already being sorted by `scope_path` — `snapshotHeads` guarantees this.
pub fn writeSnapshot(entries: []const SnapshotEntry, writer: *std.Io.Writer) !void {
    try writer.writeAll("{\"entries\":[");
    for (entries, 0..) |e, i| {
        if (i > 0) try writer.writeByte(',');
        try writer.writeAll("{\"branch\":\"");
        try writer.writeAll(e.branch);
        try writer.writeAll("\",\"head_hash\":");
        if (e.head_hash) |h| {
            try writer.writeByte('"');
            try writer.writeAll(h[0..]);
            try writer.writeByte('"');
        } else {
            try writer.writeAll("null");
        }
        try writer.print(",\"length\":{d},\"scope_path\":\"", .{e.length});
        try writer.writeAll(e.scope_path);
        try writer.writeAll("\"}");
    }
    try writer.writeAll("]}");
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "Tick.init generates a 26-char Crockford-base32 ULID" {
    const t = Tick.init();
    // Crockford alphabet: 0-9, A-Z minus I, L, O, U.
    for (t.id) |c| {
        const ok = (c >= '0' and c <= '9') or
            (c >= 'A' and c <= 'Z' and c != 'I' and c != 'L' and c != 'O' and c != 'U');
        try std.testing.expect(ok);
    }
}

test "Tick.path composes pre/post/events/rejected paths" {
    const t = Tick.init();
    var buf: [256]u8 = undefined;

    const pre = try t.path(&buf, "./kb", .pre);
    try std.testing.expect(std.mem.endsWith(u8, pre, ".pre.json"));
    try std.testing.expect(std.mem.startsWith(u8, pre, "./kb/.ticks/"));
    try std.testing.expect(std.mem.indexOf(u8, pre, t.id[0..]) != null);

    const post = try t.path(&buf, "./kb", .post);
    try std.testing.expect(std.mem.endsWith(u8, post, ".post.json"));

    const events = try t.path(&buf, "./kb", .events);
    try std.testing.expect(std.mem.endsWith(u8, events, ".events.jsonl"));

    const rejected = try t.path(&buf, "./kb", .rejected);
    try std.testing.expect(std.mem.endsWith(u8, rejected, ".rejected.json"));
}

test "Tick.path threads an absolute kb_root through" {
    const t = Tick.init();
    var buf: [256]u8 = undefined;
    const p = try t.path(&buf, "/var/lib/praescientia/kb", .pre);
    try std.testing.expect(std.mem.startsWith(u8, p, "/var/lib/praescientia/kb/.ticks/"));
}

test "Tick.init produces distinct ids across rapid calls" {
    const a = Tick.init();
    const b = Tick.init();
    // CSPRNG randomness suffix makes collision practically impossible even
    // within the same millisecond.
    try std.testing.expect(!std.mem.eql(u8, &a.id, &b.id));
}

test "snapshotHeads returns one entry per chain in alphabetical scope_path order" {
    const init_mod = @import("init.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try init_mod.initTree(io, tmp.dir, true); // creates SAMPLE market + sample thesis

    const entries = try snapshotHeads(std.testing.allocator, io, tmp.dir);
    defer freeSnapshot(std.testing.allocator, entries);

    // initTree(with_sample=true) materializes:
    //   markets/SAMPLE/reality, markets/SAMPLE/commentary,
    //   theses/sample/reality, theses/sample/prediction, theses/sample/commentary
    // No commentary/global yet (created on first write).
    try std.testing.expectEqual(@as(usize, 5), entries.len);

    // Alphabetical scope_path ordering.
    for (entries[1..], 1..) |e, i| {
        try std.testing.expect(std.mem.lessThan(u8, entries[i - 1].scope_path, e.scope_path));
    }

    // Every entry should name the "main" branch.
    for (entries) |e| try std.testing.expectEqualStrings("main", e.branch);
}

test "snapshotHeads reflects chain growth on subsequent calls" {
    const init_mod = @import("init.zig");
    const predict_mod = @import("predict.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try init_mod.initTree(io, tmp.dir, true);

    const before = try snapshotHeads(std.testing.allocator, io, tmp.dir);
    defer freeSnapshot(std.testing.allocator, before);

    try predict_mod.writePrediction(std.testing.allocator, io, tmp.dir, "sample", 5000, "test");

    const after = try snapshotHeads(std.testing.allocator, io, tmp.dir);
    defer freeSnapshot(std.testing.allocator, after);

    // Find the prediction chain entries in each snapshot.
    var before_pred: ?SnapshotEntry = null;
    var after_pred: ?SnapshotEntry = null;
    for (before) |e| {
        if (std.mem.eql(u8, e.scope_path, "theses/sample/prediction")) before_pred = e;
    }
    for (after) |e| {
        if (std.mem.eql(u8, e.scope_path, "theses/sample/prediction")) after_pred = e;
    }

    try std.testing.expectEqual(@as(usize, 0), before_pred.?.length);
    try std.testing.expectEqual(@as(usize, 1), after_pred.?.length);
    try std.testing.expect(before_pred.?.head_hash == null);
    try std.testing.expect(after_pred.?.head_hash != null);
}

test "snapshotHeads handles an empty kb_root gracefully" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    // No markets/, no theses/, no commentary/global — bare directory.
    const entries = try snapshotHeads(std.testing.allocator, io, tmp.dir);
    defer freeSnapshot(std.testing.allocator, entries);
    try std.testing.expectEqual(@as(usize, 0), entries.len);
}

// --- validateOrderIntent tests ---

fn testThesis() !manifest_mod.ThesisManifest {
    const json =
        \\{"kind":"thesis","id":"t","description":"x",
        \\"market_set":["KX-A","KX-B"],"rollup_fn":"weighted_avg_v1",
        \\"weights":{"KX-A":7000,"KX-B":3000},
        \\"trigger":{"confidence_delta_bp":500}}
    ;
    return manifest_mod.parseThesis(std.testing.allocator, json);
}

test "validateOrderIntent accepts a well-formed buy" {
    var t = try testThesis();
    defer t.deinit();
    try validateOrderIntent(
        .{ .ticker = "KX-A", .side = .yes, .action = .buy, .size = 5, .limit_cents = 30 },
        &t,
        .{ .bankroll_cap_cents = 10_000 },
    );
}

test "validateOrderIntent rejects size == 0" {
    var t = try testThesis();
    defer t.deinit();
    try std.testing.expectError(ValidationError.SizeNonPositive, validateOrderIntent(
        .{ .ticker = "KX-A", .side = .yes, .action = .buy, .size = 0, .limit_cents = 30 },
        &t,
        .{ .bankroll_cap_cents = 10_000 },
    ));
}

test "validateOrderIntent rejects size over per-market cap" {
    var t = try testThesis();
    defer t.deinit();
    try std.testing.expectError(ValidationError.SizeOverPerMarketCap, validateOrderIntent(
        .{ .ticker = "KX-A", .side = .yes, .action = .buy, .size = 200, .limit_cents = 30 },
        &t,
        .{ .per_market_cap = 100, .bankroll_cap_cents = 100_000 },
    ));
}

test "validateOrderIntent rejects limit below or above Kalshi range" {
    var t = try testThesis();
    defer t.deinit();
    try std.testing.expectError(ValidationError.LimitOutOfRange, validateOrderIntent(
        .{ .ticker = "KX-A", .side = .yes, .action = .buy, .size = 5, .limit_cents = 0 },
        &t,
        .{ .bankroll_cap_cents = 10_000 },
    ));
    try std.testing.expectError(ValidationError.LimitOutOfRange, validateOrderIntent(
        .{ .ticker = "KX-A", .side = .yes, .action = .buy, .size = 5, .limit_cents = 100 },
        &t,
        .{ .bankroll_cap_cents = 10_000 },
    ));
}

test "validateOrderIntent rejects tickers not in manifest market_set" {
    var t = try testThesis();
    defer t.deinit();
    try std.testing.expectError(ValidationError.TickerNotInManifest, validateOrderIntent(
        .{ .ticker = "KX-NOT-LISTED", .side = .yes, .action = .buy, .size = 5, .limit_cents = 30 },
        &t,
        .{ .bankroll_cap_cents = 10_000 },
    ));
}

test "validateOrderIntent rejects buys that breach bankroll cap" {
    var t = try testThesis();
    defer t.deinit();
    // 50 contracts × 30¢ = 1500¢, cap is 1000¢.
    try std.testing.expectError(ValidationError.BankrollCapExceeded, validateOrderIntent(
        .{ .ticker = "KX-A", .side = .yes, .action = .buy, .size = 50, .limit_cents = 30 },
        &t,
        .{ .bankroll_cap_cents = 1000 },
    ));
}

test "validateOrderIntent bankroll cap counts cumulative used cents" {
    var t = try testThesis();
    defer t.deinit();
    // Cap 1000¢; 800 already used; this order needs 5 × 50 = 250¢ → breach.
    try std.testing.expectError(ValidationError.BankrollCapExceeded, validateOrderIntent(
        .{ .ticker = "KX-A", .side = .yes, .action = .buy, .size = 5, .limit_cents = 50 },
        &t,
        .{ .bankroll_cap_cents = 1000, .bankroll_used_cents = 800 },
    ));
}

test "validateOrderIntent skips bankroll check for cancels and sells" {
    var t = try testThesis();
    defer t.deinit();
    // A cancel against a fully-saturated bankroll still passes — we're freeing capital.
    try validateOrderIntent(
        .{ .ticker = "KX-A", .side = .yes, .action = .cancel, .size = 5, .limit_cents = 50 },
        &t,
        .{ .bankroll_cap_cents = 100, .bankroll_used_cents = 100 },
    );
    try validateOrderIntent(
        .{ .ticker = "KX-A", .side = .yes, .action = .sell, .size = 5, .limit_cents = 50 },
        &t,
        .{ .bankroll_cap_cents = 100, .bankroll_used_cents = 100 },
    );
}

// --- clientOrderId tests ---

test "clientOrderId composes {tick_id}-{8-hex} for a standard order" {
    var buf: [client_order_id_max_bytes]u8 = undefined;
    const id = try clientOrderId(
        &buf,
        "01ABCDEFGHJKMNPQRSTVWXYZ12",
        "sas-okc-spread-ladder",
        "KXNBASPREAD-26MAY20SASOKC-SAS13",
        .yes,
        .buy,
    );
    // 26 (tick_id) + 1 ("-") + 8 (hex) = 35.
    try std.testing.expectEqual(@as(usize, 35), id.len);
    try std.testing.expect(std.mem.startsWith(u8, id, "01ABCDEFGHJKMNPQRSTVWXYZ12-"));
    // Hex portion is lowercase 0-9a-f.
    for (id[27..]) |c| {
        const ok = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f');
        try std.testing.expect(ok);
    }
}

test "clientOrderId is deterministic for identical inputs" {
    var a: [client_order_id_max_bytes]u8 = undefined;
    var b: [client_order_id_max_bytes]u8 = undefined;
    const id_a = try clientOrderId(&a, "TID", "thesis", "ticker", .yes, .buy);
    const id_b = try clientOrderId(&b, "TID", "thesis", "ticker", .yes, .buy);
    try std.testing.expectEqualStrings(id_a, id_b);
}

test "clientOrderId discriminates side and action" {
    var a: [client_order_id_max_bytes]u8 = undefined;
    var b: [client_order_id_max_bytes]u8 = undefined;
    var c: [client_order_id_max_bytes]u8 = undefined;
    const yes_buy = try clientOrderId(&a, "TID", "t", "k", .yes, .buy);
    const no_buy = try clientOrderId(&b, "TID", "t", "k", .no, .buy);
    const yes_sell = try clientOrderId(&c, "TID", "t", "k", .yes, .sell);
    try std.testing.expect(!std.mem.eql(u8, yes_buy, no_buy));
    try std.testing.expect(!std.mem.eql(u8, yes_buy, yes_sell));
    try std.testing.expect(!std.mem.eql(u8, no_buy, yes_sell));
}

test "clientOrderId rejects empty components" {
    var buf: [client_order_id_max_bytes]u8 = undefined;
    try std.testing.expectError(ClientOrderIdError.EmptyComponent, clientOrderId(
        &buf,
        "",
        "thesis",
        "ticker",
        .yes,
        .buy,
    ));
    try std.testing.expectError(ClientOrderIdError.EmptyComponent, clientOrderId(
        &buf,
        "TID",
        "",
        "ticker",
        .yes,
        .buy,
    ));
    try std.testing.expectError(ClientOrderIdError.EmptyComponent, clientOrderId(
        &buf,
        "TID",
        "thesis",
        "",
        .yes,
        .buy,
    ));
}

test "clientOrderId errors when output buffer is too small" {
    var tiny: [10]u8 = undefined;
    try std.testing.expectError(ClientOrderIdError.BufferTooSmall, clientOrderId(
        &tiny,
        "01ABCDEFGHJKMNPQRSTVWXYZ12",
        "t",
        "k",
        .yes,
        .buy,
    ));
}

// --- clampOrderSize tests ---

test "clampOrderSize passes through orders that fit every cap" {
    const intent: OrderIntent = .{
        .ticker = "K",
        .side = .yes,
        .action = .buy,
        .size = 5,
        .limit_cents = 30,
    };
    const r = clampOrderSize(intent, .{
        .per_market_cap = 100,
        .bankroll_remaining_cents = 10_000,
        .balance_cents = 10_000,
    });
    try std.testing.expectEqual(@as(u32, 5), r.size);
    try std.testing.expect(r.reason == null);
}

test "clampOrderSize clamps to per_market_cap when nothing tighter binds" {
    const intent: OrderIntent = .{
        .ticker = "K",
        .side = .yes,
        .action = .buy,
        .size = 200,
        .limit_cents = 1,
    };
    const r = clampOrderSize(intent, .{
        .per_market_cap = 100,
        .bankroll_remaining_cents = 1_000_000,
        .balance_cents = 1_000_000,
    });
    try std.testing.expectEqual(@as(u32, 100), r.size);
    try std.testing.expectEqual(@as(?ClampReason, .PerMarketCap), r.reason);
}

test "clampOrderSize clamps to bankroll when bankroll is the binding cap" {
    const intent: OrderIntent = .{
        .ticker = "K",
        .side = .yes,
        .action = .buy,
        .size = 50,
        .limit_cents = 30,
    };
    // Bankroll allows 300/30 = 10 contracts. Balance and per-market are wide.
    const r = clampOrderSize(intent, .{
        .per_market_cap = 100,
        .bankroll_remaining_cents = 300,
        .balance_cents = 1_000_000,
    });
    try std.testing.expectEqual(@as(u32, 10), r.size);
    try std.testing.expectEqual(@as(?ClampReason, .BankrollCap), r.reason);
}

test "clampOrderSize clamps to balance when balance is the tightest cap" {
    const intent: OrderIntent = .{
        .ticker = "K",
        .side = .yes,
        .action = .buy,
        .size = 50,
        .limit_cents = 30,
    };
    // Balance allows 150/30 = 5 contracts. Bankroll/per-market are looser.
    const r = clampOrderSize(intent, .{
        .per_market_cap = 100,
        .bankroll_remaining_cents = 1_000_000,
        .balance_cents = 150,
    });
    try std.testing.expectEqual(@as(u32, 5), r.size);
    try std.testing.expectEqual(@as(?ClampReason, .InsufficientBalance), r.reason);
}

test "clampOrderSize sets size to 0 when bankroll cannot afford one contract" {
    const intent: OrderIntent = .{
        .ticker = "K",
        .side = .yes,
        .action = .buy,
        .size = 5,
        .limit_cents = 50,
    };
    const r = clampOrderSize(intent, .{
        .per_market_cap = 100,
        .bankroll_remaining_cents = 25, // < 50¢ per contract
        .balance_cents = 1_000_000,
    });
    try std.testing.expectEqual(@as(u32, 0), r.size);
    try std.testing.expectEqual(@as(?ClampReason, .BankrollCap), r.reason);
}

test "clampOrderSize leaves non-buy actions untouched" {
    const intent: OrderIntent = .{
        .ticker = "K",
        .side = .yes,
        .action = .cancel,
        .size = 100,
        .limit_cents = 99,
    };
    const r = clampOrderSize(intent, .{
        .per_market_cap = 1,
        .bankroll_remaining_cents = 0,
        .balance_cents = 0,
    });
    try std.testing.expectEqual(@as(u32, 100), r.size);
    try std.testing.expect(r.reason == null);
}

test "writeSnapshot emits canonical JSON with alphabetical keys" {
    const init_mod = @import("init.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try init_mod.initTree(io, tmp.dir, true);

    const entries = try snapshotHeads(std.testing.allocator, io, tmp.dir);
    defer freeSnapshot(std.testing.allocator, entries);

    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try writeSnapshot(entries, &aw.writer);

    const out = aw.written();
    // Spot-check the canonical shape.
    try std.testing.expect(std.mem.startsWith(u8, out, "{\"entries\":["));
    try std.testing.expect(std.mem.endsWith(u8, out, "]}"));
    // Keys alphabetical: branch < head_hash < length < scope_path.
    try std.testing.expect(std.mem.indexOf(u8, out, "\"branch\":\"main\",\"head_hash\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, ",\"length\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, ",\"scope_path\":\"markets/SAMPLE/commentary\"") != null);
    // Empty chains serialize head_hash as JSON null.
    try std.testing.expect(std.mem.indexOf(u8, out, "\"head_hash\":null") != null);
}

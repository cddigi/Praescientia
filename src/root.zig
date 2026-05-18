//! Praescientia — public library surface.
//!
//! Submodules are added stage-by-stage as the Julia → Zig port progresses.

pub const kalshi = struct {
    pub const auth = @import("kalshi/auth.zig");
    pub const client = @import("kalshi/client.zig");
    pub const exchange = @import("kalshi/exchange.zig");
    pub const markets = @import("kalshi/markets.zig");
    pub const events = @import("kalshi/events.zig");
    pub const portfolio = @import("kalshi/portfolio.zig");
    pub const orders = @import("kalshi/orders.zig");
    pub const historical = @import("kalshi/historical.zig");
    pub const search = @import("kalshi/search.zig");
    pub const account = @import("kalshi/account.zig");
    pub const communications = @import("kalshi/communications.zig");
    pub const order_groups = @import("kalshi/order_groups.zig");
    pub const live_data = @import("kalshi/live_data.zig");
};

pub const kb = struct {
    pub const chain = @import("kb/chain.zig");
    pub const branches = @import("kb/branches.zig");
    pub const manifest = @import("kb/manifest.zig");
    pub const ingest = @import("kb/ingest.zig");
    pub const rollup = @import("kb/rollup.zig");
    pub const divergence = @import("kb/divergence.zig");
};

pub const canonical_json = @import("canonical_json.zig");
pub const state_chain = @import("state_chain.zig");
pub const txlog = @import("txlog.zig");

test {
    _ = kalshi.auth;
    _ = kalshi.client;
    _ = kalshi.exchange;
    _ = kalshi.markets;
    _ = kalshi.events;
    _ = kalshi.portfolio;
    _ = kalshi.orders;
    _ = kalshi.historical;
    _ = kalshi.search;
    _ = kalshi.account;
    _ = kalshi.communications;
    _ = kalshi.order_groups;
    _ = kalshi.live_data;
    _ = kb.chain;
    _ = kb.branches;
    _ = kb.manifest;
    _ = kb.ingest;
    _ = kb.rollup;
    _ = kb.divergence;
    _ = canonical_json;
    _ = state_chain;
    _ = txlog;
}

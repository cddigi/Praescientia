//! Praescientia — public library surface.
//!
//! Submodules are added stage-by-stage as the Julia → Zig port progresses.

pub const kalshi = struct {
    pub const auth = @import("kalshi/auth.zig");
    pub const client = @import("kalshi/client.zig");
    pub const exchange = @import("kalshi/exchange.zig");
};

pub const canonical_json = @import("canonical_json.zig");
pub const state_chain = @import("state_chain.zig");
pub const txlog = @import("txlog.zig");

test {
    _ = kalshi.auth;
    _ = kalshi.client;
    _ = kalshi.exchange;
    _ = canonical_json;
    _ = state_chain;
    _ = txlog;
}

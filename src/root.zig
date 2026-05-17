//! Praescientia — public library surface.
//!
//! Submodules are added stage-by-stage as the Julia → Zig port progresses.
//! Stage 1 exposes only `kalshi.auth` for RSA-PSS signing risk reduction.

pub const kalshi = struct {
    pub const auth = @import("kalshi/auth.zig");
};

test {
    _ = kalshi.auth;
}

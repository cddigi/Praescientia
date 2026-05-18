//! Knowledge-base chain — wraps txlog.TxLog with branch metadata and flock-based
//! single-writer semantics. Filled in by subsequent tasks.

const std = @import("std");

test "kb.chain module compiles" {
    try std.testing.expect(true);
}

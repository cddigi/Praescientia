//! praescientia-poll-markets — iterate every market under `--kb-root` and
//! refresh its reality chain from the Kalshi API; then recompute every thesis
//! aggregate. One-shot per invocation; the outer scheduling loop (cron, tmux,
//! `while sleep`) is the operator's problem.
//!
//! Subcommands:
//!   run                                                   Poll once. (default)

const std = @import("std");
const common = @import("common");

pub fn main(init: std.process.Init) !u8 {
    return common.runMain(init, "praescientia-poll-markets", &.{
        .{ .name = "run", .description = "Poll every market under --kb-root and recompute theses", .run = cmdRun },
    });
}

fn cmdRun(ctx: *common.Context) !u8 {
    try ctx.stdout.print("stub: poll-markets\n", .{});
    return 0;
}

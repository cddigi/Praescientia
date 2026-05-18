//! praescientia-kb — inspect, fork, and analyze knowledge-base chains.
//!
//! Subcommands:
//!   inspect    <chain-dir>                              Print active branch head + last 3 entries.
//!   branches   <chain-dir>                              List branches with their fork-point hashes.
//!   fork       <chain-dir> <parent> <fork-hash> <new>   Create a new branch at fork-hash.
//!   divergence <prediction-dir> <reality-dir>           Compute temporal divergence; --threshold-bp=N (default 1000).
//!
//! `chain-dir` is a directory containing `<branch>.jsonl` files and a
//! `branches.json` index. The kb library does not assume the directory's
//! purpose (market reality, thesis reality, prediction chain — all use the
//! same on-disk shape).

const std = @import("std");
const common = @import("common");
const praescientia = @import("praescientia");

const kb = praescientia.kb;
const chain_mod = kb.chain;
const branches_mod = kb.branches;
const divergence_mod = kb.divergence;
const init_mod = kb.init;
const predict_mod = kb.predict;
const Hash = praescientia.state_chain.Hash;

pub fn main(init: std.process.Init) !u8 {
    return common.runMain(init, "praescientia-kb", &.{
        .{ .name = "inspect", .description = "Show the active branch head and the last 3 entries", .run = cmdInspect },
        .{ .name = "branches", .description = "List all branches in a chain directory", .run = cmdBranches },
        .{ .name = "fork", .description = "Fork a branch at a given hash into a new branch", .run = cmdFork },
        .{ .name = "divergence", .description = "Temporal divergence between a prediction and reality chain", .run = cmdDivergence },
        .{ .name = "init", .description = "Bootstrap a fresh kb_root directory tree (--with-sample for skeleton data)", .run = cmdInit },
        .{ .name = "predict", .description = "Append a thesis prediction (--confidence-bp=N, optional --rationale=)", .run = cmdPredict },
        .{ .name = "add-market", .description = "Register a new market (--price-delta-cents=N, default 1)", .run = cmdAddMarket },
    });
}

fn cmdAddMarket(ctx: *common.Context) !u8 {
    const ticker = ctx.positional(0) orelse {
        try ctx.stderr.print("usage: praescientia-kb add-market <ticker> [--price-delta-cents=N]\n", .{});
        return 2;
    };
    const pd_str = ctx.flagValue("--price-delta-cents") orelse "1";
    const price_delta = std.fmt.parseInt(u32, pd_str, 10) catch {
        try ctx.stderr.print("--price-delta-cents must be an integer\n", .{});
        return 2;
    };

    const kb_root_path = ctx.flagValue("--kb-root") orelse "./kb";
    var kb_root = std.Io.Dir.cwd().openDir(ctx.io, kb_root_path, .{ .iterate = false }) catch |err| {
        try ctx.stderr.print("open {s}: {t}\n", .{ kb_root_path, err });
        return 1;
    };
    defer kb_root.close(ctx.io);

    init_mod.addMarket(ctx.io, kb_root, ticker, price_delta) catch |err| {
        try ctx.stderr.print("add-market failed: {t}\n", .{err});
        return 1;
    };
    try ctx.stdout.print("created markets/{s} (price_delta_cents={d})\n", .{ ticker, price_delta });
    return 0;
}

fn cmdPredict(ctx: *common.Context) !u8 {
    const thesis_id = ctx.positional(0) orelse {
        try ctx.stderr.print("usage: praescientia-kb predict <thesis-id> --confidence-bp=N [--rationale=\"...\"]\n", .{});
        return 2;
    };
    const conf_str = ctx.flagValue("--confidence-bp") orelse {
        try ctx.stderr.print("--confidence-bp is required\n", .{});
        return 2;
    };
    const confidence_bp = std.fmt.parseInt(u32, conf_str, 10) catch {
        try ctx.stderr.print("--confidence-bp must be an integer\n", .{});
        return 2;
    };
    if (confidence_bp == 0 or confidence_bp > 10000) {
        try ctx.stderr.print("--confidence-bp must be in [1, 10000]\n", .{});
        return 2;
    }
    const rationale = ctx.flagValue("--rationale") orelse "";

    const kb_root_path = ctx.flagValue("--kb-root") orelse "./kb";
    var kb_root = std.Io.Dir.cwd().openDir(ctx.io, kb_root_path, .{ .iterate = false }) catch |err| {
        try ctx.stderr.print("open {s}: {t}\n", .{ kb_root_path, err });
        return 1;
    };
    defer kb_root.close(ctx.io);

    predict_mod.writePrediction(ctx.gpa, ctx.io, kb_root, thesis_id, confidence_bp, rationale) catch |err| {
        try ctx.stderr.print("predict failed: {t}\n", .{err});
        return 1;
    };

    try ctx.stdout.print("wrote prediction for thesis '{s}' at confidence={d} bp\n", .{ thesis_id, confidence_bp });
    return 0;
}

fn cmdInit(ctx: *common.Context) !u8 {
    const root_path = ctx.positional(0) orelse {
        try ctx.stderr.print("usage: praescientia-kb init <kb_root> [--with-sample]\n", .{});
        return 2;
    };
    var with_sample = false;
    for (ctx.args[1..]) |a| {
        if (std.mem.eql(u8, a, "--with-sample")) with_sample = true;
    }

    std.Io.Dir.cwd().createDirPath(ctx.io, root_path) catch |err| {
        try ctx.stderr.print("create {s}: {t}\n", .{ root_path, err });
        return 1;
    };
    var root = std.Io.Dir.cwd().openDir(ctx.io, root_path, .{ .iterate = false }) catch |err| {
        try ctx.stderr.print("open {s}: {t}\n", .{ root_path, err });
        return 1;
    };
    defer root.close(ctx.io);

    init_mod.initTree(ctx.io, root, with_sample) catch |err| {
        try ctx.stderr.print("init failed: {t}\n", .{err});
        return 1;
    };
    try ctx.stdout.print(
        "initialized kb_root at {s}{s}\n",
        .{ root_path, if (with_sample) " (with sample)" else "" },
    );
    return 0;
}

fn cmdInspect(ctx: *common.Context) !u8 {
    const dir_path = ctx.positional(0) orelse {
        try ctx.stderr.print("usage: praescientia-kb inspect <chain-dir>\n", .{});
        return 2;
    };

    var dir = std.Io.Dir.cwd().openDir(ctx.io, dir_path, .{ .iterate = false }) catch |err| {
        try ctx.stderr.print("open {s}: {t}\n", .{ dir_path, err });
        return 1;
    };
    defer dir.close(ctx.io);

    const meta_buf = dir.readFileAlloc(ctx.io, "branches.json", ctx.arena, .unlimited) catch |err| {
        try ctx.stderr.print("read branches.json: {t}\n", .{err});
        return 1;
    };
    var bf = try branches_mod.parseSlice(ctx.arena, meta_buf);
    defer bf.deinit();

    var chain = chain_mod.openRead(ctx.arena, ctx.io, dir, bf.active) catch |err| {
        try ctx.stderr.print("open chain '{s}': {t}\n", .{ bf.active, err });
        return 1;
    };
    defer chain.deinit();

    try ctx.stdout.print("chain:          {s}\n", .{dir_path});
    try ctx.stdout.print("active_branch:  {s}\n", .{bf.active});
    try ctx.stdout.print("length:         {d}\n", .{chain.len()});
    if (chain.head()) |h| {
        var hex: [64]u8 = undefined;
        _ = std.fmt.bufPrint(&hex, "{x}", .{h}) catch unreachable;
        try ctx.stdout.print("head:           {s}\n", .{hex});
    } else {
        try ctx.stdout.print("head:           (empty)\n", .{});
    }
    const tail = chain.tail(3);
    if (tail.len > 0) {
        try ctx.stdout.print("\nlast {d}:\n", .{tail.len});
        for (tail) |tx| {
            var hash_hex: [64]u8 = undefined;
            _ = std.fmt.bufPrint(&hash_hex, "{x}", .{tx.hash}) catch unreachable;
            try ctx.stdout.print("  {s}  {s}\n", .{ hash_hex[0..12], tx.payload });
        }
    }
    return 0;
}

fn cmdBranches(ctx: *common.Context) !u8 {
    const dir_path = ctx.positional(0) orelse {
        try ctx.stderr.print("usage: praescientia-kb branches <chain-dir>\n", .{});
        return 2;
    };

    var dir = std.Io.Dir.cwd().openDir(ctx.io, dir_path, .{ .iterate = false }) catch |err| {
        try ctx.stderr.print("open {s}: {t}\n", .{ dir_path, err });
        return 1;
    };
    defer dir.close(ctx.io);

    const meta_buf = try dir.readFileAlloc(ctx.io, "branches.json", ctx.arena, .unlimited);
    var bf = try branches_mod.parseSlice(ctx.arena, meta_buf);
    defer bf.deinit();

    try ctx.stdout.print("active: {s}\n\n", .{bf.active});
    for (bf.branches) |b| {
        var hex: [64]u8 = undefined;
        _ = std.fmt.bufPrint(&hex, "{x}", .{b.created_at_hash}) catch unreachable;
        try ctx.stdout.print(
            "  {s:<24} created_at={s} parent={s}\n",
            .{ b.name, hex[0..12], if (b.parent_branch.len > 0) b.parent_branch else "-" },
        );
    }
    return 0;
}

fn cmdFork(ctx: *common.Context) !u8 {
    const dir_path = ctx.positional(0) orelse return missingFork(ctx);
    const parent = ctx.positional(1) orelse return missingFork(ctx);
    const fork_hex = ctx.positional(2) orelse return missingFork(ctx);
    const new_name = ctx.positional(3) orelse return missingFork(ctx);

    if (fork_hex.len != 64) {
        try ctx.stderr.print("fork-hash must be 64 hex chars (got {d})\n", .{fork_hex.len});
        return 2;
    }
    var fork_hash: Hash = undefined;
    decodeHex(fork_hex, &fork_hash) catch {
        try ctx.stderr.print("invalid hex in fork-hash\n", .{});
        return 2;
    };

    var dir = try std.Io.Dir.cwd().openDir(ctx.io, dir_path, .{ .iterate = false });
    defer dir.close(ctx.io);

    branches_mod.fork(ctx.arena, ctx.io, dir, parent, fork_hash, new_name) catch |err| {
        try ctx.stderr.print("fork failed: {t}\n", .{err});
        return 1;
    };
    try ctx.stdout.print("forked '{s}' from '{s}' at {s}\n", .{ new_name, parent, fork_hex[0..12] });
    return 0;
}

fn missingFork(ctx: *common.Context) !u8 {
    try ctx.stderr.print("usage: praescientia-kb fork <chain-dir> <parent-branch> <fork-hash> <new-name>\n", .{});
    return 2;
}

fn cmdDivergence(ctx: *common.Context) !u8 {
    const pred_path = ctx.positional(0) orelse return missingDivergence(ctx);
    const real_path = ctx.positional(1) orelse return missingDivergence(ctx);

    var threshold_bp: u32 = 1000;
    if (ctx.flagValue("--threshold-bp")) |v| {
        threshold_bp = std.fmt.parseInt(u32, v, 10) catch {
            try ctx.stderr.print("--threshold-bp must be an integer\n", .{});
            return 2;
        };
    }

    var pred = try openActive(ctx, pred_path);
    defer pred.deinit();
    var real = try openActive(ctx, real_path);
    defer real.deinit();

    const d = try divergence_mod.temporalDivergence(ctx.arena, &pred, &real, threshold_bp);
    if (d.first_drift_idx) |idx| {
        try ctx.stdout.print(
            "drift_idx:        {d}\ndrift_amount_bp:  {d}\nthreshold_bp:     {d}\n",
            .{ idx, d.drift_amount_bp, d.threshold_bp },
        );
    } else {
        try ctx.stdout.print(
            "no divergence within threshold {d} bp ({d} predictions checked)\n",
            .{ d.threshold_bp, pred.len() },
        );
    }
    return 0;
}

fn missingDivergence(ctx: *common.Context) !u8 {
    try ctx.stderr.print("usage: praescientia-kb divergence <prediction-dir> <reality-dir> [--threshold-bp=N]\n", .{});
    return 2;
}

fn openActive(ctx: *common.Context, dir_path: []const u8) !chain_mod.Chain {
    var dir = try std.Io.Dir.cwd().openDir(ctx.io, dir_path, .{ .iterate = false });
    defer dir.close(ctx.io);

    const meta_buf = try dir.readFileAlloc(ctx.io, "branches.json", ctx.arena, .unlimited);
    var bf = try branches_mod.parseSlice(ctx.arena, meta_buf);
    defer bf.deinit();
    return try chain_mod.openRead(ctx.arena, ctx.io, dir, bf.active);
}

fn decodeHex(hex: []const u8, out: *Hash) !void {
    if (hex.len != 64) return error.WrongHexLength;
    for (out, 0..) |*byte, i| {
        const hi = try hexNibble(hex[i * 2]);
        const lo = try hexNibble(hex[i * 2 + 1]);
        byte.* = (hi << 4) | lo;
    }
}

fn hexNibble(c: u8) !u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => 10 + c - 'a',
        'A'...'F' => 10 + c - 'A',
        else => error.InvalidHex,
    };
}

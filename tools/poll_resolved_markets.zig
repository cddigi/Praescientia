//! praescientia-poll-resolved-markets — port of scripts/poll_resolved_markets.jl.
//!
//! The Julia script is a data harvester for *Polymarket* and CoinGecko (it
//! pre-dates Stage 3's Kalshi focus). Stage 4 ports the simple, dependency-free
//! `prices` subcommand to Zig; the deeper monthly backtest extraction
//! (Polymarket Gamma + date math + data/ writes) is intentionally left as Julia
//! through Stage 5 — it isn't on the Stage 3 Kalshi-client critical path and
//! porting it would more than double Stage 4's scope.
//!
//! Subcommands:
//!   prices                       Current BTC/ETH/SOL spot from CoinGecko
//!   month                        Defer to the Julia version (printed message)
//!   --all                        Defer to the Julia version

const std = @import("std");

const COINGECKO_PRICES_URL = "https://api.coingecko.com/api/v3/simple/price?ids=bitcoin,ethereum,solana&vs_currencies=usd";

const Prices = struct {
    bitcoin: Coin,
    ethereum: Coin,
    solana: Coin,
    const Coin = struct { usd: f64 };
};

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();

    var stderr_buf: [4096]u8 = undefined;
    var stderr_w = std.Io.File.stderr().writer(io, &stderr_buf);
    const stderr = &stderr_w.interface;
    defer stderr.flush() catch {};

    var stdout_buf: [4096]u8 = undefined;
    var stdout_w = std.Io.File.stdout().writer(io, &stdout_buf);
    const stdout = &stdout_w.interface;
    defer stdout.flush() catch {};

    const argv = try init.minimal.args.toSlice(arena);

    if (argv.len < 2 or std.mem.eql(u8, argv[1], "--help") or std.mem.eql(u8, argv[1], "-h")) {
        try printUsage(stderr);
        return if (argv.len < 2) 2 else 0;
    }

    const cmd = argv[1];
    if (std.mem.eql(u8, cmd, "prices")) return cmdPrices(gpa, io, stdout, stderr);
    if (std.mem.eql(u8, cmd, "month") or std.mem.eql(u8, cmd, "--all")) return cmdDeferred(stderr);

    try stderr.print("unknown subcommand: {s}\n\n", .{cmd});
    try printUsage(stderr);
    return 2;
}

fn printUsage(out: *std.Io.Writer) !void {
    try out.print(
        \\Usage: praescientia-poll-resolved-markets <command>
        \\
        \\Commands:
        \\  prices    Current BTC/ETH/SOL spot prices (CoinGecko)
        \\  month     Deferred — use `julia --project=. scripts/poll_resolved_markets.jl <month> <year>`
        \\  --all     Deferred — see Julia version
        \\
        \\Note: the Polymarket-resolved-markets harvester remains the
        \\canonical Julia tool through Stage 5; only the trivial CoinGecko
        \\price fetch is ported to Zig.
        \\
    , .{});
}

fn cmdPrices(gpa: std.mem.Allocator, io: std.Io, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !u8 {
    var http: std.http.Client = .{ .allocator = gpa, .io = io };
    defer http.deinit();

    var body: std.Io.Writer.Allocating = .init(gpa);
    defer body.deinit();

    const res = http.fetch(.{
        .location = .{ .url = COINGECKO_PRICES_URL },
        .response_writer = &body.writer,
    }) catch |e| {
        try stderr.print("CoinGecko fetch failed: {s}\n", .{@errorName(e)});
        return 1;
    };
    if (@intFromEnum(res.status) != 200) {
        try stderr.print("CoinGecko returned status {d}\n", .{@intFromEnum(res.status)});
        return 1;
    }

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const parsed = std.json.parseFromSliceLeaky(Prices, a, body.written(), .{ .ignore_unknown_fields = true }) catch |e| {
        try stderr.print("CoinGecko parse failed: {s}\n", .{@errorName(e)});
        return 1;
    };

    try stdout.print("BTC: ${d:.2}\nETH: ${d:.2}\nSOL: ${d:.2}\n", .{
        parsed.bitcoin.usd,
        parsed.ethereum.usd,
        parsed.solana.usd,
    });
    return 0;
}

fn cmdDeferred(stderr: *std.Io.Writer) !u8 {
    try stderr.print(
        \\This subcommand is not yet ported — the Polymarket-resolved-markets
        \\harvester remains in Julia through Stage 5. Run instead:
        \\
        \\  julia --project=. scripts/poll_resolved_markets.jl <month> <year>
        \\  julia --project=. scripts/poll_resolved_markets.jl --all
        \\
        \\
    , .{});
    return 2;
}

test "Prices parses CoinGecko shape" {
    const fixture =
        \\{"bitcoin":{"usd":67000.5},"ethereum":{"usd":3400.25},"solana":{"usd":150.0}}
    ;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const parsed = try std.json.parseFromSliceLeaky(Prices, arena.allocator(), fixture, .{ .ignore_unknown_fields = true });
    try std.testing.expectEqual(@as(f64, 67000.5), parsed.bitcoin.usd);
    try std.testing.expectEqual(@as(f64, 3400.25), parsed.ethereum.usd);
    try std.testing.expectEqual(@as(f64, 150.0), parsed.solana.usd);
}

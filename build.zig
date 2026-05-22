const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mbedtls = buildMbedtls(b, target, optimize);

    // Public library module. Re-exports state-chain, txlog, and kalshi.* over time.
    const praescientia = b.addModule("praescientia", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "mbedtls", .module = mbedtls.module },
        },
    });
    praescientia.linkLibrary(mbedtls.lib);

    const lib_tests = b.addTest(.{ .root_module = praescientia });
    const run_lib_tests = b.addRunArtifact(lib_tests);
    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_lib_tests.step);

    // Stage 1 risk-reduction binaries.
    addTool(b, target, optimize, praescientia, null, "praescientia-signtest", "tools/signtest.zig", "signtest", "Run the RSA-PSS sign harness");
    addTool(b, target, optimize, praescientia, null, "praescientia-verifytest", "tools/verifytest.zig", "verifytest", "Run the RSA-PSS verify harness");

    // Stage 2 microbenchmark.
    addTool(b, target, optimize, praescientia, null, "praescientia-bench-state-chain", "tools/bench_state_chain.zig", "bench", "Benchmark state_chain.Chain.divergesAt on 100k entries");

    // Stage 3 demo API smoke check.
    addTool(b, target, optimize, praescientia, null, "praescientia-test-conn", "tools/test_conn.zig", "test-conn", "End-to-end smoke check against the Kalshi demo (or live) API");

    // Stage 9 / Ollama routing — local-model dispatch worker. Inlined (rather
    // than going through addTool) because the binary needs the role-prompt
    // `.md` files registered as anonymous imports so `@embedFile` can pick
    // them up from outside the tool's package root.
    const ollama_agent_mod = b.createModule(.{
        .root_source_file = b.path("tools/ollama_agent.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "praescientia", .module = praescientia },
        },
    });
    addOllamaAgentRolePrompts(b, ollama_agent_mod, target, optimize);
    const ollama_agent_exe = b.addExecutable(.{ .name = "praescientia-ollama-agent", .root_module = ollama_agent_mod });
    b.installArtifact(ollama_agent_exe);
    const run_ollama_agent = b.addRunArtifact(ollama_agent_exe);
    if (b.args) |args| run_ollama_agent.addArgs(args);
    const run_ollama_agent_step = b.step("run-ollama-agent", "Stage 9 Ollama dispatch worker (stub — argparse/HTTP land in Tasks 2.4-2.5)");
    run_ollama_agent_step.dependOn(&run_ollama_agent.step);

    // Stage 4: shared tools/common.zig + one Zig CLI per Julia script.
    const tool_common = b.createModule(.{
        .root_source_file = b.path("tools/common.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "praescientia", .module = praescientia }},
    });

    const smoke_step = b.step("test-cli", "Smoke-check each Stage 4 CLI --help");

    const Stage4 = struct { name: []const u8, src: []const u8, step: []const u8 };
    const stage4_tools = [_]Stage4{
        .{ .name = "praescientia-exchange", .src = "tools/exchange.zig", .step = "run-exchange" },
        .{ .name = "praescientia-markets", .src = "tools/markets.zig", .step = "run-markets" },
        .{ .name = "praescientia-events", .src = "tools/events.zig", .step = "run-events" },
        .{ .name = "praescientia-historical", .src = "tools/historical.zig", .step = "run-historical" },
        .{ .name = "praescientia-portfolio", .src = "tools/portfolio.zig", .step = "run-portfolio" },
        .{ .name = "praescientia-orders", .src = "tools/orders.zig", .step = "run-orders" },
        .{ .name = "praescientia-account", .src = "tools/account.zig", .step = "run-account" },
        .{ .name = "praescientia-communications", .src = "tools/communications.zig", .step = "run-communications" },
        .{ .name = "praescientia-order-groups", .src = "tools/order_groups.zig", .step = "run-order-groups" },
        .{ .name = "praescientia-live-data", .src = "tools/live_data.zig", .step = "run-live-data" },
        .{ .name = "praescientia-search", .src = "tools/search.zig", .step = "run-search" },
        .{ .name = "praescientia-kb", .src = "tools/kb.zig", .step = "run-kb" },
        .{ .name = "praescientia-poll-markets", .src = "tools/poll_markets.zig", .step = "run-poll-markets" },
        .{ .name = "praescientia-ticks", .src = "tools/ticks.zig", .step = "run-ticks" },
        .{ .name = "praescientia-orchestrate-daemon", .src = "tools/orchestrate_daemon.zig", .step = "run-orchestrate-daemon" },
        .{ .name = "praescientia-screener", .src = "tools/screener.zig", .step = "run-screener" },
        .{ .name = "praescientia-game-state", .src = "tools/game_state.zig", .step = "run-game-state" },
    };
    for (stage4_tools) |t| {
        const exe = addToolReturn(b, target, optimize, praescientia, tool_common, t.name, t.src, t.step, "Stage 4 CLI");
        const help_run = b.addRunArtifact(exe);
        help_run.addArg("--help");
        help_run.expectExitCode(0);
        help_run.expectStdErrMatch("Usage:");
        smoke_step.dependOn(&help_run.step);
    }
    addTool(b, target, optimize, praescientia, null, "praescientia-poll-resolved-markets", "tools/poll_resolved_markets.zig", "run-poll", "praescientia-poll-resolved-markets CLI (CoinGecko prices only — Julia retains the Polymarket harvester)");

    // Stage 5: dashboard server.
    const server_mod = b.createModule(.{
        .root_source_file = b.path("server/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "praescientia", .module = praescientia }},
    });
    const server_exe = b.addExecutable(.{ .name = "praescientia-server", .root_module = server_mod });
    b.installArtifact(server_exe);
    const run_server = b.addRunArtifact(server_exe);
    if (b.args) |args| run_server.addArgs(args);
    const run_server_step = b.step("run-server", "Run the dashboard server");
    run_server_step.dependOn(&run_server.step);

    // Wire server tests into `zig build test`.
    const server_tests = b.addTest(.{ .root_module = server_mod });
    const run_server_tests = b.addRunArtifact(server_tests);
    test_step.dependOn(&run_server_tests.step);

    // tools/common.zig has its own inline tests; surface them through `zig build test`.
    const common_tests = b.addTest(.{ .root_module = tool_common });
    const run_common_tests = b.addRunArtifact(common_tests);
    test_step.dependOn(&run_common_tests.step);

    // tools/poll_markets.zig has inline tests (pollerForTest etc.) that need to
    // run through `zig build test`. Build a dedicated test target for the same
    // module shape addToolReturn used.
    const poll_markets_test_mod = b.createModule(.{
        .root_source_file = b.path("tools/poll_markets.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "praescientia", .module = praescientia },
            .{ .name = "common", .module = tool_common },
        },
    });
    const poll_markets_tests = b.addTest(.{ .root_module = poll_markets_test_mod });
    const run_poll_markets_tests = b.addRunArtifact(poll_markets_tests);
    test_step.dependOn(&run_poll_markets_tests.step);

    // tools/ticks.zig also carries inline tests — surface them through
    // `zig build test` the same way as poll_markets.
    const ticks_test_mod = b.createModule(.{
        .root_source_file = b.path("tools/ticks.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "praescientia", .module = praescientia },
            .{ .name = "common", .module = tool_common },
        },
    });
    const ticks_tests = b.addTest(.{ .root_module = ticks_test_mod });
    const run_ticks_tests = b.addRunArtifact(ticks_tests);
    test_step.dependOn(&run_ticks_tests.step);

    // tools/markets.zig has inline gate-predicate tests for the `candidates`
    // subcommand — wire them through `zig build test`.
    const markets_test_mod = b.createModule(.{
        .root_source_file = b.path("tools/markets.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "praescientia", .module = praescientia },
            .{ .name = "common", .module = tool_common },
        },
    });
    const markets_tests = b.addTest(.{ .root_module = markets_test_mod });
    const run_markets_tests = b.addRunArtifact(markets_tests);
    test_step.dependOn(&run_markets_tests.step);

    // tools/screener.zig has inline helper tests for the `validate` /
    // `apply` subcommands of the market-screener CLI.
    const screener_test_mod = b.createModule(.{
        .root_source_file = b.path("tools/screener.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "praescientia", .module = praescientia },
            .{ .name = "common", .module = tool_common },
        },
    });
    const screener_tests = b.addTest(.{ .root_module = screener_test_mod });
    const run_screener_tests = b.addRunArtifact(screener_tests);
    test_step.dependOn(&run_screener_tests.step);

    // tools/game_state.zig — inline helper tests for the classify CLI.
    const game_state_test_mod = b.createModule(.{
        .root_source_file = b.path("tools/game_state.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "praescientia", .module = praescientia },
            .{ .name = "common", .module = tool_common },
        },
    });
    const game_state_tests = b.addTest(.{ .root_module = game_state_test_mod });
    const run_game_state_tests = b.addRunArtifact(game_state_tests);
    test_step.dependOn(&run_game_state_tests.step);

    // tools/orchestrate_daemon.zig — inline tests for parseDuration,
    // backoffSeconds, etc. Pure helpers; the loop itself is subprocess-
    // heavy and covered by scripts/game_state_smoke.sh.
    const orchestrate_daemon_test_mod = b.createModule(.{
        .root_source_file = b.path("tools/orchestrate_daemon.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "praescientia", .module = praescientia },
            .{ .name = "common", .module = tool_common },
        },
    });
    const orchestrate_daemon_tests = b.addTest(.{ .root_module = orchestrate_daemon_test_mod });
    const run_orchestrate_daemon_tests = b.addRunArtifact(orchestrate_daemon_tests);
    test_step.dependOn(&run_orchestrate_daemon_tests.step);

    // tools/ollama_agent.zig — inline tests for extractJsonEnvelope (prose-strip
    // pipeline) and rolePrompt/parseRole dispatch. Mirrors the executable
    // module's anonymous imports so `@embedFile` resolves the role .md files.
    const ollama_agent_test_mod = b.createModule(.{
        .root_source_file = b.path("tools/ollama_agent.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "praescientia", .module = praescientia },
            .{ .name = "common", .module = tool_common },
        },
    });
    addOllamaAgentRolePrompts(b, ollama_agent_test_mod, target, optimize);
    const ollama_agent_tests = b.addTest(.{ .root_module = ollama_agent_test_mod });
    const run_ollama_agent_tests = b.addRunArtifact(ollama_agent_tests);
    test_step.dependOn(&run_ollama_agent_tests.step);

    test_step.dependOn(smoke_step);
}

fn addToolReturn(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    praescientia: *std.Build.Module,
    tool_common: *std.Build.Module,
    exe_name: []const u8,
    source: []const u8,
    step_name: []const u8,
    step_description: []const u8,
) *std.Build.Step.Compile {
    const mod = b.createModule(.{
        .root_source_file = b.path(source),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "praescientia", .module = praescientia },
            .{ .name = "common", .module = tool_common },
        },
    });
    const exe = b.addExecutable(.{ .name = exe_name, .root_module = mod });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    const step = b.step(step_name, step_description);
    step.dependOn(&run.step);
    return exe;
}

/// Register the three role-prompt `.md` files as anonymous imports on `mod`,
/// so the Stage 9 Ollama agent's `@embedFile("role_*")` calls resolve to the
/// canonical files under `.claude/agents/` (which live outside the tool's
/// package root and therefore can't be embedded via a relative path).
fn addOllamaAgentRolePrompts(
    b: *std.Build,
    mod: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const roles = [_]struct { name: []const u8, path: []const u8 }{
        .{ .name = "role_thesis_analyst", .path = ".claude/agents/praescientia-thesis-analyst.md" },
        .{ .name = "role_loss_reflector", .path = ".claude/agents/praescientia-loss-reflector.md" },
        .{ .name = "role_market_screener", .path = ".claude/agents/praescientia-market-screener.md" },
    };
    for (roles) |r| {
        mod.addAnonymousImport(r.name, .{
            .root_source_file = b.path(r.path),
            .target = target,
            .optimize = optimize,
        });
    }
}

fn addTool(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    praescientia: *std.Build.Module,
    tool_common: ?*std.Build.Module,
    exe_name: []const u8,
    source: []const u8,
    step_name: []const u8,
    step_description: []const u8,
) void {
    var imports_buf: [2]std.Build.Module.Import = .{
        .{ .name = "praescientia", .module = praescientia },
        .{ .name = "common", .module = praescientia }, // overwritten below if tool_common != null
    };
    var imports_count: usize = 1;
    if (tool_common) |c| {
        imports_buf[1] = .{ .name = "common", .module = c };
        imports_count = 2;
    }

    const mod = b.createModule(.{
        .root_source_file = b.path(source),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = imports_buf[0..imports_count],
    });
    const exe = b.addExecutable(.{ .name = exe_name, .root_module = mod });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    const step = b.step(step_name, step_description);
    step.dependOn(&run.step);
}

const Mbedtls = struct {
    module: *std.Build.Module,
    lib: *std.Build.Step.Compile,
};

/// Compile mbedTLS (default config) as a static library and translate its
/// public headers into an importable Zig module via b.addTranslateC.
fn buildMbedtls(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) Mbedtls {
    const include_dir = b.path("vendor/mbedtls/include");
    const library_dir = b.path("vendor/mbedtls/library");

    const translate = b.addTranslateC(.{
        .root_source_file = b.path("vendor/mbedtls_glue.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    translate.addIncludePath(include_dir);
    const module = translate.createModule();

    const lib_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    lib_module.addIncludePath(include_dir);
    lib_module.addIncludePath(library_dir);
    lib_module.addCSourceFiles(.{
        .root = library_dir,
        .files = &mbedtls_sources,
        .flags = &.{ "-std=c99", "-Wno-unused-function" },
    });

    const lib = b.addLibrary(.{
        .name = "mbedtls",
        .linkage = .static,
        .root_module = lib_module,
    });

    // Anything that imports the translated-C module also needs the static
    // library at link time.
    module.linkLibrary(lib);

    return .{ .module = module, .lib = lib };
}

/// Every .c file under vendor/mbedtls/library — kept exhaustive for Stage 1
/// to avoid debugging missing-symbol errors. Dead code is link-time stripped
/// in ReleaseSmall/ReleaseFast.
const mbedtls_sources = [_][]const u8{
    "aes.c",
    "aesce.c",
    "aesni.c",
    "aria.c",
    "asn1parse.c",
    "asn1write.c",
    "base64.c",
    "bignum_core.c",
    "bignum_mod_raw.c",
    "bignum_mod.c",
    "bignum.c",
    "block_cipher.c",
    "camellia.c",
    "ccm.c",
    "chacha20.c",
    "chachapoly.c",
    "cipher_wrap.c",
    "cipher.c",
    "cmac.c",
    "constant_time.c",
    "ctr_drbg.c",
    "debug.c",
    "des.c",
    "dhm.c",
    "ecdh.c",
    "ecdsa.c",
    "ecjpake.c",
    "ecp_curves_new.c",
    "ecp_curves.c",
    "ecp.c",
    "entropy_poll.c",
    "entropy.c",
    "error.c",
    "gcm.c",
    "hkdf.c",
    "hmac_drbg.c",
    "lmots.c",
    "lms.c",
    "md.c",
    "md5.c",
    "memory_buffer_alloc.c",
    "mps_reader.c",
    "mps_trace.c",
    "net_sockets.c",
    "nist_kw.c",
    "oid.c",
    "padlock.c",
    "pem.c",
    "pk_ecc.c",
    "pk_wrap.c",
    "pk.c",
    "pkcs12.c",
    "pkcs5.c",
    "pkcs7.c",
    "pkparse.c",
    "pkwrite.c",
    "platform_util.c",
    "platform.c",
    "poly1305.c",
    "psa_crypto_aead.c",
    "psa_crypto_cipher.c",
    "psa_crypto_client.c",
    "psa_crypto_driver_wrappers_no_static.c",
    "psa_crypto_ecp.c",
    "psa_crypto_ffdh.c",
    "psa_crypto_hash.c",
    "psa_crypto_mac.c",
    "psa_crypto_pake.c",
    "psa_crypto_random.c",
    "psa_crypto_rsa.c",
    "psa_crypto_se.c",
    "psa_crypto_slot_management.c",
    "psa_crypto_storage.c",
    "psa_crypto.c",
    "psa_its_file.c",
    "psa_util.c",
    "ripemd160.c",
    "rsa_alt_helpers.c",
    "rsa.c",
    "sha1.c",
    "sha256.c",
    "sha3.c",
    "sha512.c",
    "ssl_cache.c",
    "ssl_ciphersuites.c",
    "ssl_client.c",
    "ssl_cookie.c",
    "ssl_debug_helpers_generated.c",
    "ssl_msg.c",
    "ssl_ticket.c",
    "ssl_tls.c",
    "ssl_tls12_client.c",
    "ssl_tls12_server.c",
    "ssl_tls13_client.c",
    "ssl_tls13_generic.c",
    "ssl_tls13_keys.c",
    "ssl_tls13_server.c",
    "threading.c",
    "timing.c",
    "version_features.c",
    "version.c",
    "x509_create.c",
    "x509_crl.c",
    "x509_crt.c",
    "x509_csr.c",
    "x509.c",
    "x509write_crt.c",
    "x509write_csr.c",
    "x509write.c",
};

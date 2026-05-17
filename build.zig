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
    addTool(b, target, optimize, praescientia, "praescientia-signtest", "tools/signtest.zig", "signtest", "Run the RSA-PSS sign harness");
    addTool(b, target, optimize, praescientia, "praescientia-verifytest", "tools/verifytest.zig", "verifytest", "Run the RSA-PSS verify harness");

    // Stage 2 microbenchmark.
    addTool(b, target, optimize, praescientia, "praescientia-bench-state-chain", "tools/bench_state_chain.zig", "bench", "Benchmark state_chain.Chain.divergesAt on 100k entries");

    // Stage 3 demo API smoke check.
    addTool(b, target, optimize, praescientia, "praescientia-test-conn", "tools/test_conn.zig", "test-conn", "End-to-end smoke check against the Kalshi demo (or live) API");
}

fn addTool(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    praescientia: *std.Build.Module,
    exe_name: []const u8,
    source: []const u8,
    step_name: []const u8,
    step_description: []const u8,
) void {
    const mod = b.createModule(.{
        .root_source_file = b.path(source),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "praescientia", .module = praescientia },
        },
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

//! RSA-PSS signing for Kalshi API requests.
//!
//! Behavioral parity target: `src/KalshiAuth.jl::rsa_pss_sign`
//!   - RSA-SHA256, PSS padding
//!   - MGF1 hash: SHA-256
//!   - Salt length: digest length (32 bytes)
//!   - Output: base64 of raw signature
//!   - Message format: "{timestamp_ms}{HTTP_METHOD}{path_without_query_params}"

const std = @import("std");
const c = @import("mbedtls");

const Allocator = std.mem.Allocator;

pub const access_key_header = "KALSHI-ACCESS-KEY";
pub const access_timestamp_header = "KALSHI-ACCESS-TIMESTAMP";
pub const access_signature_header = "KALSHI-ACCESS-SIGNATURE";

pub const SignError = error{
    MethodTooLong,
    PemParseFailed,
    EntropySeedFailed,
    SignFailed,
    Base64EncodeFailed,
} || Allocator.Error;

pub const VerifyError = error{
    PemParseFailed,
    NotAnRsaKey,
    RsaConfigFailed,
    Base64DecodeFailed,
} || Allocator.Error;

/// Build the canonical signing message: `{timestamp_ms}{METHOD}{path}`.
/// `path` is the request path *without* query parameters.
/// Caller owns the returned slice.
pub fn signingMessage(
    allocator: Allocator,
    timestamp_ms: i64,
    method: []const u8,
    path: []const u8,
) ![]u8 {
    var upper_buf: [16]u8 = undefined;
    if (method.len > upper_buf.len) return error.MethodTooLong;
    const upper_method = std.ascii.upperString(upper_buf[0..method.len], method);
    return std.fmt.allocPrint(allocator, "{d}{s}{s}", .{ timestamp_ms, upper_method, path });
}

/// Sign a Kalshi request. Returns the base64-encoded signature.
pub fn signRequest(
    allocator: Allocator,
    private_key_pem: []const u8,
    timestamp_ms: i64,
    method: []const u8,
    path: []const u8,
) SignError![]u8 {
    const message = try signingMessage(allocator, timestamp_ms, method, path);
    defer allocator.free(message);

    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(message, &digest, .{});

    return signDigest(allocator, private_key_pem, &digest);
}

/// Sign a pre-computed SHA-256 digest with RSA-PSS. Returns base64 signature.
pub fn signDigest(
    allocator: Allocator,
    private_key_pem: []const u8,
    digest: *const [32]u8,
) SignError![]u8 {
    const pem_z = try allocator.allocSentinel(u8, private_key_pem.len, 0);
    defer allocator.free(pem_z);
    @memcpy(pem_z[0..private_key_pem.len], private_key_pem);

    var entropy: c.mbedtls_entropy_context = undefined;
    var ctr_drbg: c.mbedtls_ctr_drbg_context = undefined;
    var pk: c.mbedtls_pk_context = undefined;

    c.mbedtls_entropy_init(&entropy);
    defer c.mbedtls_entropy_free(&entropy);

    c.mbedtls_ctr_drbg_init(&ctr_drbg);
    defer c.mbedtls_ctr_drbg_free(&ctr_drbg);

    c.mbedtls_pk_init(&pk);
    defer c.mbedtls_pk_free(&pk);

    const personalization = "praescientia-kalshi-sign";
    if (c.mbedtls_ctr_drbg_seed(
        &ctr_drbg,
        c.mbedtls_entropy_func,
        &entropy,
        personalization.ptr,
        personalization.len,
    ) != 0) return error.EntropySeedFailed;

    // pk_parse_key needs keylen including the trailing NUL.
    if (c.mbedtls_pk_parse_key(
        &pk,
        pem_z.ptr,
        pem_z.len + 1,
        null,
        0,
        c.mbedtls_ctr_drbg_random,
        &ctr_drbg,
    ) != 0) return error.PemParseFailed;

    const sig_size = c.mbedtls_pk_get_len(&pk);
    const sig_buf = try allocator.alloc(u8, sig_size);
    defer allocator.free(sig_buf);

    var sig_len: usize = 0;
    if (c.mbedtls_pk_sign_ext(
        c.MBEDTLS_PK_RSASSA_PSS,
        &pk,
        c.MBEDTLS_MD_SHA256,
        digest,
        digest.len,
        sig_buf.ptr,
        sig_size,
        &sig_len,
        c.mbedtls_ctr_drbg_random,
        &ctr_drbg,
    ) != 0) return error.SignFailed;

    const b64_size = ((sig_len + 2) / 3) * 4 + 1;
    const b64_buf = try allocator.alloc(u8, b64_size);
    errdefer allocator.free(b64_buf);
    var b64_len: usize = 0;
    if (c.mbedtls_base64_encode(
        b64_buf.ptr,
        b64_buf.len,
        &b64_len,
        sig_buf.ptr,
        sig_len,
    ) != 0) return error.Base64EncodeFailed;

    return allocator.realloc(b64_buf, b64_len);
}

/// Verify an RSA-PSS base64 signature against a SHA-256 digest using a PEM public key.
/// Used by the round-trip test and cross-language verification.
pub fn verifyDigest(
    allocator: Allocator,
    public_key_pem: []const u8,
    digest: *const [32]u8,
    signature_b64: []const u8,
) VerifyError!bool {
    const pem_z = try allocator.allocSentinel(u8, public_key_pem.len, 0);
    defer allocator.free(pem_z);
    @memcpy(pem_z[0..public_key_pem.len], public_key_pem);

    var sig_len: usize = 0;
    _ = c.mbedtls_base64_decode(null, 0, &sig_len, signature_b64.ptr, signature_b64.len);
    const sig_buf = try allocator.alloc(u8, sig_len);
    defer allocator.free(sig_buf);
    if (c.mbedtls_base64_decode(
        sig_buf.ptr,
        sig_buf.len,
        &sig_len,
        signature_b64.ptr,
        signature_b64.len,
    ) != 0) return error.Base64DecodeFailed;

    var pk: c.mbedtls_pk_context = undefined;
    c.mbedtls_pk_init(&pk);
    defer c.mbedtls_pk_free(&pk);

    if (c.mbedtls_pk_parse_public_key(&pk, pem_z.ptr, pem_z.len + 1) != 0)
        return error.PemParseFailed;

    const pss_opts: c.mbedtls_pk_rsassa_pss_options = .{
        .mgf1_hash_id = c.MBEDTLS_MD_SHA256,
        .expected_salt_len = c.MBEDTLS_RSA_SALT_LEN_ANY,
    };
    const rc = c.mbedtls_pk_verify_ext(
        c.MBEDTLS_PK_RSASSA_PSS,
        &pss_opts,
        &pk,
        c.MBEDTLS_MD_SHA256,
        digest,
        digest.len,
        sig_buf.ptr,
        sig_len,
    );
    return rc == 0;
}

test "signing message format matches Julia" {
    const a = std.testing.allocator;
    const msg = try signingMessage(a, 1_700_000_000_000, "get", "/trade-api/v2/exchange/status");
    defer a.free(msg);
    try std.testing.expectEqualStrings("1700000000000GET/trade-api/v2/exchange/status", msg);
}

const test_private_key = @embedFile("testdata/test_rsa_private.pem");
const test_public_key = @embedFile("testdata/test_rsa_public.pem");

test "signs and self-verifies" {
    const a = std.testing.allocator;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("hello kalshi", &digest, .{});

    const sig = try signDigest(a, test_private_key, &digest);
    defer a.free(sig);
    try std.testing.expect(sig.len > 0);

    const ok = try verifyDigest(a, test_public_key, &digest, sig);
    try std.testing.expect(ok);
}

test "signRequest round-trips through verifyDigest" {
    const a = std.testing.allocator;
    const ts: i64 = 1_700_000_000_000;
    const method = "GET";
    const path = "/trade-api/v2/exchange/status";

    const sig = try signRequest(a, test_private_key, ts, method, path);
    defer a.free(sig);

    const msg = try signingMessage(a, ts, method, path);
    defer a.free(msg);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(msg, &digest, .{});

    const ok = try verifyDigest(a, test_public_key, &digest, sig);
    try std.testing.expect(ok);
}

test "tampered signature is rejected" {
    const a = std.testing.allocator;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("hello kalshi", &digest, .{});

    const sig = try signDigest(a, test_private_key, &digest);
    defer a.free(sig);

    var tampered = try a.dupe(u8, sig);
    defer a.free(tampered);
    const idx = tampered.len - 2;
    tampered[idx] = if (tampered[idx] == 'A') 'B' else 'A';

    const ok = try verifyDigest(a, test_public_key, &digest, tampered);
    try std.testing.expect(!ok);
}

#!/usr/bin/env bash
# Stage 1 cross-language signature verification.
#
# Proves bidirectional RSA-PSS compatibility between Zig (mbedTLS) and the
# OpenSSL family (which Julia's KalshiAuth.rsa_pss_sign uses internally):
#   1. Zig signs   → OpenSSL verifies   (Zig output understood by Julia/Kalshi)
#   2. OpenSSL signs → Zig verifies     (Julia/Kalshi output understood by Zig)
#
# Exits 0 only if both directions verify.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

PRIV="$ROOT/src/kalshi/testdata/test_rsa_private.pem"
PUB="$ROOT/src/kalshi/testdata/test_rsa_public.pem"
MSG_FILE="$(mktemp -t praescientia-msg.XXXXXX)"
ZIG_SIG_B64="$(mktemp -t praescientia-zigsig.XXXXXX)"
ZIG_SIG_BIN="$(mktemp -t praescientia-zigsig.XXXXXX.bin)"
OSSL_SIG_BIN="$(mktemp -t praescientia-osslsig.XXXXXX.bin)"
OSSL_SIG_B64="$(mktemp -t praescientia-osslsig.XXXXXX.b64)"
trap 'rm -f "$MSG_FILE" "$ZIG_SIG_B64" "$ZIG_SIG_BIN" "$OSSL_SIG_BIN" "$OSSL_SIG_B64"' EXIT

MESSAGE="1700000000000GET/trade-api/v2/exchange/status"
printf '%s' "$MESSAGE" > "$MSG_FILE"

echo "[1/4] Build Zig binaries"
zig build -Doptimize=ReleaseSafe > /dev/null

echo "[2/4] Zig sign → OpenSSL verify"
./zig-out/bin/praescientia-signtest --key "$PRIV" --message "$MESSAGE" > "$ZIG_SIG_B64"
base64 --decode < "$ZIG_SIG_B64" > "$ZIG_SIG_BIN"
openssl dgst -sha256 -verify "$PUB" \
    -signature "$ZIG_SIG_BIN" \
    -sigopt rsa_padding_mode:pss \
    -sigopt rsa_pss_saltlen:-1 \
    -sigopt rsa_mgf1_md:sha256 \
    "$MSG_FILE" \
    || { echo "FAIL: OpenSSL rejected Zig signature"; exit 1; }

echo "[3/4] OpenSSL sign → Zig verify"
openssl dgst -sha256 -sign "$PRIV" \
    -sigopt rsa_padding_mode:pss \
    -sigopt rsa_pss_saltlen:-1 \
    -sigopt rsa_mgf1_md:sha256 \
    -out "$OSSL_SIG_BIN" \
    "$MSG_FILE"
base64 -i "$OSSL_SIG_BIN" -o "$OSSL_SIG_B64" 2>/dev/null \
    || base64 < "$OSSL_SIG_BIN" > "$OSSL_SIG_B64"
RESULT="$(./zig-out/bin/praescientia-verifytest --pubkey "$PUB" --signature "$OSSL_SIG_B64" --message "$MESSAGE")"
if [ "$RESULT" != "OK" ]; then
    echo "FAIL: Zig rejected OpenSSL signature ($RESULT)"
    exit 1
fi

echo "[4/4] Tampered signature is rejected by Zig"
printf 'XXXXXXXXXXXX%s' "$(cat "$OSSL_SIG_B64")" > "$OSSL_SIG_B64.bad"
if ./zig-out/bin/praescientia-verifytest --pubkey "$PUB" --signature "$OSSL_SIG_B64.bad" --message "$MESSAGE" 2>/dev/null | grep -q "^OK$"; then
    echo "FAIL: Zig accepted a tampered signature"
    rm -f "$OSSL_SIG_B64.bad"
    exit 1
fi
rm -f "$OSSL_SIG_B64.bad"

echo ""
echo "cross_verify: PASS — Zig and OpenSSL agree in both directions."

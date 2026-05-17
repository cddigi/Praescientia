/* Umbrella header consumed by build.zig's addTranslateC.
 * Pulls in exactly the mbedTLS surface area Praescientia needs:
 *   - PK + RSA-PSS signing
 *   - PEM private-key parsing
 *   - SHA-256 (for message digest)
 *   - CTR-DRBG + entropy (PSS requires a CSPRNG for salt)
 *   - Base64 (so we can encode the resulting signature)
 *   - Error string lookup for diagnostics
 *
 * Mirrors the OpenSSL primitives used by src/KalshiAuth.jl. */

#include "mbedtls/build_info.h"
#include "mbedtls/pk.h"
#include "mbedtls/rsa.h"
#include "mbedtls/md.h"
#include "mbedtls/sha256.h"
#include "mbedtls/entropy.h"
#include "mbedtls/ctr_drbg.h"
#include "mbedtls/base64.h"
#include "mbedtls/error.h"

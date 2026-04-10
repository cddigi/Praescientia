"""
    KalshiAuth - Kalshi API Authentication & HTTP Client

RSA-SHA256 with PSS padding authentication for Kalshi's Trading API.
Supports both Live and Demo environments.

Base URLs:
  - Live: https://api.elections.kalshi.com/trade-api/v2
  - Demo: https://demo-api.kalshi.co/trade-api/v2

Auth Headers:
  - KALSHI-ACCESS-KEY:       API Key ID
  - KALSHI-ACCESS-TIMESTAMP: Request timestamp in milliseconds
  - KALSHI-ACCESS-SIGNATURE: Base64-encoded RSA-PSS signature

Signing message format: "{timestamp_ms}{HTTP_METHOD}{path_without_query_params}"
"""
module KalshiAuth

using HTTP
using JSON3
using Dates
using Base64
using Libdl

export KalshiConfig, load_config, kalshi_request
export kalshi_get, kalshi_post, kalshi_put, kalshi_delete

# =============================================================================
# Constants
# =============================================================================

const LIVE_BASE_URL = "https://api.elections.kalshi.com/trade-api/v2"
const DEMO_BASE_URL = "https://demo-api.kalshi.co/trade-api/v2"

# OpenSSL constants for EVP_PKEY_CTX_ctrl
const EVP_PKEY_RSA = 6
const EVP_PKEY_CTRL_RSA_PADDING = 0x1001
const EVP_PKEY_CTRL_RSA_PSS_SALTLEN = 0x1002
const RSA_PKCS1_PSS_PADDING = 6
const RSA_PSS_SALTLEN_DIGEST = -1  # salt length = digest length (32 for SHA256)

# =============================================================================
# Configuration
# =============================================================================

"""
    KalshiConfig

Holds API credentials and environment configuration.

Fields:
  - api_key_id:      Your Kalshi API Key ID
  - private_key_pem: RSA private key in PEM format (string)
  - base_url:        API base URL (auto-set based on use_demo)
  - use_demo:        true for demo environment, false for live
  - verbose:         print request/response debug info
"""
mutable struct KalshiConfig
    api_key_id::String
    private_key_pem::String
    base_url::String
    use_demo::Bool
    verbose::Bool
end

"""
    load_config(; api_key_id, private_key_file, demo, verbose) -> KalshiConfig

Load Kalshi API configuration.

Precedence for api_key_id:
  1. Explicit `api_key_id` parameter
  2. `KALSHI_API_KEY_ID` environment variable

Precedence for private_key_file:
  1. Explicit `private_key_file` parameter
  2. `KALSHI_PRIVATE_KEY_FILE` environment variable
  3. `Claude-Demo.txt` in project root (for demo mode)
"""
function load_config(;
    api_key_id::String = "",
    private_key_file::String = "",
    demo::Bool = true,
    verbose::Bool = false
)
    # Resolve API Key ID
    key_id = if !isempty(api_key_id)
        api_key_id
    elseif haskey(ENV, "KALSHI_API_KEY_ID")
        ENV["KALSHI_API_KEY_ID"]
    else
        ""
    end

    if isempty(key_id)
        @warn """
        No API Key ID provided. Set one of:
          1. Pass api_key_id="your-key-id" to load_config()
          2. Set KALSHI_API_KEY_ID environment variable
        You can find your key ID in the Kalshi dashboard under API Keys.
        """
    end

    # Resolve private key file
    key_file = if !isempty(private_key_file)
        private_key_file
    elseif haskey(ENV, "KALSHI_PRIVATE_KEY_FILE")
        ENV["KALSHI_PRIVATE_KEY_FILE"]
    elseif demo
        # Look for Claude-Demo.txt, walking up parent directories (handles worktrees)
        found = ""
        dir = dirname(dirname(@__FILE__))
        for _ in 1:10
            candidate = joinpath(dir, "Claude-Demo.txt")
            if isfile(candidate)
                found = candidate
                break
            end
            parent = dirname(dir)
            parent == dir && break
            dir = parent
        end
        found
    else
        ""
    end

    if isempty(key_file) || !isfile(key_file)
        error("Private key file not found: '$(key_file)'. Provide private_key_file or set KALSHI_PRIVATE_KEY_FILE.")
    end

    pem = read(key_file, String)

    base_url = demo ? DEMO_BASE_URL : LIVE_BASE_URL

    if verbose
        env = demo ? "DEMO" : "LIVE"
        @info "Kalshi config loaded" environment=env base_url key_id_set=!isempty(key_id)
    end

    return KalshiConfig(key_id, pem, base_url, demo, verbose)
end

# =============================================================================
# RSA-PSS Signing via OpenSSL (Libdl)
# =============================================================================

# Libcrypto handle — loaded once at first use
const _libcrypto_handle = Ref{Ptr{Cvoid}}(C_NULL)

function _get_sym(name::Symbol)::Ptr{Cvoid}
    if _libcrypto_handle[] == C_NULL
        # Try common library names
        for libname in ("libcrypto-3-x64", "libcrypto-3", "libcrypto",
                        "libcrypto-1_1-x64", "libcrypto-1_1")
            h = Libdl.dlopen(libname; throw_error=false)
            if h !== nothing
                _libcrypto_handle[] = h
                break
            end
        end
        if _libcrypto_handle[] == C_NULL
            # Try OpenSSL_jll artifact path
            try
                @eval Main using OpenSSL_jll
                h = Libdl.dlopen(OpenSSL_jll.libcrypto; throw_error=false)
                if h !== nothing
                    _libcrypto_handle[] = h
                end
            catch
            end
        end
        _libcrypto_handle[] == C_NULL && error(
            "Cannot find OpenSSL libcrypto. Install OpenSSL_jll: Pkg.add(\"OpenSSL_jll\")")
    end
    return Libdl.dlsym(_libcrypto_handle[], name)
end

"""
    rsa_pss_sign(pem_key::String, message::String) -> String

Sign a message using RSA-SHA256 with PSS padding (MGF1-SHA256, salt=digest_length).
Returns base64-encoded signature.
"""
function rsa_pss_sign(pem_key::String, message::String)::String
    msg = Vector{UInt8}(message)
    pem = Vector{UInt8}(pem_key)

    # Create BIO from PEM string
    bio = ccall(_get_sym(:BIO_new_mem_buf), Ptr{Cvoid}, (Ptr{UInt8}, Cint), pem, length(pem))
    bio == C_NULL && error("BIO_new_mem_buf failed")

    # Read private key from BIO
    pkey = ccall(_get_sym(:PEM_read_bio_PrivateKey), Ptr{Cvoid},
        (Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}),
        bio, C_NULL, C_NULL, C_NULL)
    ccall(_get_sym(:BIO_free), Cint, (Ptr{Cvoid},), bio)
    pkey == C_NULL && error("PEM_read_bio_PrivateKey failed — check your private key PEM format")

    try
        # Create EVP_MD_CTX
        md_ctx = ccall(_get_sym(:EVP_MD_CTX_new), Ptr{Cvoid}, ())
        md_ctx == C_NULL && error("EVP_MD_CTX_new failed")

        try
            # Get SHA256 digest
            sha256 = ccall(_get_sym(:EVP_sha256), Ptr{Cvoid}, ())

            # Initialize DigestSign with SHA256
            pctx_ref = Ref{Ptr{Cvoid}}(C_NULL)
            ret = ccall(_get_sym(:EVP_DigestSignInit), Cint,
                (Ptr{Cvoid}, Ptr{Ptr{Cvoid}}, Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}),
                md_ctx, pctx_ref, sha256, C_NULL, pkey)
            ret != 1 && error("EVP_DigestSignInit failed (ret=$ret)")

            pctx = pctx_ref[]

            # Set RSA-PSS padding via EVP_PKEY_CTX_ctrl
            ret = ccall(_get_sym(:EVP_PKEY_CTX_ctrl), Cint,
                (Ptr{Cvoid}, Cint, Cint, Cint, Cint, Ptr{Cvoid}),
                pctx, EVP_PKEY_RSA, -1, EVP_PKEY_CTRL_RSA_PADDING, RSA_PKCS1_PSS_PADDING, C_NULL)
            ret <= 0 && error("Failed to set PSS padding (ret=$ret)")

            # Set salt length = digest length (32 bytes for SHA256)
            ret = ccall(_get_sym(:EVP_PKEY_CTX_ctrl), Cint,
                (Ptr{Cvoid}, Cint, Cint, Cint, Cint, Ptr{Cvoid}),
                pctx, EVP_PKEY_RSA, -1, EVP_PKEY_CTRL_RSA_PSS_SALTLEN, RSA_PSS_SALTLEN_DIGEST, C_NULL)
            ret <= 0 && error("Failed to set PSS salt length (ret=$ret)")

            # Get required signature length
            siglen = Ref{Csize_t}(0)
            ret = ccall(_get_sym(:EVP_DigestSign), Cint,
                (Ptr{Cvoid}, Ptr{UInt8}, Ptr{Csize_t}, Ptr{UInt8}, Csize_t),
                md_ctx, C_NULL, siglen, msg, length(msg))
            ret != 1 && error("EVP_DigestSign (get length) failed (ret=$ret)")

            # Perform signing
            sig = Vector{UInt8}(undef, siglen[])
            ret = ccall(_get_sym(:EVP_DigestSign), Cint,
                (Ptr{Cvoid}, Ptr{UInt8}, Ptr{Csize_t}, Ptr{UInt8}, Csize_t),
                md_ctx, sig, siglen, msg, length(msg))
            ret != 1 && error("EVP_DigestSign failed (ret=$ret)")

            return base64encode(sig[1:siglen[]])
        finally
            ccall(_get_sym(:EVP_MD_CTX_free), Cvoid, (Ptr{Cvoid},), md_ctx)
        end
    finally
        ccall(_get_sym(:EVP_PKEY_free), Cvoid, (Ptr{Cvoid},), pkey)
    end
end

# =============================================================================
# HTTP Client
# =============================================================================

"""
    build_auth_headers(config::KalshiConfig, method::String, path::String) -> Vector{Pair}

Build authentication headers for a Kalshi API request.
Signs: "{timestamp_ms}{METHOD}{path}" (path without query parameters).
"""
function build_auth_headers(config::KalshiConfig, method::String, path::String)
    headers = [
        "Content-Type" => "application/json",
        "Accept" => "application/json"
    ]

    # Only add auth headers if we have credentials
    if !isempty(config.api_key_id) && !isempty(config.private_key_pem)
        timestamp_ms = round(Int64, time() * 1000)
        message = string(timestamp_ms, uppercase(method), path)
        signature = rsa_pss_sign(config.private_key_pem, message)

        pushfirst!(headers,
            "KALSHI-ACCESS-KEY" => config.api_key_id,
            "KALSHI-ACCESS-TIMESTAMP" => string(timestamp_ms),
            "KALSHI-ACCESS-SIGNATURE" => signature)
    end

    return headers
end

"""
    kalshi_request(config, method, endpoint; params, body, raw) -> response data

Make an authenticated request to the Kalshi API.

Arguments:
  - config:   KalshiConfig with credentials
  - method:   HTTP method (GET, POST, PUT, DELETE)
  - endpoint: API path after /trade-api/v2 (e.g., "/exchange/status")
  - params:   Dict of query parameters (optional)
  - body:     Request body as Dict (optional, for POST/PUT)
  - raw:      If true, return raw HTTP.Response (default: false)

Returns parsed JSON response (or raw HTTP.Response if raw=true).
"""
function kalshi_request(config::KalshiConfig, method::String, endpoint::String;
    params::Dict = Dict(),
    body::Union{Dict, Nothing} = nothing,
    raw::Bool = false
)
    # Build full path (for signing — no query params)
    path = "/trade-api/v2" * endpoint

    # Build URL with query params
    url = config.base_url * endpoint
    if !isempty(params)
        # Filter out nothing values
        filtered = Dict(k => v for (k, v) in params if v !== nothing && v !== "")
        if !isempty(filtered)
            query = join(["$(HTTP.URIs.escapeuri(string(k)))=$(HTTP.URIs.escapeuri(string(v)))" for (k, v) in filtered], "&")
            url *= "?" * query
        end
    end

    # Auth headers
    headers = build_auth_headers(config, method, path)

    if config.verbose
        @info "Kalshi request" method url
    end

    try
        response = if method == "GET"
            HTTP.get(url, headers; status_exception=false)
        elseif method == "POST"
            payload = body !== nothing ? JSON3.write(body) : ""
            HTTP.post(url, headers, payload; status_exception=false)
        elseif method == "PUT"
            payload = body !== nothing ? JSON3.write(body) : ""
            HTTP.put(url, headers, payload; status_exception=false)
        elseif method == "DELETE"
            if body !== nothing
                payload = JSON3.write(body)
                HTTP.request("DELETE", url, headers, payload; status_exception=false)
            else
                HTTP.request("DELETE", url, headers; status_exception=false)
            end
        else
            error("Unsupported HTTP method: $method")
        end

        if raw
            return response
        end

        status = response.status
        body_str = String(response.body)

        if config.verbose
            @info "Response" status body_preview=first(body_str, 200)
        end

        if status >= 400
            error_msg = try
                err = JSON3.read(body_str)
                get(err, :message, get(err, :error, body_str))
            catch
                body_str
            end
            error("Kalshi API error ($status): $error_msg")
        end

        if isempty(body_str)
            return Dict()
        end

        return JSON3.read(body_str)
    catch e
        if e isa HTTP.ExceptionRequest.StatusError
            rethrow()
        elseif e isa ErrorException && startswith(e.msg, "Kalshi API error")
            rethrow()
        else
            @error "Request failed" exception=e method url
            rethrow()
        end
    end
end

# Convenience wrappers
kalshi_get(config, endpoint; params=Dict(), raw=false) =
    kalshi_request(config, "GET", endpoint; params, raw)

kalshi_post(config, endpoint; body=Dict(), params=Dict(), raw=false) =
    kalshi_request(config, "POST", endpoint; body, params, raw)

kalshi_put(config, endpoint; body=Dict(), params=Dict(), raw=false) =
    kalshi_request(config, "PUT", endpoint; body, params, raw)

kalshi_delete(config, endpoint; body=nothing, params=Dict(), raw=false) =
    kalshi_request(config, "DELETE", endpoint; body, params, raw)

# =============================================================================
# Pagination Helper
# =============================================================================

"""
    kalshi_get_all(config, endpoint; params, key, limit) -> Vector

Fetch all pages of a paginated endpoint using cursor-based pagination.
Returns concatenated results from the specified response key.
"""
function kalshi_get_all(config::KalshiConfig, endpoint::String;
    params::Dict = Dict(),
    key::String = "",
    limit::Int = 100
)
    all_results = []
    cursor = nothing
    params = copy(params)
    params["limit"] = limit

    while true
        if cursor !== nothing
            params["cursor"] = cursor
        end

        resp = kalshi_get(config, endpoint; params)

        # Extract results
        if !isempty(key) && haskey(resp, Symbol(key))
            items = resp[Symbol(key)]
            append!(all_results, items)
        end

        # Check for next page
        cursor = get(resp, :cursor, nothing)
        if cursor === nothing || cursor == ""
            break
        end
    end

    return all_results
end

end # module

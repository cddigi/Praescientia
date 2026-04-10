#!/usr/bin/env julia
"""Quick test of Kalshi demo API connectivity."""

include(joinpath(@__DIR__, "..", "src", "KalshiAuth.jl"))
using .KalshiAuth
using JSON3

println("=== Kalshi API Connectivity Test ===")
println()

# Create config without auth (public endpoints only)
config = KalshiConfig("", "", KalshiAuth.DEMO_BASE_URL, true, false)
println("Target: $(config.base_url)")
println()

# Test 1: Exchange status (public, no auth)
println("--- Test 1: GET /exchange/status ---")
try
    result = kalshi_get(config, "/exchange/status")
    println("SUCCESS: ", JSON3.write(result))
catch e
    println("ERROR: ", e)
end
println()

# Test 2: List markets (public, no auth)
println("--- Test 2: GET /markets (limit=3) ---")
try
    result = kalshi_get(config, "/markets"; params=Dict("limit" => 3))
    markets = get(result, :markets, [])
    println("SUCCESS: Found $(length(markets)) markets")
    for m in markets
        ticker = get(m, :ticker, "?")
        title = get(m, :title, "?")
        println("  - $ticker: $title")
    end
catch e
    println("ERROR: ", e)
end
println()

# Test 3: RSA signing (just test that OpenSSL works)
println("--- Test 3: RSA-PSS Signing ---")
try
    # Walk up directories to find Claude-Demo.txt
    key_file = ""
    dir = dirname(dirname(@__FILE__))
    for _ in 1:10
        candidate = joinpath(dir, "Claude-Demo.txt")
        if isfile(candidate)
            key_file = candidate
            break
        end
        parent = dirname(dir)
        parent == dir && break
        dir = parent
    end

    if !isempty(key_file)
        pem = read(key_file, String)
        sig = KalshiAuth.rsa_pss_sign(pem, "test_message_12345")
        println("SUCCESS: Signature generated ($(length(sig)) chars) from $key_file")
    else
        println("SKIP: Claude-Demo.txt not found (walked up from $(dirname(dirname(@__FILE__))))")
    end
catch e
    println("ERROR: ", sprint(showerror, e))
end
println()

println("=== Tests complete ===")

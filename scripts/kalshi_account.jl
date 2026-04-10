#!/usr/bin/env julia
"""
    Kalshi Account, API Keys & Incentives API Scripts

Endpoints:
  GET    /api_keys                  - List all API keys
  POST   /api_keys                  - Create API key (provide RSA public key)
  POST   /api_keys/generate         - Generate API key (auto key pair)
  DELETE /api_keys/{api_key}        - Delete API key permanently
  GET    /account/limits            - API tier limits
  GET    /incentive_programs        - Incentive programs list

Usage:
  julia --project=. scripts/kalshi_account.jl list_keys
  julia --project=. scripts/kalshi_account.jl create_key --public_key_file=PATH
  julia --project=. scripts/kalshi_account.jl generate_key
  julia --project=. scripts/kalshi_account.jl delete_key KEY_ID
  julia --project=. scripts/kalshi_account.jl limits
  julia --project=. scripts/kalshi_account.jl incentives [--status=active] [--type=TYPE]
"""

include(joinpath(@__DIR__, "..", "src", "KalshiAuth.jl"))
using .KalshiAuth
using JSON3

# =============================================================================
# API Keys Endpoints
# =============================================================================

"""
    list_api_keys(config) -> response

List all API keys for the authenticated user.
"""
function list_api_keys(config::KalshiConfig)
    return kalshi_get(config, "/api_keys")
end

"""
    create_api_key(config; public_key_pem) -> response

Create an API key by providing your own RSA public key PEM.
Returns the key_id to use for authentication.
"""
function create_api_key(config::KalshiConfig; public_key_pem::String)
    body = Dict{String,Any}("public_key" => public_key_pem)
    return kalshi_post(config, "/api_keys"; body)
end

"""
    generate_api_key(config) -> response

Generate an API key with automatic RSA key pair creation.
Returns both key_id and private_key — save the private key securely!
"""
function generate_api_key(config::KalshiConfig)
    return kalshi_post(config, "/api_keys/generate")
end

"""
    delete_api_key(config, api_key_id) -> response

Permanently delete an API key.
"""
function delete_api_key(config::KalshiConfig, api_key_id::String)
    return kalshi_delete(config, "/api_keys/$api_key_id")
end

# =============================================================================
# Account Limits
# =============================================================================

"""
    get_account_limits(config) -> response

Get API tier limits for the authenticated user.
Shows read/write rate limits based on your tier (Basic, Advanced, Premier, Prime).
"""
function get_account_limits(config::KalshiConfig)
    return kalshi_get(config, "/account/limits")
end

# =============================================================================
# Incentive Programs
# =============================================================================

"""
    list_incentive_programs(config; status, type) -> response

List incentive programs with optional filters.
"""
function list_incentive_programs(config::KalshiConfig;
    status::String = "",
    type::String = ""
)
    params = Dict{String,Any}()
    !isempty(status) && (params["status"] = status)
    !isempty(type) && (params["type"] = type)
    return kalshi_get(config, "/incentive_programs"; params)
end

# =============================================================================
# FCM Endpoints (Futures Commission Merchant — Premier/Market Maker only)
# =============================================================================

"""
    get_fcm_orders(config; subtrader_id, limit, cursor) -> response

Get orders filtered by subtrader ID. FCM access required.
"""
function get_fcm_orders(config::KalshiConfig;
    subtrader_id::String = "",
    limit::Int = 100,
    cursor::String = ""
)
    params = Dict{String,Any}("limit" => limit)
    !isempty(subtrader_id) && (params["subtrader_id"] = subtrader_id)
    !isempty(cursor) && (params["cursor"] = cursor)
    return kalshi_get(config, "/fcm/orders"; params)
end

"""
    get_fcm_positions(config; subtrader_id, limit, cursor) -> response

Get positions filtered by subtrader ID. FCM access required.
"""
function get_fcm_positions(config::KalshiConfig;
    subtrader_id::String = "",
    limit::Int = 100,
    cursor::String = ""
)
    params = Dict{String,Any}("limit" => limit)
    !isempty(subtrader_id) && (params["subtrader_id"] = subtrader_id)
    !isempty(cursor) && (params["cursor"] = cursor)
    return kalshi_get(config, "/fcm/positions"; params)
end

# =============================================================================
# CLI
# =============================================================================

function parse_arg(args, prefix)
    for arg in args
        if startswith(arg, "--$(prefix)=")
            return split(arg, "=", limit=2)[2]
        end
    end
    return ""
end

function parse_int_arg(args, prefix)
    val = parse_arg(args, prefix)
    return isempty(val) ? nothing : parse(Int, val)
end

function main()
    if isempty(ARGS)
        println("""
        Usage: julia --project=. scripts/kalshi_account.jl <command> [options]

        Commands:
          list_keys                 List all API keys
          create_key                Create API key (provide public key)
          generate_key              Generate API key pair (SAVE the private key!)
          delete_key KEY_ID         Permanently delete an API key
          limits                    Show API tier rate limits
          incentives                List incentive programs
          fcm_orders                FCM orders (Premier/MM only)
          fcm_positions             FCM positions (Premier/MM only)

        Create key options:
          --public_key_file=PATH    Path to RSA public key PEM file

        Filter options:
          --status=STATUS           Filter incentives by status
          --type=TYPE               Filter incentives by type
          --subtrader_id=ID         Filter FCM by subtrader

        Common options:
          --demo / --live           Environment
          --verbose                 Debug output
        """)
        return
    end

    demo = !("--live" in ARGS)
    verbose = "--verbose" in ARGS
    config = load_config(; demo, verbose)

    cmd = ARGS[1]
    rest = filter(a -> !startswith(a, "--"), ARGS[2:end])

    if cmd == "list_keys"
        result = list_api_keys(config)
        println(JSON3.pretty(JSON3.write(result)))

    elseif cmd == "create_key"
        pub_file = parse_arg(ARGS, "public_key_file")
        isempty(pub_file) && error("--public_key_file required")
        !isfile(pub_file) && error("File not found: $pub_file")
        pub_pem = read(pub_file, String)
        result = create_api_key(config; public_key_pem=pub_pem)
        println(JSON3.pretty(JSON3.write(result)))
        @warn "Save the returned key_id — you'll need it for KALSHI-ACCESS-KEY header"

    elseif cmd == "generate_key"
        result = generate_api_key(config)
        println(JSON3.pretty(JSON3.write(result)))
        println("\n⚠️  SAVE THE PRIVATE KEY — it will not be shown again!")

    elseif cmd == "delete_key"
        key_id = isempty(rest) ? error("API Key ID required") : rest[1]
        result = delete_api_key(config, key_id)
        println(JSON3.pretty(JSON3.write(result)))
        println("Key deleted permanently.")

    elseif cmd == "limits"
        result = get_account_limits(config)
        println(JSON3.pretty(JSON3.write(result)))

    elseif cmd == "incentives"
        result = list_incentive_programs(config;
            status = parse_arg(ARGS, "status"),
            type = parse_arg(ARGS, "type"))
        println(JSON3.pretty(JSON3.write(result)))

    elseif cmd == "fcm_orders"
        result = get_fcm_orders(config;
            subtrader_id = parse_arg(ARGS, "subtrader_id"),
            limit = something(parse_int_arg(ARGS, "limit"), 100))
        println(JSON3.pretty(JSON3.write(result)))

    elseif cmd == "fcm_positions"
        result = get_fcm_positions(config;
            subtrader_id = parse_arg(ARGS, "subtrader_id"),
            limit = something(parse_int_arg(ARGS, "limit"), 100))
        println(JSON3.pretty(JSON3.write(result)))

    else
        println("Unknown command: $cmd")
    end
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end

#!/usr/bin/env julia
"""
    Kalshi Portfolio & Balance API Scripts

Endpoints:
  GET  /portfolio/balance                         - Account balance & portfolio value
  POST /portfolio/subaccounts                     - Create subaccount
  POST /portfolio/subaccounts/transfer            - Transfer funds between subaccounts
  GET  /portfolio/subaccounts/balances            - Balances for all subaccounts
  GET  /portfolio/subaccounts/transfers           - List subaccount transfers
  PUT  /portfolio/subaccounts/netting             - Update netting setting
  GET  /portfolio/subaccounts/netting             - Get netting settings
  GET  /portfolio/positions                       - Market positions
  GET  /portfolio/settlements                     - Settlement history
  GET  /portfolio/summary/total_resting_order_value - Total value of resting orders
  GET  /portfolio/fills                           - All fills for authenticated user

Usage:
  julia --project=. scripts/kalshi_portfolio.jl balance
  julia --project=. scripts/kalshi_portfolio.jl positions [--ticker=T] [--event_ticker=E] [--settlement_status=S]
  julia --project=. scripts/kalshi_portfolio.jl settlements [--limit=100]
  julia --project=. scripts/kalshi_portfolio.jl fills [--ticker=T] [--limit=100]
  julia --project=. scripts/kalshi_portfolio.jl resting_value
  julia --project=. scripts/kalshi_portfolio.jl subaccounts_balances
  julia --project=. scripts/kalshi_portfolio.jl create_subaccount --name=NAME
  julia --project=. scripts/kalshi_portfolio.jl transfer --from=ID --to=ID --amount=CENTS
"""

include(joinpath(@__DIR__, "..", "src", "KalshiAuth.jl"))
using .KalshiAuth
using JSON3

# =============================================================================
# Portfolio Endpoints
# =============================================================================

"""
    get_balance(config) -> response

Get account balance and portfolio value.
Returns: available_balance, portfolio_value, etc.
"""
function get_balance(config::KalshiConfig)
    return kalshi_get(config, "/portfolio/balance")
end

"""
    get_positions(config; ticker, event_ticker, settlement_status, limit, cursor) -> response

Get market positions with filtering.

settlement_status: "unsettled", "settled", or empty for all.
"""
function get_positions(config::KalshiConfig;
    ticker::String = "",
    event_ticker::String = "",
    settlement_status::String = "",
    limit::Int = 100,
    cursor::String = ""
)
    params = Dict{String,Any}("limit" => limit)
    !isempty(ticker) && (params["ticker"] = ticker)
    !isempty(event_ticker) && (params["event_ticker"] = event_ticker)
    !isempty(settlement_status) && (params["settlement_status"] = settlement_status)
    !isempty(cursor) && (params["cursor"] = cursor)
    return kalshi_get(config, "/portfolio/positions"; params)
end

"""
    get_settlements(config; limit, cursor) -> response

Get settlement history.
"""
function get_settlements(config::KalshiConfig;
    limit::Int = 100,
    cursor::String = ""
)
    params = Dict{String,Any}("limit" => limit)
    !isempty(cursor) && (params["cursor"] = cursor)
    return kalshi_get(config, "/portfolio/settlements"; params)
end

"""
    get_fills(config; ticker, order_id, min_ts, max_ts, limit, cursor) -> response

Get all fills for authenticated user.
"""
function get_fills(config::KalshiConfig;
    ticker::String = "",
    order_id::String = "",
    min_ts::Union{Int,Nothing} = nothing,
    max_ts::Union{Int,Nothing} = nothing,
    limit::Int = 100,
    cursor::String = ""
)
    params = Dict{String,Any}("limit" => limit)
    !isempty(ticker) && (params["ticker"] = ticker)
    !isempty(order_id) && (params["order_id"] = order_id)
    min_ts !== nothing && (params["min_ts"] = min_ts)
    max_ts !== nothing && (params["max_ts"] = max_ts)
    !isempty(cursor) && (params["cursor"] = cursor)
    return kalshi_get(config, "/portfolio/fills"; params)
end

"""
    get_total_resting_order_value(config) -> response

Get total value of all resting orders.
"""
function get_total_resting_order_value(config::KalshiConfig)
    return kalshi_get(config, "/portfolio/summary/total_resting_order_value")
end

# =============================================================================
# Subaccounts
# =============================================================================

"""
    create_subaccount(config; name) -> response

Create a new subaccount.
"""
function create_subaccount(config::KalshiConfig; name::String)
    body = Dict{String,Any}("name" => name)
    return kalshi_post(config, "/portfolio/subaccounts"; body)
end

"""
    transfer_between_subaccounts(config; from_id, to_id, amount) -> response

Transfer funds between subaccounts. Amount in cents.
"""
function transfer_between_subaccounts(config::KalshiConfig;
    from_id::String,
    to_id::String,
    amount::Int
)
    body = Dict{String,Any}(
        "from" => from_id,
        "to" => to_id,
        "amount" => amount
    )
    return kalshi_post(config, "/portfolio/subaccounts/transfer"; body)
end

"""
    get_subaccount_balances(config) -> response

Get balances for all subaccounts.
"""
function get_subaccount_balances(config::KalshiConfig)
    return kalshi_get(config, "/portfolio/subaccounts/balances")
end

"""
    get_subaccount_transfers(config; limit, cursor) -> response

List paginated subaccount transfers.
"""
function get_subaccount_transfers(config::KalshiConfig;
    limit::Int = 100,
    cursor::String = ""
)
    params = Dict{String,Any}("limit" => limit)
    !isempty(cursor) && (params["cursor"] = cursor)
    return kalshi_get(config, "/portfolio/subaccounts/transfers"; params)
end

"""
    update_netting(config; subaccount_id, netting_enabled) -> response

Update netting setting for a subaccount.
"""
function update_netting(config::KalshiConfig;
    subaccount_id::String,
    netting_enabled::Bool
)
    body = Dict{String,Any}(
        "subaccount_id" => subaccount_id,
        "netting_enabled" => netting_enabled
    )
    return kalshi_put(config, "/portfolio/subaccounts/netting"; body)
end

"""
    get_netting(config) -> response

Get netting settings for subaccounts.
"""
function get_netting(config::KalshiConfig)
    return kalshi_get(config, "/portfolio/subaccounts/netting")
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
        Usage: julia --project=. scripts/kalshi_portfolio.jl <command> [options]

        Commands:
          balance                   Account balance & portfolio value
          positions                 Market positions
          settlements               Settlement history
          fills                     All fills
          resting_value             Total resting order value
          subaccounts_balances      All subaccount balances
          subaccount_transfers      List subaccount transfers
          netting                   Get netting settings
          create_subaccount         Create a subaccount
          transfer                  Transfer between subaccounts
          set_netting               Update netting setting

        Options:
          --ticker=TICKER           Filter by ticker
          --event_ticker=EVENT      Filter by event
          --settlement_status=S     unsettled | settled
          --name=NAME               Subaccount name (for create)
          --from=ID                 Source subaccount (for transfer)
          --to=ID                   Destination subaccount (for transfer)
          --amount=CENTS            Amount in cents (for transfer)
          --subaccount_id=ID        Subaccount ID (for netting)
          --netting_enabled=BOOL    true | false (for netting)
          --limit=N                 Results per page
          --demo / --live           Environment
          --verbose                 Debug output
        """)
        return
    end

    demo = !("--live" in ARGS)
    verbose = "--verbose" in ARGS
    config = load_config(; demo, verbose)

    cmd = ARGS[1]

    if cmd == "balance"
        result = get_balance(config)
        println(JSON3.pretty(JSON3.write(result)))

    elseif cmd == "positions"
        result = get_positions(config;
            ticker = parse_arg(ARGS, "ticker"),
            event_ticker = parse_arg(ARGS, "event_ticker"),
            settlement_status = parse_arg(ARGS, "settlement_status"),
            limit = something(parse_int_arg(ARGS, "limit"), 100))
        println(JSON3.pretty(JSON3.write(result)))

    elseif cmd == "settlements"
        result = get_settlements(config;
            limit = something(parse_int_arg(ARGS, "limit"), 100))
        println(JSON3.pretty(JSON3.write(result)))

    elseif cmd == "fills"
        result = get_fills(config;
            ticker = parse_arg(ARGS, "ticker"),
            limit = something(parse_int_arg(ARGS, "limit"), 100))
        println(JSON3.pretty(JSON3.write(result)))

    elseif cmd == "resting_value"
        result = get_total_resting_order_value(config)
        println(JSON3.pretty(JSON3.write(result)))

    elseif cmd == "subaccounts_balances"
        result = get_subaccount_balances(config)
        println(JSON3.pretty(JSON3.write(result)))

    elseif cmd == "subaccount_transfers"
        result = get_subaccount_transfers(config;
            limit = something(parse_int_arg(ARGS, "limit"), 100))
        println(JSON3.pretty(JSON3.write(result)))

    elseif cmd == "netting"
        result = get_netting(config)
        println(JSON3.pretty(JSON3.write(result)))

    elseif cmd == "create_subaccount"
        name = parse_arg(ARGS, "name")
        isempty(name) && error("--name required")
        result = create_subaccount(config; name)
        println(JSON3.pretty(JSON3.write(result)))

    elseif cmd == "transfer"
        from_id = parse_arg(ARGS, "from")
        to_id = parse_arg(ARGS, "to")
        amount = parse_int_arg(ARGS, "amount")
        isempty(from_id) && error("--from required")
        isempty(to_id) && error("--to required")
        amount === nothing && error("--amount required (in cents)")
        result = transfer_between_subaccounts(config; from_id, to_id, amount)
        println(JSON3.pretty(JSON3.write(result)))

    elseif cmd == "set_netting"
        sub_id = parse_arg(ARGS, "subaccount_id")
        netting = parse_arg(ARGS, "netting_enabled")
        isempty(sub_id) && error("--subaccount_id required")
        isempty(netting) && error("--netting_enabled required (true/false)")
        result = update_netting(config;
            subaccount_id = sub_id,
            netting_enabled = lowercase(netting) == "true")
        println(JSON3.pretty(JSON3.write(result)))

    else
        println("Unknown command: $cmd")
    end
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end

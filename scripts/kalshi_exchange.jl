#!/usr/bin/env julia
"""
    Kalshi Exchange API Scripts

Endpoints:
  GET /exchange/status              - Exchange operational status
  GET /exchange/announcements       - Exchange-wide announcements
  GET /exchange/schedule            - Exchange operating schedule
  GET /exchange/user_data_timestamp - When user data was last validated
  GET /series/fee_changes           - Fee change history by series

Usage:
  julia --project=. scripts/kalshi_exchange.jl status
  julia --project=. scripts/kalshi_exchange.jl announcements
  julia --project=. scripts/kalshi_exchange.jl schedule
  julia --project=. scripts/kalshi_exchange.jl user_data_timestamp
  julia --project=. scripts/kalshi_exchange.jl fee_changes [--series_ticker=TICKER]
"""

include(joinpath(@__DIR__, "..", "src", "KalshiAuth.jl"))
using .KalshiAuth
using JSON3

# =============================================================================
# Exchange Endpoints
# =============================================================================

"""
    get_exchange_status(config) -> response

Get the current exchange operational status.
"""
function get_exchange_status(config::KalshiConfig)
    return kalshi_get(config, "/exchange/status")
end

"""
    get_exchange_announcements(config) -> response

Get exchange-wide announcements.
"""
function get_exchange_announcements(config::KalshiConfig)
    return kalshi_get(config, "/exchange/announcements")
end

"""
    get_exchange_schedule(config) -> response

Get exchange operating schedule.
"""
function get_exchange_schedule(config::KalshiConfig)
    return kalshi_get(config, "/exchange/schedule")
end

"""
    get_user_data_timestamp(config) -> response

Get the timestamp when user data was last validated.
Requires authentication.
"""
function get_user_data_timestamp(config::KalshiConfig)
    return kalshi_get(config, "/exchange/user_data_timestamp")
end

"""
    get_fee_changes(config; series_ticker) -> response

Get fee change history, optionally filtered by series ticker.
"""
function get_fee_changes(config::KalshiConfig; series_ticker::String = "")
    params = Dict{String,Any}()
    if !isempty(series_ticker)
        params["series_ticker"] = series_ticker
    end
    return kalshi_get(config, "/series/fee_changes"; params)
end

# =============================================================================
# CLI
# =============================================================================

function main()
    if isempty(ARGS)
        println("""
        Usage: julia --project=. scripts/kalshi_exchange.jl <command> [options]

        Commands:
          status              Exchange operational status
          announcements       Exchange-wide announcements
          schedule            Exchange operating schedule
          user_data_timestamp When user data was last validated
          fee_changes         Fee change history [--series_ticker=TICKER]

        Options:
          --demo    Use demo environment (default)
          --live    Use live environment
          --verbose Print debug info
        """)
        return
    end

    demo = !("--live" in ARGS)
    verbose = "--verbose" in ARGS
    config = load_config(; demo, verbose)

    cmd = ARGS[1]

    if cmd == "status"
        result = get_exchange_status(config)
        println(JSON3.pretty(JSON3.write(result)))

    elseif cmd == "announcements"
        result = get_exchange_announcements(config)
        println(JSON3.pretty(JSON3.write(result)))

    elseif cmd == "schedule"
        result = get_exchange_schedule(config)
        println(JSON3.pretty(JSON3.write(result)))

    elseif cmd == "user_data_timestamp"
        result = get_user_data_timestamp(config)
        println(JSON3.pretty(JSON3.write(result)))

    elseif cmd == "fee_changes"
        series = ""
        for arg in ARGS[2:end]
            if startswith(arg, "--series_ticker=")
                series = split(arg, "=", limit=2)[2]
            end
        end
        result = get_fee_changes(config; series_ticker=series)
        println(JSON3.pretty(JSON3.write(result)))

    else
        println("Unknown command: $cmd")
        println("Run without arguments for usage info.")
    end
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end

#!/usr/bin/env julia
"""
    Kalshi Search, Structured Targets & Series API Scripts

Endpoints:
  GET /search/tags_by_categories                    - Tags organized by series categories
  GET /search/filters_by_sport                      - Filters available by sport
  GET /structured_targets                           - List structured targets
  GET /structured_targets/{structured_target_id}    - Get specific structured target
  GET /series/{series_ticker}                       - Get series information

Usage:
  julia --project=. scripts/kalshi_search.jl tags
  julia --project=. scripts/kalshi_search.jl sport_filters
  julia --project=. scripts/kalshi_search.jl targets [--limit=20]
  julia --project=. scripts/kalshi_search.jl target TARGET_ID
  julia --project=. scripts/kalshi_search.jl series SERIES_TICKER
"""

include(joinpath(@__DIR__, "..", "src", "KalshiAuth.jl"))
using .KalshiAuth
using JSON3

# =============================================================================
# Search & Discovery Endpoints
# =============================================================================

"""
    get_tags_by_categories(config) -> response

Get tags organized by series categories.
Useful for discovering what types of markets are available.
"""
function get_tags_by_categories(config::KalshiConfig)
    return kalshi_get(config, "/search/tags_by_categories")
end

"""
    get_filters_by_sport(config) -> response

Get available filters organized by sport.
Useful for sports-related market discovery.
"""
function get_filters_by_sport(config::KalshiConfig)
    return kalshi_get(config, "/search/filters_by_sport")
end

# =============================================================================
# Structured Targets
# =============================================================================

"""
    list_structured_targets(config; limit, cursor) -> response

List structured targets with optional filtering.
"""
function list_structured_targets(config::KalshiConfig;
    limit::Int = 20,
    cursor::String = ""
)
    params = Dict{String,Any}("limit" => limit)
    !isempty(cursor) && (params["cursor"] = cursor)
    return kalshi_get(config, "/structured_targets"; params)
end

"""
    get_structured_target(config, target_id) -> response

Get a specific structured target.
"""
function get_structured_target(config::KalshiConfig, target_id::String)
    return kalshi_get(config, "/structured_targets/$target_id")
end

# =============================================================================
# Series
# =============================================================================

"""
    get_series(config, series_ticker) -> response

Get information about a series (group of related markets).
"""
function get_series(config::KalshiConfig, series_ticker::String)
    return kalshi_get(config, "/series/$series_ticker")
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
        Usage: julia --project=. scripts/kalshi_search.jl <command> [options]

        Commands:
          tags                     Tags by series categories
          sport_filters            Filters by sport
          targets                  List structured targets
          target TARGET_ID         Get specific structured target
          series SERIES_TICKER     Get series information

        Options:
          --limit=N                Results per page
          --demo / --live          Environment
          --verbose                Debug output
        """)
        return
    end

    demo = !("--live" in ARGS)
    verbose = "--verbose" in ARGS
    config = load_config(; demo, verbose)

    cmd = ARGS[1]
    rest = filter(a -> !startswith(a, "--"), ARGS[2:end])

    if cmd == "tags"
        result = get_tags_by_categories(config)
        println(JSON3.pretty(JSON3.write(result)))

    elseif cmd == "sport_filters"
        result = get_filters_by_sport(config)
        println(JSON3.pretty(JSON3.write(result)))

    elseif cmd == "targets"
        result = list_structured_targets(config;
            limit = something(parse_int_arg(ARGS, "limit"), 20))
        println(JSON3.pretty(JSON3.write(result)))

    elseif cmd == "target"
        target_id = isempty(rest) ? error("Target ID required") : rest[1]
        result = get_structured_target(config, target_id)
        println(JSON3.pretty(JSON3.write(result)))

    elseif cmd == "series"
        ticker = isempty(rest) ? error("Series ticker required") : rest[1]
        result = get_series(config, ticker)
        println(JSON3.pretty(JSON3.write(result)))

    else
        println("Unknown command: $cmd")
    end
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end

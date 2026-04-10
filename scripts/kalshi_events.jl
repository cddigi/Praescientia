#!/usr/bin/env julia
"""
    Kalshi Events API Scripts

Endpoints:
  GET /events                                                             - List standard events
  GET /events/multivariate                                                - Multivariate combo events
  GET /events/{event_ticker}                                              - Specific event
  GET /events/{event_ticker}/metadata                                     - Event metadata
  GET /series/{series_ticker}/events/{ticker}/candlesticks                - Event candlesticks
  GET /series/{series_ticker}/events/{ticker}/forecast_percentile_history - Forecast percentile history
  GET /multivariate_event_collections/{collection_ticker}                 - Multivariate collection

Usage:
  julia --project=. scripts/kalshi_events.jl list [--status=open] [--series_ticker=S] [--limit=20]
  julia --project=. scripts/kalshi_events.jl multivariate [--limit=20]
  julia --project=. scripts/kalshi_events.jl get EVENT_TICKER [--with_nested_markets]
  julia --project=. scripts/kalshi_events.jl metadata EVENT_TICKER
  julia --project=. scripts/kalshi_events.jl candlesticks SERIES_TICKER EVENT_TICKER [--period_interval=1]
  julia --project=. scripts/kalshi_events.jl forecast SERIES_TICKER EVENT_TICKER
  julia --project=. scripts/kalshi_events.jl collection COLLECTION_TICKER
"""

include(joinpath(@__DIR__, "..", "src", "KalshiAuth.jl"))
using .KalshiAuth
using JSON3

# =============================================================================
# Events Endpoints
# =============================================================================

"""
    list_events(config; status, series_ticker, limit, cursor, with_nested_markets) -> response

List all standard events with optional filters.
"""
function list_events(config::KalshiConfig;
    status::String = "",
    series_ticker::String = "",
    limit::Int = 20,
    cursor::String = "",
    with_nested_markets::Bool = false
)
    params = Dict{String,Any}("limit" => limit)
    !isempty(status) && (params["status"] = status)
    !isempty(series_ticker) && (params["series_ticker"] = series_ticker)
    !isempty(cursor) && (params["cursor"] = cursor)
    with_nested_markets && (params["with_nested_markets"] = "true")
    return kalshi_get(config, "/events"; params)
end

"""
    list_multivariate_events(config; limit, cursor) -> response

Get dynamically created multivariate combo events.
"""
function list_multivariate_events(config::KalshiConfig;
    limit::Int = 20,
    cursor::String = ""
)
    params = Dict{String,Any}("limit" => limit)
    !isempty(cursor) && (params["cursor"] = cursor)
    return kalshi_get(config, "/events/multivariate"; params)
end

"""
    get_event(config, event_ticker; with_nested_markets) -> response

Get specific event data, optionally with nested markets.
"""
function get_event(config::KalshiConfig, event_ticker::String;
    with_nested_markets::Bool = false
)
    params = Dict{String,Any}()
    with_nested_markets && (params["with_nested_markets"] = "true")
    return kalshi_get(config, "/events/$event_ticker"; params)
end

"""
    get_event_metadata(config, event_ticker) -> response

Get metadata for a specific event.
"""
function get_event_metadata(config::KalshiConfig, event_ticker::String)
    return kalshi_get(config, "/events/$event_ticker/metadata")
end

"""
    get_event_candlesticks(config, series_ticker, event_ticker; period_interval, start_ts, end_ts) -> response

Get aggregated candlesticks for an event.
"""
function get_event_candlesticks(config::KalshiConfig, series_ticker::String, event_ticker::String;
    period_interval::Int = 1,
    start_ts::Union{Int,Nothing} = nothing,
    end_ts::Union{Int,Nothing} = nothing
)
    params = Dict{String,Any}("period_interval" => period_interval)
    start_ts !== nothing && (params["start_ts"] = start_ts)
    end_ts !== nothing && (params["end_ts"] = end_ts)
    return kalshi_get(config, "/series/$series_ticker/events/$event_ticker/candlesticks"; params)
end

"""
    get_forecast_percentile_history(config, series_ticker, event_ticker) -> response

Get forecast percentile history for an event.
"""
function get_forecast_percentile_history(config::KalshiConfig, series_ticker::String, event_ticker::String)
    return kalshi_get(config, "/series/$series_ticker/events/$event_ticker/forecast_percentile_history")
end

"""
    get_multivariate_collection(config, collection_ticker) -> response

Get a multivariate event collection.
"""
function get_multivariate_collection(config::KalshiConfig, collection_ticker::String)
    return kalshi_get(config, "/multivariate_event_collections/$collection_ticker")
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
        Usage: julia --project=. scripts/kalshi_events.jl <command> [options]

        Commands:
          list                                       List standard events
          multivariate                               List multivariate combo events
          get EVENT_TICKER                           Get specific event
          metadata EVENT_TICKER                      Get event metadata
          candlesticks SERIES_TICKER EVENT_TICKER    Event candlesticks
          forecast SERIES_TICKER EVENT_TICKER        Forecast percentile history
          collection COLLECTION_TICKER               Multivariate collection

        Options:
          --status=STATUS              Filter by status
          --series_ticker=SERIES       Filter by series
          --with_nested_markets        Include nested markets
          --period_interval=N          Candle period in minutes
          --start_ts=EPOCH             Start timestamp
          --end_ts=EPOCH               End timestamp
          --limit=N                    Results per page
          --demo / --live              Environment
          --verbose                    Debug output
        """)
        return
    end

    demo = !("--live" in ARGS)
    verbose = "--verbose" in ARGS
    config = load_config(; demo, verbose)

    cmd = ARGS[1]
    rest = filter(a -> !startswith(a, "--"), ARGS[2:end])

    if cmd == "list"
        result = list_events(config;
            status = parse_arg(ARGS, "status"),
            series_ticker = parse_arg(ARGS, "series_ticker"),
            limit = something(parse_int_arg(ARGS, "limit"), 20),
            with_nested_markets = "--with_nested_markets" in ARGS)
        println(JSON3.pretty(JSON3.write(result)))

    elseif cmd == "multivariate"
        result = list_multivariate_events(config;
            limit = something(parse_int_arg(ARGS, "limit"), 20))
        println(JSON3.pretty(JSON3.write(result)))

    elseif cmd == "get"
        ticker = isempty(rest) ? error("Event ticker required") : rest[1]
        result = get_event(config, ticker;
            with_nested_markets = "--with_nested_markets" in ARGS)
        println(JSON3.pretty(JSON3.write(result)))

    elseif cmd == "metadata"
        ticker = isempty(rest) ? error("Event ticker required") : rest[1]
        result = get_event_metadata(config, ticker)
        println(JSON3.pretty(JSON3.write(result)))

    elseif cmd == "candlesticks"
        length(rest) < 2 && error("Usage: candlesticks SERIES_TICKER EVENT_TICKER")
        result = get_event_candlesticks(config, rest[1], rest[2];
            period_interval = something(parse_int_arg(ARGS, "period_interval"), 1),
            start_ts = parse_int_arg(ARGS, "start_ts"),
            end_ts = parse_int_arg(ARGS, "end_ts"))
        println(JSON3.pretty(JSON3.write(result)))

    elseif cmd == "forecast"
        length(rest) < 2 && error("Usage: forecast SERIES_TICKER EVENT_TICKER")
        result = get_forecast_percentile_history(config, rest[1], rest[2])
        println(JSON3.pretty(JSON3.write(result)))

    elseif cmd == "collection"
        ticker = isempty(rest) ? error("Collection ticker required") : rest[1]
        result = get_multivariate_collection(config, ticker)
        println(JSON3.pretty(JSON3.write(result)))

    else
        println("Unknown command: $cmd")
    end
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end

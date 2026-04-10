#!/usr/bin/env julia
"""
    Kalshi Historical Data API Scripts

Endpoints:
  GET /historical/cutoff                              - Cutoff timestamps between live/historical
  GET /historical/markets/{ticker}/candlesticks        - Archived candlestick data
  GET /historical/fills                                - Historical fills (authenticated)
  GET /historical/orders                               - Archived orders (authenticated)
  GET /historical/trades                               - All historical trades
  GET /historical/markets                              - Archived markets list
  GET /historical/markets/{ticker}                     - Specific historical market

Usage:
  julia --project=. scripts/kalshi_historical.jl cutoff
  julia --project=. scripts/kalshi_historical.jl candlesticks TICKER [--period_interval=1] [--start_ts=EPOCH] [--end_ts=EPOCH]
  julia --project=. scripts/kalshi_historical.jl fills [--ticker=TICKER] [--limit=100]
  julia --project=. scripts/kalshi_historical.jl orders [--ticker=TICKER] [--limit=100]
  julia --project=. scripts/kalshi_historical.jl trades [--ticker=TICKER] [--limit=100]
  julia --project=. scripts/kalshi_historical.jl markets [--status=STATUS] [--series_ticker=SERIES] [--limit=100]
  julia --project=. scripts/kalshi_historical.jl market TICKER
"""

include(joinpath(@__DIR__, "..", "src", "KalshiAuth.jl"))
using .KalshiAuth
using JSON3

# =============================================================================
# Historical Endpoints
# =============================================================================

"""
    get_historical_cutoff(config) -> response

Get cutoff timestamps between live and historical data.
Markets/trades/orders before these timestamps must use /historical/* endpoints.
"""
function get_historical_cutoff(config::KalshiConfig)
    return kalshi_get(config, "/historical/cutoff")
end

"""
    get_historical_candlesticks(config, ticker; period_interval, start_ts, end_ts) -> response

Fetch archived candlestick data for a market ticker.

Parameters:
  - ticker:          Market ticker (required)
  - period_interval: Candle period in minutes (default: 1)
  - start_ts:        Start timestamp (epoch seconds)
  - end_ts:          End timestamp (epoch seconds)
"""
function get_historical_candlesticks(config::KalshiConfig, ticker::String;
    period_interval::Int = 1,
    start_ts::Union{Int,Nothing} = nothing,
    end_ts::Union{Int,Nothing} = nothing
)
    params = Dict{String,Any}("period_interval" => period_interval)
    if start_ts !== nothing
        params["start_ts"] = start_ts
    end
    if end_ts !== nothing
        params["end_ts"] = end_ts
    end
    return kalshi_get(config, "/historical/markets/$ticker/candlesticks"; params)
end

"""
    get_historical_fills(config; ticker, order_id, min_ts, max_ts, limit, cursor) -> response

Get historical fills for the authenticated user.
"""
function get_historical_fills(config::KalshiConfig;
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
    return kalshi_get(config, "/historical/fills"; params)
end

"""
    get_historical_orders(config; ticker, status, min_ts, max_ts, limit, cursor) -> response

Get archived orders from the historical database.
"""
function get_historical_orders(config::KalshiConfig;
    ticker::String = "",
    status::String = "",
    min_ts::Union{Int,Nothing} = nothing,
    max_ts::Union{Int,Nothing} = nothing,
    limit::Int = 100,
    cursor::String = ""
)
    params = Dict{String,Any}("limit" => limit)
    !isempty(ticker) && (params["ticker"] = ticker)
    !isempty(status) && (params["status"] = status)
    min_ts !== nothing && (params["min_ts"] = min_ts)
    max_ts !== nothing && (params["max_ts"] = max_ts)
    !isempty(cursor) && (params["cursor"] = cursor)
    return kalshi_get(config, "/historical/orders"; params)
end

"""
    get_historical_trades(config; ticker, min_ts, max_ts, limit, cursor) -> response

Get all historical trades across markets.
"""
function get_historical_trades(config::KalshiConfig;
    ticker::String = "",
    min_ts::Union{Int,Nothing} = nothing,
    max_ts::Union{Int,Nothing} = nothing,
    limit::Int = 100,
    cursor::String = ""
)
    params = Dict{String,Any}("limit" => limit)
    !isempty(ticker) && (params["ticker"] = ticker)
    min_ts !== nothing && (params["min_ts"] = min_ts)
    max_ts !== nothing && (params["max_ts"] = max_ts)
    !isempty(cursor) && (params["cursor"] = cursor)
    return kalshi_get(config, "/historical/trades"; params)
end

"""
    get_historical_markets(config; status, series_ticker, limit, cursor) -> response

List archived markets with optional filters.
"""
function get_historical_markets(config::KalshiConfig;
    status::String = "",
    series_ticker::String = "",
    limit::Int = 100,
    cursor::String = ""
)
    params = Dict{String,Any}("limit" => limit)
    !isempty(status) && (params["status"] = status)
    !isempty(series_ticker) && (params["series_ticker"] = series_ticker)
    !isempty(cursor) && (params["cursor"] = cursor)
    return kalshi_get(config, "/historical/markets"; params)
end

"""
    get_historical_market(config, ticker) -> response

Get specific historical market data by ticker.
"""
function get_historical_market(config::KalshiConfig, ticker::String)
    return kalshi_get(config, "/historical/markets/$ticker")
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
        Usage: julia --project=. scripts/kalshi_historical.jl <command> [options]

        Commands:
          cutoff                          Cutoff timestamps
          candlesticks TICKER             Archived candlestick data
          fills                           Historical fills (auth required)
          orders                          Archived orders (auth required)
          trades                          Historical trades
          markets                         List archived markets
          market TICKER                   Specific historical market

        Options:
          --ticker=TICKER          Filter by ticker
          --series_ticker=SERIES   Filter by series
          --status=STATUS          Filter by status
          --period_interval=N      Candle period in minutes (default: 1)
          --start_ts=EPOCH         Start timestamp (epoch seconds)
          --end_ts=EPOCH           End timestamp (epoch seconds)
          --limit=N                Results per page (default: 100)
          --demo / --live          Environment (default: demo)
          --verbose                Debug output
        """)
        return
    end

    demo = !("--live" in ARGS)
    verbose = "--verbose" in ARGS
    config = load_config(; demo, verbose)

    cmd = ARGS[1]
    rest = filter(a -> !startswith(a, "--"), ARGS[2:end])

    if cmd == "cutoff"
        result = get_historical_cutoff(config)
        println(JSON3.pretty(JSON3.write(result)))

    elseif cmd == "candlesticks"
        ticker = isempty(rest) ? error("Ticker required") : rest[1]
        result = get_historical_candlesticks(config, ticker;
            period_interval = something(parse_int_arg(ARGS, "period_interval"), 1),
            start_ts = parse_int_arg(ARGS, "start_ts"),
            end_ts = parse_int_arg(ARGS, "end_ts"))
        println(JSON3.pretty(JSON3.write(result)))

    elseif cmd == "fills"
        result = get_historical_fills(config;
            ticker = parse_arg(ARGS, "ticker"),
            limit = something(parse_int_arg(ARGS, "limit"), 100))
        println(JSON3.pretty(JSON3.write(result)))

    elseif cmd == "orders"
        result = get_historical_orders(config;
            ticker = parse_arg(ARGS, "ticker"),
            status = parse_arg(ARGS, "status"),
            limit = something(parse_int_arg(ARGS, "limit"), 100))
        println(JSON3.pretty(JSON3.write(result)))

    elseif cmd == "trades"
        result = get_historical_trades(config;
            ticker = parse_arg(ARGS, "ticker"),
            limit = something(parse_int_arg(ARGS, "limit"), 100))
        println(JSON3.pretty(JSON3.write(result)))

    elseif cmd == "markets"
        result = get_historical_markets(config;
            status = parse_arg(ARGS, "status"),
            series_ticker = parse_arg(ARGS, "series_ticker"),
            limit = something(parse_int_arg(ARGS, "limit"), 100))
        println(JSON3.pretty(JSON3.write(result)))

    elseif cmd == "market"
        ticker = isempty(rest) ? error("Ticker required") : rest[1]
        result = get_historical_market(config, ticker)
        println(JSON3.pretty(JSON3.write(result)))

    else
        println("Unknown command: $cmd")
    end
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end

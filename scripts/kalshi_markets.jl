#!/usr/bin/env julia
"""
    Kalshi Markets & Trading Data API Scripts

Endpoints:
  GET /markets                                                  - List markets (public)
  GET /markets/{ticker}                                         - Get specific market
  GET /markets/trades                                           - Paginated trades across markets
  GET /series/{series_ticker}/markets/{ticker}/candlesticks     - Live market candlesticks
  GET /markets/{ticker}/orderbook                               - Order book for a market
  GET /markets/orderbooks                                       - Order books for multiple markets

Usage:
  julia --project=. scripts/kalshi_markets.jl list [--series_ticker=S] [--status=open] [--limit=20]
  julia --project=. scripts/kalshi_markets.jl get TICKER
  julia --project=. scripts/kalshi_markets.jl trades [--ticker=TICKER] [--limit=100]
  julia --project=. scripts/kalshi_markets.jl candlesticks SERIES_TICKER MARKET_TICKER [--period_interval=1]
  julia --project=. scripts/kalshi_markets.jl orderbook TICKER
  julia --project=. scripts/kalshi_markets.jl orderbooks TICKER1,TICKER2,...
"""

include(joinpath(@__DIR__, "..", "src", "KalshiAuth.jl"))
using .KalshiAuth
using JSON3

# =============================================================================
# Markets Endpoints
# =============================================================================

"""
    list_markets(config; series_ticker, status, event_ticker, limit, cursor) -> response

List markets with optional filters. Public endpoint.
"""
function list_markets(config::KalshiConfig;
    series_ticker::String = "",
    status::String = "",
    event_ticker::String = "",
    limit::Int = 20,
    cursor::String = ""
)
    params = Dict{String,Any}("limit" => limit)
    !isempty(series_ticker) && (params["series_ticker"] = series_ticker)
    !isempty(status) && (params["status"] = status)
    !isempty(event_ticker) && (params["event_ticker"] = event_ticker)
    !isempty(cursor) && (params["cursor"] = cursor)
    return kalshi_get(config, "/markets"; params)
end

"""
    get_market(config, ticker) -> response

Get details for a specific market by ticker.
"""
function get_market(config::KalshiConfig, ticker::String)
    return kalshi_get(config, "/markets/$ticker")
end

"""
    get_trades(config; ticker, limit, cursor, min_ts, max_ts) -> response

Get paginated trades across all markets.
"""
function get_trades(config::KalshiConfig;
    ticker::String = "",
    limit::Int = 100,
    cursor::String = "",
    min_ts::Union{Int,Nothing} = nothing,
    max_ts::Union{Int,Nothing} = nothing
)
    params = Dict{String,Any}("limit" => limit)
    !isempty(ticker) && (params["ticker"] = ticker)
    !isempty(cursor) && (params["cursor"] = cursor)
    min_ts !== nothing && (params["min_ts"] = min_ts)
    max_ts !== nothing && (params["max_ts"] = max_ts)
    return kalshi_get(config, "/markets/trades"; params)
end

"""
    get_candlesticks(config, series_ticker, market_ticker; period_interval, start_ts, end_ts) -> response

Fetch candlestick data for a live market.
"""
function get_candlesticks(config::KalshiConfig, series_ticker::String, market_ticker::String;
    period_interval::Int = 1,
    start_ts::Union{Int,Nothing} = nothing,
    end_ts::Union{Int,Nothing} = nothing
)
    params = Dict{String,Any}("period_interval" => period_interval)
    start_ts !== nothing && (params["start_ts"] = start_ts)
    end_ts !== nothing && (params["end_ts"] = end_ts)
    return kalshi_get(config, "/series/$series_ticker/markets/$market_ticker/candlesticks"; params)
end

"""
    get_orderbook(config, ticker) -> response

Get the current order book for a market.
Returns yes and no bids (asks are implicit due to YES/NO reciprocal relationship).
"""
function get_orderbook(config::KalshiConfig, ticker::String)
    return kalshi_get(config, "/markets/$ticker/orderbook")
end

"""
    get_orderbooks(config, tickers::Vector{String}) -> response

Get order books for multiple markets in a single request.
"""
function get_orderbooks(config::KalshiConfig, tickers::Vector{String})
    params = Dict{String,Any}("tickers" => join(tickers, ","))
    return kalshi_get(config, "/markets/orderbooks"; params)
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
        Usage: julia --project=. scripts/kalshi_markets.jl <command> [options]

        Commands:
          list                                    List markets
          get TICKER                              Get specific market
          trades                                  Paginated trades
          candlesticks SERIES_TICKER MARKET_TICKER  Live candlesticks
          orderbook TICKER                        Order book
          orderbooks TICKER1,TICKER2,...           Multiple order books

        Options:
          --series_ticker=SERIES   Filter by series
          --event_ticker=EVENT     Filter by event
          --ticker=TICKER          Filter trades by ticker
          --status=STATUS          Filter by status (open, closed, settled)
          --period_interval=N      Candle period in minutes
          --start_ts=EPOCH         Start timestamp
          --end_ts=EPOCH           End timestamp
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

    if cmd == "list"
        result = list_markets(config;
            series_ticker = parse_arg(ARGS, "series_ticker"),
            status = parse_arg(ARGS, "status"),
            event_ticker = parse_arg(ARGS, "event_ticker"),
            limit = something(parse_int_arg(ARGS, "limit"), 20))
        println(JSON3.pretty(JSON3.write(result)))

    elseif cmd == "get"
        ticker = isempty(rest) ? error("Ticker required") : rest[1]
        result = get_market(config, ticker)
        println(JSON3.pretty(JSON3.write(result)))

    elseif cmd == "trades"
        result = get_trades(config;
            ticker = parse_arg(ARGS, "ticker"),
            limit = something(parse_int_arg(ARGS, "limit"), 100))
        println(JSON3.pretty(JSON3.write(result)))

    elseif cmd == "candlesticks"
        length(rest) < 2 && error("Usage: candlesticks SERIES_TICKER MARKET_TICKER")
        result = get_candlesticks(config, rest[1], rest[2];
            period_interval = something(parse_int_arg(ARGS, "period_interval"), 1),
            start_ts = parse_int_arg(ARGS, "start_ts"),
            end_ts = parse_int_arg(ARGS, "end_ts"))
        println(JSON3.pretty(JSON3.write(result)))

    elseif cmd == "orderbook"
        ticker = isempty(rest) ? error("Ticker required") : rest[1]
        result = get_orderbook(config, ticker)
        println(JSON3.pretty(JSON3.write(result)))

    elseif cmd == "orderbooks"
        isempty(rest) && error("Tickers required (comma-separated)")
        tickers = split(rest[1], ",")
        result = get_orderbooks(config, String.(tickers))
        println(JSON3.pretty(JSON3.write(result)))

    else
        println("Unknown command: $cmd")
    end
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end

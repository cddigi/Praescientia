#!/usr/bin/env julia
#=
=====================================================================
PRAESCIENTIA - RESOLVED MARKET DATA POLLER
=====================================================================
Fetches resolved Polymarket market data and crypto prices for a given
month, then stores results in the data/ directory.

Usage:
    julia --project=. scripts/poll_resolved_markets.jl               # Current month
    julia --project=. scripts/poll_resolved_markets.jl january 2026  # Specific month
    julia --project=. scripts/poll_resolved_markets.jl --all         # All months since Jan 2026

APIs Used:
    - CoinGecko (free, no auth) — crypto price history
    - Polymarket Gamma API (free) — resolved market data
    - Yahoo Finance — SPX historical data

"The cost of incorrect information... I can go up to almost half a
million dollars to get that file to a higher level of correctness."
— Grace Hopper, 1982
=====================================================================
=#

using HTTP
using JSON3
using Dates
using Printf

const COINGECKO_API = "https://api.coingecko.com/api/v3"
const POLYMARKET_GAMMA_API = "https://gamma-api.polymarket.com"
const DATA_DIR = joinpath(@__DIR__, "..", "data")

# =============================================================================
# CoinGecko Historical Prices
# =============================================================================

"""
    fetch_monthly_crypto_prices(year, month)

Fetch daily OHLC prices for BTC, ETH, SOL for the given month.
Returns Dict mapping coin => Vector of (date, open, high, low, close).
"""
function fetch_monthly_crypto_prices(year::Int, month::Int)
    start_date = Date(year, month, 1)
    end_date = min(Date(year, month, daysinmonth(start_date)), today())

    # Unix timestamps
    from_ts = round(Int, datetime2unix(DateTime(start_date)))
    to_ts = round(Int, datetime2unix(DateTime(end_date + Day(1))))

    coins = Dict("bitcoin" => "BTC", "ethereum" => "ETH", "solana" => "SOL")
    result = Dict{String, Vector{NamedTuple}}()

    for (coin_id, symbol) in coins
        try
            url = "$COINGECKO_API/coins/$coin_id/market_chart/range?vs_currency=usd&from=$from_ts&to=$to_ts"
            response = HTTP.get(url, ["Accept" => "application/json"]; readtimeout=15)
            data = JSON3.read(String(response.body))

            prices = []
            for point in data.prices
                ts = point[1] / 1000  # ms to seconds
                dt = Date(unix2datetime(ts))
                price = Float64(point[2])
                push!(prices, (date=dt, price=price))
            end

            result[symbol] = prices
            println("  Fetched $symbol: $(length(prices)) data points")
            sleep(1.5)  # Rate limit (CoinGecko free tier)
        catch e
            @warn "Failed to fetch $symbol prices" exception=e
            result[symbol] = []
        end
    end

    return result
end

"""
    fetch_current_crypto_prices()

Fetch current spot prices for BTC, ETH, SOL.
"""
function fetch_current_crypto_prices()
    url = "$COINGECKO_API/simple/price?ids=bitcoin,ethereum,solana&vs_currencies=usd"
    try
        response = HTTP.get(url, ["Accept" => "application/json"]; readtimeout=10)
        data = JSON3.read(String(response.body))
        return Dict(
            "BTC" => Float64(data.bitcoin.usd),
            "ETH" => Float64(data.ethereum.usd),
            "SOL" => Float64(data.solana.usd)
        )
    catch e
        @warn "Failed to fetch current prices" exception=e
        return Dict("BTC" => 0.0, "ETH" => 0.0, "SOL" => 0.0)
    end
end

# =============================================================================
# Polymarket Resolved Markets
# =============================================================================

"""
    fetch_resolved_markets(; limit=100, offset=0)

Fetch recently resolved markets from Polymarket Gamma API.
"""
function fetch_resolved_markets(; limit::Int=100, offset::Int=0)
    try
        url = "$POLYMARKET_GAMMA_API/markets?limit=$limit&offset=$offset&closed=true&order=volume&ascending=false"
        response = HTTP.get(url, ["Accept" => "application/json"]; readtimeout=15)
        return JSON3.read(String(response.body))
    catch e
        @warn "Failed to fetch resolved markets" exception=e
        return []
    end
end

"""
    fetch_market_by_slug(slug::String)

Fetch a specific market by its slug/ID.
"""
function fetch_market_by_slug(slug::String)
    try
        url = "$POLYMARKET_GAMMA_API/markets?slug=$slug"
        response = HTTP.get(url, ["Accept" => "application/json"]; readtimeout=10)
        data = JSON3.read(String(response.body))
        return isempty(data) ? nothing : data[1]
    catch e
        @warn "Failed to fetch market: $slug" exception=e
        return nothing
    end
end

"""
    fetch_polymarket_odds(search_term::String; closed=false)

Search Polymarket for a market and return current/final odds.
Returns (yes_price, no_price, volume, question).
"""
function fetch_polymarket_odds(search_term::String; closed::Bool=false)
    try
        encoded = HTTP.escapeuri(search_term)
        closed_param = closed ? "true" : "false"
        url = "$POLYMARKET_GAMMA_API/markets?limit=5&closed=$closed_param&_q=$encoded"
        response = HTTP.get(url, ["Accept" => "application/json"]; readtimeout=10)
        data = JSON3.read(String(response.body))

        if isempty(data)
            return (0.0, 0.0, 0, "")
        end

        market = data[1]
        prices_str = get(market, :outcomePrices, "[0.5,0.5]")
        prices = prices_str isa String ? JSON3.read(prices_str) : prices_str

        parse_p(p) = p isa Number ? Float64(p) : p isa String ? parse(Float64, p) : 0.5

        yes_price = length(prices) > 0 ? parse_p(prices[1]) : 0.5
        no_price = length(prices) > 1 ? parse_p(prices[2]) : 1.0 - yes_price
        volume = get(market, :volume, 0)
        question = get(market, :question, "")

        return (yes_price, no_price, volume, question)
    catch e
        @warn "Failed to fetch odds for: $search_term" exception=e
        return (0.0, 0.0, 0, "")
    end
end

# =============================================================================
# Data File Generation
# =============================================================================

"""
    save_resolved_data(filename, metadata, markets)

Save resolved market data to a JSON file in data/.
"""
function save_resolved_data(filename::String, metadata::Dict, markets::Vector)
    path = joinpath(DATA_DIR, filename)

    data = Dict(
        "metadata" => metadata,
        "markets" => markets
    )

    open(path, "w") do f
        JSON3.pretty(f, data; allow_inf=true)
    end

    println("Saved: $path ($(length(markets)) markets)")
    return path
end

"""
    load_resolved_data(filename)

Load existing resolved market data.
"""
function load_resolved_data(filename::String)
    path = joinpath(DATA_DIR, filename)
    if !isfile(path)
        return nothing
    end
    return JSON3.read(read(path, String))
end

# =============================================================================
# Contrarian Portfolio Tracker
# =============================================================================

"""
    poll_contrarian_odds()

Fetch current odds for all contrarian portfolio positions.
Returns dict of position_id => (yes_price, no_price, volume).
"""
function poll_contrarian_odds()
    println("Polling contrarian portfolio odds...")

    odds = Dict{String, NamedTuple}()

    searches = [
        ("c1", "US recession 2026"),
        ("c2", "Fed rate hike 2026"),
        ("c3", "Fed emergency rate cut 2027")
    ]

    for (id, term) in searches
        (yes, no, vol, q) = fetch_polymarket_odds(term)
        odds[id] = (yes=yes, no=no, volume=vol, question=q)
        @printf("  %s: YES=%.3f NO=%.3f (vol: \$%s)\n", id, yes, no, format_volume(vol))
        sleep(0.5)
    end

    return odds
end

function format_volume(v)
    if v >= 1_000_000
        return @sprintf("%.1fM", v / 1_000_000)
    elseif v >= 1_000
        return @sprintf("%.1fK", v / 1_000)
    else
        return string(round(Int, v))
    end
end

# =============================================================================
# Main Entry Point
# =============================================================================

function main()
    println()
    println("╔══════════════════════════════════════════════════════════════════════╗")
    println("║  PRAESCIENTIA - RESOLVED MARKET DATA POLLER                         ║")
    println("║  $(Dates.format(now(), "yyyy-mm-dd HH:MM:SS"))                                          ║")
    println("╚══════════════════════════════════════════════════════════════════════╝")

    # Parse arguments
    if "--all" in ARGS
        # Poll all months from Jan 2026 to current
        start_month = Date(2026, 1, 1)
        current = today()
        month = start_month
        while month <= current
            poll_month(year(month), Dates.month(month))
            month += Month(1)
        end
    elseif length(ARGS) >= 2
        month_str = lowercase(ARGS[1])
        year = parse(Int, ARGS[2])
        month_names = Dict(
            "january" => 1, "february" => 2, "march" => 3,
            "april" => 4, "may" => 5, "june" => 6,
            "july" => 7, "august" => 8, "september" => 9,
            "october" => 10, "november" => 11, "december" => 12,
            "jan" => 1, "feb" => 2, "mar" => 3, "apr" => 4,
            "jun" => 6, "jul" => 7, "aug" => 8, "sep" => 9,
            "oct" => 10, "nov" => 11, "dec" => 12
        )
        m = get(month_names, month_str, nothing)
        if m === nothing
            m = tryparse(Int, month_str)
        end
        if m === nothing || m < 1 || m > 12
            println("Error: Invalid month '$month_str'")
            return
        end
        poll_month(year, m)
    else
        # Default: current month
        poll_month(year(today()), Dates.month(today()))
    end

    # Always poll contrarian odds
    println("\n" * "─" ^ 60)
    odds = poll_contrarian_odds()

    # Fetch current prices
    println("\nFetching current crypto prices...")
    prices = fetch_current_crypto_prices()
    for (sym, price) in sort(collect(prices))
        @printf("  %s: \$%.2f\n", sym, price)
    end

    println("\n" * "─" ^ 60)
    println("Grace Hopper's Calculus: Know the cost of being wrong.")
    println("─" ^ 60)
end

function poll_month(year::Int, month::Int)
    month_name = Dates.monthname(month)
    println("\n── Polling $month_name $year ──")

    # Fetch crypto prices for the month
    println("Fetching crypto prices...")
    prices = fetch_monthly_crypto_prices(year, month)

    # Fetch resolved Polymarket markets
    println("Fetching resolved Polymarket markets...")
    resolved = fetch_resolved_markets(limit=50)

    # Filter to this month
    month_start = Date(year, month, 1)
    month_end = Date(year, month, daysinmonth(month_start))

    relevant = filter(resolved) do m
        end_date_str = get(m, :endDate, nothing)
        if end_date_str === nothing
            return false
        end
        try
            end_date = Date(end_date_str[1:10])
            return month_start <= end_date <= month_end
        catch
            return false
        end
    end

    println("Found $(length(relevant)) markets resolved in $month_name $year")

    # Summarize
    for m in relevant
        q = get(m, :question, "?")
        vol = get(m, :volume, 0)
        short_q = length(q) > 50 ? q[1:50] * "..." : q
        @printf("  • %s (vol: \$%s)\n", short_q, format_volume(vol))
    end
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end

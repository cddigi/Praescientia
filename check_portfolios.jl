#!/usr/bin/env julia
#=
=====================================================================
PRAESCIENTIA - PORTFOLIO CHECKER
=====================================================================
Quickly check on active and resolved wagers across all portfolios.

Usage:
    julia check_portfolios.jl           # Check all portfolios
    julia check_portfolios.jl daily     # Check daily portfolio only
    julia check_portfolios.jl weekly    # Check weekly portfolio only
    julia check_portfolios.jl contrarian # Check contrarian portfolio only

"I now know economically: I can go up to almost half a million dollars
to get that file to a higher level of correctness, because that's what
I stand to lose." — Grace Hopper, 1982
=====================================================================
=#

using HTTP
using JSON3
using Dates
using Printf

# =============================================================================
# Price Fetching (CoinGecko - free, no API key required)
# =============================================================================

const COINGECKO_API = "https://api.coingecko.com/api/v3"

"""
    fetch_crypto_prices()

Fetch current prices for BTC, ETH, SOL from CoinGecko.
Returns a Dict with symbol => price.
"""
function fetch_crypto_prices()
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
        @warn "Failed to fetch crypto prices" exception=e
        return Dict("BTC" => 0.0, "ETH" => 0.0, "SOL" => 0.0)
    end
end

"""
    fetch_spx_price()

Fetch current S&P 500 price. Uses Yahoo Finance via a simple endpoint.
"""
function fetch_spx_price()
    # Use a lightweight endpoint for SPX
    try
        # Try to get from a public source
        url = "https://query1.finance.yahoo.com/v8/finance/chart/%5EGSPC?interval=1d&range=1d"
        response = HTTP.get(url, ["Accept" => "application/json", "User-Agent" => "Mozilla/5.0"]; readtimeout=10)
        data = JSON3.read(String(response.body))

        price = data.chart.result[1].meta.regularMarketPrice
        return Float64(price)
    catch e
        @warn "Failed to fetch SPX price" exception=e
        return 0.0
    end
end

# =============================================================================
# Portfolio Data Structures
# =============================================================================

struct Position
    market::String
    direction::String      # "YES", "NO", "UP", "DOWN"
    entry_price::Float64
    shares::Int
    cost::Float64
    target::Union{Nothing, Float64}  # Target price for threshold markets
    resolution_date::Date
    portfolio::String
end

struct PositionResult
    position::Position
    current_price::Float64
    status::Symbol         # :pending, :won, :lost, :unknown
    pnl::Float64
    notes::String
end

# =============================================================================
# Portfolio Parsing
# =============================================================================

"""
    parse_daily_portfolio(path::String)

Parse the daily portfolio markdown file.
"""
function parse_daily_portfolio(path::String)
    if !isfile(path)
        return Position[]
    end

    positions = Position[]
    content = read(path, String)
    lines = split(content, "\n")

    # Find positions table
    in_table = false
    for line in lines
        if startswith(line, "| #") && contains(line, "Market")
            in_table = true
            continue
        end

        if in_table && startswith(line, "|:-:")
            continue
        end

        if in_table && startswith(line, "| ")
            parts = split(line, "|")
            if length(parts) >= 8
                try
                    market = strip(parts[3])
                    direction = strip(replace(parts[4], "*" => ""))
                    entry_str = strip(replace(parts[5], "\$" => ""))
                    shares = parse(Int, strip(parts[6]))
                    cost_str = strip(replace(parts[7], "\$" => ""))

                    entry_price = parse(Float64, entry_str)
                    cost = parse(Float64, cost_str)

                    push!(positions, Position(
                        market,
                        direction,
                        entry_price,
                        shares,
                        cost,
                        nothing,
                        Date(2026, 1, 7),  # Daily resolution
                        "daily"
                    ))
                catch e
                    # Skip malformed lines
                end
            end
        end

        if in_table && !startswith(line, "|")
            in_table = false
        end
    end

    return positions
end

"""
    parse_weekly_portfolio(path::String)

Parse the weekly portfolio markdown file.
"""
function parse_weekly_portfolio(path::String)
    if !isfile(path)
        return Position[]
    end

    positions = Position[]
    content = read(path, String)
    lines = split(content, "\n")

    in_table = false
    for line in lines
        if startswith(line, "| #") && contains(line, "Market")
            in_table = true
            continue
        end

        if in_table && startswith(line, "|:-:")
            continue
        end

        if in_table && startswith(line, "| ")
            parts = split(line, "|")
            if length(parts) >= 8
                try
                    market = strip(parts[3])
                    direction = strip(replace(parts[4], "*" => ""))
                    entry_str = strip(replace(parts[5], "\$" => ""))
                    shares = parse(Int, strip(parts[6]))
                    cost_str = strip(replace(parts[7], "\$" => ""))

                    entry_price = parse(Float64, entry_str)
                    cost = parse(Float64, cost_str)

                    # Extract target price from market name
                    target = nothing
                    if contains(lowercase(market), "\$100k")
                        target = 100000.0
                    elseif contains(lowercase(market), "\$3,000") || contains(lowercase(market), "\$3k")
                        target = 3000.0
                    elseif contains(lowercase(market), "\$88k")
                        target = 88000.0
                    elseif contains(lowercase(market), "\$3,400")
                        target = 3400.0
                    elseif contains(lowercase(market), "\$96k")
                        target = 96000.0
                    elseif contains(lowercase(market), "\$150")
                        target = 150.0
                    end

                    push!(positions, Position(
                        market,
                        direction,
                        entry_price,
                        shares,
                        cost,
                        target,
                        Date(2026, 1, 12),  # Weekly resolution
                        "weekly"
                    ))
                catch e
                    # Skip malformed lines
                end
            end
        end

        if in_table && !startswith(line, "|")
            in_table = false
        end
    end

    return positions
end

"""
    parse_contrarian_portfolio(path::String)

Parse the contrarian portfolio markdown file.
"""
function parse_contrarian_portfolio(path::String)
    if !isfile(path)
        return Position[]
    end

    positions = Position[]
    content = read(path, String)
    lines = split(content, "\n")

    in_table = false
    for line in lines
        if startswith(line, "| #") && contains(line, "Market")
            in_table = true
            continue
        end

        if in_table && startswith(line, "|:-:")
            continue
        end

        if in_table && startswith(line, "| ")
            parts = split(line, "|")
            if length(parts) >= 8
                try
                    market = strip(parts[3])
                    direction = strip(replace(parts[4], "*" => ""))
                    entry_str = strip(replace(parts[5], "\$" => ""))
                    shares = parse(Int, strip(parts[6]))
                    cost_str = strip(replace(parts[7], "\$" => ""))

                    entry_price = parse(Float64, entry_str)
                    cost = parse(Float64, cost_str)

                    push!(positions, Position(
                        market,
                        direction,
                        entry_price,
                        shares,
                        cost,
                        nothing,
                        Date(2026, 12, 31),  # Year-end resolution
                        "contrarian"
                    ))
                catch e
                    # Skip malformed lines
                end
            end
        end

        if in_table && !startswith(line, "|")
            in_table = false
        end
    end

    return positions
end

# =============================================================================
# Position Evaluation
# =============================================================================

"""
    evaluate_daily_position(pos::Position, prices::Dict)

Evaluate a daily up/down position.
"""
function evaluate_daily_position(pos::Position, prices::Dict, jan6_prices::Dict)
    symbol = ""
    if contains(uppercase(pos.market), "BTC")
        symbol = "BTC"
    elseif contains(uppercase(pos.market), "ETH")
        symbol = "ETH"
    elseif contains(uppercase(pos.market), "SOL")
        symbol = "SOL"
    elseif contains(uppercase(pos.market), "SPX")
        symbol = "SPX"
    end

    current = get(prices, symbol, 0.0)
    baseline = get(jan6_prices, symbol, 0.0)

    if current == 0.0 || baseline == 0.0
        return PositionResult(pos, current, :unknown, 0.0, "Unable to fetch prices")
    end

    # Determine if market went up or down
    went_up = current > baseline
    predicted_up = uppercase(pos.direction) == "UP"

    # Check if resolved (past resolution date)
    today = Date(now())
    is_resolved = today > pos.resolution_date

    if !is_resolved
        # Still pending - estimate based on current direction
        likely_win = (predicted_up && went_up) || (!predicted_up && !went_up)
        notes = "Pending ($(went_up ? "currently UP" : "currently DOWN") from \$$(round(baseline, digits=2)))"
        return PositionResult(pos, current, :pending, 0.0, notes)
    end

    # Calculate P&L for resolved position
    won = (predicted_up && went_up) || (!predicted_up && !went_up)
    pnl = won ? (pos.shares * 1.0 - pos.cost) : -pos.cost
    status = won ? :won : :lost

    change_pct = round((current - baseline) / baseline * 100, digits=2)
    notes = "$(went_up ? "UP" : "DOWN") $(abs(change_pct))% from \$$(round(baseline, digits=2))"

    return PositionResult(pos, current, status, pnl, notes)
end

"""
    evaluate_weekly_position(pos::Position, prices::Dict)

Evaluate a weekly threshold position (hits X / dips to Y).
"""
function evaluate_weekly_position(pos::Position, prices::Dict)
    symbol = ""
    if contains(uppercase(pos.market), "BTC")
        symbol = "BTC"
    elseif contains(uppercase(pos.market), "ETH")
        symbol = "ETH"
    elseif contains(uppercase(pos.market), "SOL")
        symbol = "SOL"
    end

    current = get(prices, symbol, 0.0)
    target = pos.target

    if current == 0.0 || target === nothing
        return PositionResult(pos, current, :unknown, 0.0, "Unable to evaluate")
    end

    # Determine if this is a "hits" or "dips" market
    is_hits_market = contains(lowercase(pos.market), "hits")
    is_dips_market = contains(lowercase(pos.market), "dip")

    # Check if resolved
    today = Date(now())
    is_resolved = today > pos.resolution_date

    if is_hits_market
        # "Hits $X" - YES wins if price reached target, NO wins if it didn't
        # For now, we can only check current price (not if it hit during the week)
        currently_above = current >= target
        predicted_yes = uppercase(pos.direction) == "YES"

        distance = target - current
        distance_pct = round(distance / current * 100, digits=1)

        if !is_resolved
            if predicted_yes
                notes = currently_above ? "Target HIT! ✓" : "Needs +$(distance_pct)% to hit \$$(Int(target))"
            else
                notes = currently_above ? "Target was hit ✗" : "Safe - $(distance_pct)% below target"
            end
            return PositionResult(pos, current, :pending, 0.0, notes)
        end

        # Resolved - simplified (would need historical data for accurate resolution)
        won = (predicted_yes && currently_above) || (!predicted_yes && !currently_above)
        pnl = won ? (pos.shares * 1.0 - pos.cost) : -pos.cost
        return PositionResult(pos, current, won ? :won : :lost, pnl, "Resolved")

    elseif is_dips_market
        # "Dips to $X" - YES wins if price fell to target, NO wins if it didn't
        currently_below = current <= target
        predicted_no = uppercase(pos.direction) == "NO"

        buffer = current - target
        buffer_pct = round(buffer / current * 100, digits=1)

        if !is_resolved
            if predicted_no
                notes = currently_below ? "Dipped below target ✗" : "Safe - $(buffer_pct)% buffer above \$$(Int(target))"
            else
                notes = currently_below ? "Target reached ✓" : "Needs -$(buffer_pct)% to reach \$$(Int(target))"
            end
            return PositionResult(pos, current, :pending, 0.0, notes)
        end

        won = (predicted_no && !currently_below) || (!predicted_no && currently_below)
        pnl = won ? (pos.shares * 1.0 - pos.cost) : -pos.cost
        return PositionResult(pos, current, won ? :won : :lost, pnl, "Resolved")
    end

    return PositionResult(pos, current, :unknown, 0.0, "Unknown market type")
end

"""
    evaluate_contrarian_position(pos::Position)

Evaluate a contrarian (long-term) position.
"""
function evaluate_contrarian_position(pos::Position)
    # These are event-based, not price-based
    # We can only report their status as pending
    notes = "Long-term position - monitoring"
    return PositionResult(pos, 0.0, :pending, 0.0, notes)
end

# =============================================================================
# Report Generation
# =============================================================================

function status_icon(status::Symbol)
    status == :won && return "✅"
    status == :lost && return "❌"
    status == :pending && return "⏳"
    return "❓"
end

function print_portfolio_report(name::String, results::Vector{PositionResult})
    println()
    println("═" ^ 70)
    println("  $name")
    println("═" ^ 70)

    if isempty(results)
        println("  No positions found.")
        return
    end

    total_cost = 0.0
    total_pnl = 0.0
    won_count = 0
    lost_count = 0
    pending_count = 0

    for r in results
        icon = status_icon(r.status)
        market_short = length(r.position.market) > 35 ? r.position.market[1:35] * "..." : r.position.market

        @printf("  %s %-38s %4s @ \$%.3f\n", icon, market_short, r.position.direction, r.position.entry_price)
        @printf("     Cost: \$%6.2f | Current: \$%9.2f | %s\n", r.position.cost, r.current_price, r.notes)

        if r.status == :won || r.status == :lost
            pnl_str = r.pnl >= 0 ? "+\$$(round(r.pnl, digits=2))" : "-\$$(round(abs(r.pnl), digits=2))"
            @printf("     P&L: %s\n", pnl_str)
        end
        println()

        total_cost += r.position.cost
        total_pnl += r.pnl

        r.status == :won && (won_count += 1)
        r.status == :lost && (lost_count += 1)
        r.status == :pending && (pending_count += 1)
    end

    println("─" ^ 70)
    @printf("  Total Cost: \$%.2f\n", total_cost)

    if won_count + lost_count > 0
        @printf("  Resolved:   %d/%d (%.1f%% win rate)\n",
                won_count, won_count + lost_count,
                100.0 * won_count / (won_count + lost_count))
        @printf("  Total P&L:  %s\$%.2f\n", total_pnl >= 0 ? "+" : "-", abs(total_pnl))
    end

    if pending_count > 0
        @printf("  Pending:    %d positions\n", pending_count)
    end
end

# =============================================================================
# Main Entry Point
# =============================================================================

function main()
    println()
    println("╔══════════════════════════════════════════════════════════════════════╗")
    println("║  PRAESCIENTIA - PORTFOLIO STATUS CHECK                               ║")
    println("║  $(Dates.format(now(), "yyyy-mm-dd HH:MM:SS"))                                          ║")
    println("╚══════════════════════════════════════════════════════════════════════╝")

    # Determine which portfolios to check
    check_all = isempty(ARGS)
    check_daily = check_all || any(x -> lowercase(x) == "daily", ARGS)
    check_weekly = check_all || any(x -> lowercase(x) == "weekly", ARGS)
    check_contrarian = check_all || any(x -> lowercase(x) == "contrarian", ARGS)

    # Fetch current prices
    println("\nFetching current prices...")
    prices = fetch_crypto_prices()
    spx = fetch_spx_price()
    prices["SPX"] = spx

    # Baseline prices for Jan 6 (from portfolio entry)
    jan6_prices = Dict(
        "BTC" => 91000.0,
        "ETH" => 3300.0,
        "SOL" => 139.0,
        "SPX" => 6944.82  # Jan 6 close (record high)
    )

    println("\nCurrent Prices:")
    @printf("  BTC: \$%.2f (vs \$91,000 on Jan 6)\n", prices["BTC"])
    @printf("  ETH: \$%.2f (vs \$3,300 on Jan 6)\n", prices["ETH"])
    @printf("  SOL: \$%.2f (vs \$139 on Jan 6)\n", prices["SOL"])
    if spx > 0
        @printf("  SPX: \$%.2f\n", spx)
    end

    base_path = joinpath(@__DIR__, "portfolios")

    # Daily Portfolio
    if check_daily
        daily_positions = parse_daily_portfolio(joinpath(base_path, "daily_jan7_2026.md"))
        daily_results = [evaluate_daily_position(p, prices, jan6_prices) for p in daily_positions]
        print_portfolio_report("DAILY PORTFOLIO (Jan 7, 2026)", daily_results)
    end

    # Weekly Portfolio
    if check_weekly
        weekly_positions = parse_weekly_portfolio(joinpath(base_path, "week1_jan6-12_2026.md"))
        weekly_results = [evaluate_weekly_position(p, prices) for p in weekly_positions]
        print_portfolio_report("WEEKLY PORTFOLIO (Jan 6-12, 2026)", weekly_results)
    end

    # Contrarian Portfolio
    if check_contrarian
        contrarian_positions = parse_contrarian_portfolio(joinpath(base_path, "contrarian_2026.md"))
        contrarian_results = [evaluate_contrarian_position(p) for p in contrarian_positions]
        print_portfolio_report("CONTRARIAN PORTFOLIO (2026)", contrarian_results)
    end

    println()
    println("─" ^ 70)
    println("Grace Hopper's Calculus: Know the cost of being wrong.")
    println("─" ^ 70)
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end

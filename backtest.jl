#!/usr/bin/env julia
#=
=====================================================================
PRAESCIENTIA - BACKTESTING MODULE
=====================================================================
Latin: praescientia (foreknowledge)

"The cost of incorrect information... I can go up to almost half a
million dollars to get that file to a higher level of correctness,
because that's what I stand to lose."
                                        - Grace Hopper, 1982

This script backtests predictions against actual Polymarket
resolutions to validate our prediction engine.
=====================================================================
=#

include("src/Praescientia.jl")
using .Praescientia
using JSON3
using Dates
using Printf

"""
    BacktestResult

Holds the result of a single backtest prediction.
"""
struct BacktestResult
    market_id::String
    question::String
    predicted_outcome::String
    actual_outcome::String
    predicted_confidence::Float64
    stake::Float64
    pnl::Float64
    correct::Bool
end

"""
    load_resolved_markets(path::String)

Load resolved markets from JSON file.
"""
function load_resolved_markets(path::String)
    data = JSON3.read(read(path, String))
    return data.markets
end

"""
    calculate_pnl(predicted_price::Float64, actual_outcome::Bool, stake::Float64)

Calculate profit/loss for a prediction.
- If we predicted YES at price P and outcome is YES: profit = stake * (1 - P)
- If we predicted YES at price P and outcome is NO: loss = -stake * P
"""
function calculate_pnl(predicted_price::Float64, predicted_yes::Bool, actual_yes::Bool, stake::Float64)
    if predicted_yes
        if actual_yes
            return stake * (1.0 - predicted_price)  # Bought at P, worth 1.0
        else
            return -stake * predicted_price  # Bought at P, worth 0
        end
    else  # Predicted NO
        if actual_yes
            return -stake * (1.0 - predicted_price)  # Sold at P, worth 1.0
        else
            return stake * predicted_price  # Sold at P, worth 0
        end
    end
end

"""
    simulate_prediction(market, confidence::Float64, stake::Float64)

Simulate what our prediction would have been for a given market.
Returns a BacktestResult.
"""
function simulate_prediction(market, predicted_outcome::String, confidence::Float64, stake::Float64)
    # Find actual outcome
    actual_outcome = market.outcome

    # Determine if prediction was correct
    correct = lowercase(predicted_outcome) == lowercase(actual_outcome) ||
              occursin(lowercase(predicted_outcome), lowercase(actual_outcome))

    # Calculate P&L
    pnl = correct ? stake * (1.0 - confidence) : -stake * confidence

    return BacktestResult(
        String(market.id),
        String(market.question),
        predicted_outcome,
        actual_outcome,
        confidence,
        stake,
        pnl,
        correct
    )
end

"""
    run_backtest(markets, predictions::Vector{Tuple{String, String, Float64, Float64}})

Run backtest on a set of predictions.
Each prediction is (market_id, predicted_outcome, confidence, stake).
"""
function run_backtest(markets, predictions::Vector{Tuple{String, String, Float64, Float64}})
    results = BacktestResult[]

    market_dict = Dict(String(m.id) => m for m in markets)

    for (market_id, predicted_outcome, confidence, stake) in predictions
        if haskey(market_dict, market_id)
            result = simulate_prediction(market_dict[market_id], predicted_outcome, confidence, stake)
            push!(results, result)
        else
            @warn "Market not found: $market_id"
        end
    end

    return results
end

"""
    print_backtest_report(results::Vector{BacktestResult}; month::String="")

Print a formatted backtest report.
"""
function print_backtest_report(results::Vector{BacktestResult}; month::String="")
    println("="^75)
    title = isempty(month) ? "BACKTEST REPORT" : "BACKTEST REPORT - $month Polymarket Markets"
    println(title)
    println("="^75)
    println()

    total_pnl = 0.0
    total_stake = 0.0
    correct_count = 0

    for r in results
        status = r.correct ? "✓" : "✗"
        pnl_str = r.pnl >= 0 ? "+\$$(round(r.pnl, digits=2))" : "-\$$(round(abs(r.pnl), digits=2))"

        println("$status $(r.question[1:min(50, length(r.question))])...")
        println("  Predicted: $(r.predicted_outcome) @ $(round(r.predicted_confidence * 100, digits=1))%")
        println("  Actual:    $(r.actual_outcome)")
        println("  Stake:     \$$(round(r.stake, digits=2)) → $pnl_str")
        println()

        total_pnl += r.pnl
        total_stake += r.stake
        if r.correct
            correct_count += 1
        end
    end

    println("-"^75)
    println("SUMMARY")
    println("-"^75)
    @printf("Accuracy:     %d/%d (%.1f%%)\n", correct_count, length(results), 100.0 * correct_count / length(results))
    @printf("Total Stake:  \$%.2f\n", total_stake)
    @printf("Total P&L:    %s\$%.2f\n", total_pnl >= 0 ? "+" : "-", abs(total_pnl))
    @printf("ROI:          %.1f%%\n", 100.0 * total_pnl / total_stake)
    println()

    # Grace Hopper's calculus
    println("="^75)
    println("GRACE HOPPER'S CALCULUS")
    println("="^75)
    cost_of_wrong = sum(r.pnl for r in results if !r.correct; init=0.0)
    @printf("Cost of incorrect predictions: \$%.2f\n", abs(cost_of_wrong))
    @printf("Value of correct predictions:  \$%.2f\n", sum(r.pnl for r in results if r.correct; init=0.0))
    println()
    println("\"I now know economically: I can go up to almost half a million")
    println("dollars to get that file to a higher level of correctness,")
    println("because that's what I stand to lose.\" — Grace Hopper")
end

# =============================================================================
# Example Predictions for Backtesting
# =============================================================================

"""
    december_predictions()

Generate sample predictions for December 2025 markets.
"""
function december_predictions()
    return [
        # (market_id, predicted_outcome, confidence, stake)
        ("fed-decision-december-2025", "25 bps decrease", 0.85, 1000.0),
        ("fed-rate-cuts-2025", "3 (75 bps)", 0.70, 500.0),
        ("elon-musk-tweets-december-2025", "1100-1399", 0.60, 100.0),  # Wrong!
        ("microstrategy-sells-btc-2025", "No", 0.90, 500.0),
        ("macron-out-2025", "No", 0.80, 300.0),
        ("kraken-ipo-2025", "No", 0.75, 200.0),
        ("polymarket-us-live-2025", "Yes", 0.65, 400.0),
    ]
end

"""
    november_predictions()

Generate sample predictions for November 2025 markets.
"""
function november_predictions()
    return [
        # (market_id, predicted_outcome, confidence, stake)
        ("fed-decision-october-2025", "25 bps decrease", 0.80, 1000.0),
        ("elon-musk-tweets-november-2025", "880-919", 0.55, 200.0),  # Close but wrong
        ("elon-tweets-oct28-nov4", "200-219", 0.65, 100.0),
        ("elon-tweets-nov11-nov18", "240+", 0.50, 100.0),  # Wrong - was 260-279
        ("elon-tweets-nov18-nov25", "200-219", 0.60, 100.0),
        ("government-shutdown-nov-2025", "Yes", 0.75, 500.0),
    ]
end

# Alias for backwards compatibility
demo_predictions() = december_predictions()

# =============================================================================
# Main
# =============================================================================

"""
    run_month(month::String)

Run backtest for a specific month.
Supported months: "november", "december"
"""
function run_month(month::String)
    month_lower = lowercase(month)

    if month_lower == "november"
        data_file = "november_2025_resolved.json"
        predictions = november_predictions()
        display_name = "November 2025"
    elseif month_lower == "december"
        data_file = "december_2025_resolved.json"
        predictions = december_predictions()
        display_name = "December 2025"
    else
        error("Unknown month: $month. Supported: november, december")
    end

    data_path = joinpath(@__DIR__, "data", data_file)

    if !isfile(data_path)
        @error "Data file not found: $data_path"
        return nothing
    end

    markets = load_resolved_markets(data_path)
    println("Loaded $(length(markets)) resolved markets for $display_name")
    println("Testing $(length(predictions)) predictions")
    println()

    results = run_backtest(markets, predictions)
    print_backtest_report(results; month=display_name)

    return results
end

function main()
    println()
    println("╔══════════════════════════════════════════════════════════════════════╗")
    println("║  PRAESCIENTIA - BACKTESTING                                          ║")
    println("║  Validating predictions against market resolutions                   ║")
    println("╚══════════════════════════════════════════════════════════════════════╝")
    println()

    # Parse command line args
    month = length(ARGS) > 0 ? ARGS[1] : "december"

    run_month(month)
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end

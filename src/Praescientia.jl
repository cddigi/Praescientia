module Praescientia

using HTTP
using JSON3
using SHA
using Dates
using UUIDs

export StateBlock, PredictionChain, Market, Prediction
export create_genesis_block, add_prediction, calculate_divergence_point
export fetch_markets, get_market_price, calculate_cost_of_wrong
export confidence_decay, rollback_to_block

# =============================================================================
# Core Philosophy (per Grace Hopper, 1982):
# "We've almost never made any computation of the possible costs of incorrect
#  information in the system... I now know economically: I can go up to almost
#  half a million dollars to get that file to a higher level of correctness,
#  because that's what I stand to lose."
#
# And: "The minute we get to systems of computers, we don't go down anymore."
# 
# This module implements discrete state checkpoints with rollback capability,
# narrowing the gap between human "obvious" pattern recognition and GenAI's
# brute-force reprocessing.
# =============================================================================

"""
    StateBlock

An immutable checkpoint in the prediction chain. Each block knows its parent,
enabling O(1) identification of divergence points rather than O(n) reprocessing.
"""
struct StateBlock
    id::UUID
    timestamp::DateTime
    parent_hash::String
    hash::String
    prediction::Union{Nothing, Dict{String, Any}}
    confidence::Float64
    reality_check::Union{Nothing, Float64}  # What the market actually showed
    cost_if_wrong::Float64
    
    function StateBlock(parent_hash::String, prediction, confidence::Float64, cost_if_wrong::Float64)
        id = uuid4()
        ts = now(UTC)
        data = string(parent_hash, ts, prediction, confidence)
        hash = bytes2hex(sha256(data))
        new(id, ts, parent_hash, hash, prediction, confidence, nothing, cost_if_wrong)
    end
end

"""
    PredictionChain

A chain of StateBlocks representing the evolution of predictions over time.
The key insight: humans identify rollback points instantly because they maintain
a causal graph in memory. We replicate this with explicit parent pointers.
"""
mutable struct PredictionChain
    blocks::Vector{StateBlock}
    divergence_index::Union{Nothing, Int}  # Where reality diverged from prediction
    cumulative_confidence::Float64
    
    function PredictionChain()
        genesis = create_genesis_block()
        new([genesis], nothing, 1.0)
    end
end

function create_genesis_block()
    StateBlock("0" ^ 64, nothing, 1.0, 0.0)
end

"""
    add_prediction(chain::PredictionChain, prediction::Dict, confidence::Float64, stake::Float64)

Add a new prediction block. The stake determines cost_if_wrong via Kelly-inspired calculation.
"""
function add_prediction(chain::PredictionChain, prediction::Dict, confidence::Float64, stake::Float64)
    parent = chain.blocks[end]
    
    # Grace Hopper's calculus: what's the cost of being wrong?
    # If confidence is 0.7 and stake is $100, potential loss is $100 * (1 - 0.7) = $30
    # But this underestimates tail risk. Use: stake * (1 / confidence - 1) for expected loss
    cost_if_wrong = stake * (1.0 / max(confidence, 0.01) - 1.0)
    
    block = StateBlock(parent.hash, prediction, confidence, cost_if_wrong)
    push!(chain.blocks, block)
    
    # Update cumulative confidence (product of confidences, decaying)
    chain.cumulative_confidence *= confidence
    
    return block
end

"""
    calculate_divergence_point(chain::PredictionChain, reality::Vector{Float64})

Given a vector of actual market outcomes, find where our predictions diverged.
This is the "come on, it's obvious" moment - O(n) in worst case, but typically
early divergence is caught quickly because we check in reverse order.

Returns the block index where divergence occurred, or nothing if aligned.
"""
function calculate_divergence_point(chain::PredictionChain, reality::Vector{Float64}; threshold::Float64=0.1)
    if length(reality) != length(chain.blocks) - 1  # -1 for genesis
        @warn "Reality vector length mismatch with prediction chain"
        return nothing
    end
    
    # Check from most recent to oldest (humans do this too - "where did we go wrong?")
    for i in length(reality):-1:1
        block = chain.blocks[i + 1]  # +1 to skip genesis
        if block.prediction !== nothing
            predicted_price = get(block.prediction, "predicted_price", 0.0)
            if abs(predicted_price - reality[i]) > threshold
                chain.divergence_index = i + 1
                return i + 1
            end
        end
    end
    
    chain.divergence_index = nothing
    return nothing
end

"""
    rollback_to_block(chain::PredictionChain, block_index::Int)

Rollback the chain to a specific checkpoint. Returns a new chain starting from that point.
This is the key insight: we don't reprocess everything, we just fork from the valid state.
"""
function rollback_to_block(chain::PredictionChain, block_index::Int)
    if block_index < 1 || block_index > length(chain.blocks)
        error("Invalid block index for rollback")
    end
    
    new_chain = PredictionChain()
    new_chain.blocks = chain.blocks[1:block_index]
    new_chain.cumulative_confidence = prod([b.confidence for b in new_chain.blocks])
    new_chain.divergence_index = nothing
    
    return new_chain
end

"""
    confidence_decay(angle::Float64, t::Float64)

Trigonometric confidence decay function (from your visualization).
Uses the oscillating model: confidence = (cos(3θ) + 1) / 2
where θ evolves with time/new information.
"""
function confidence_decay(angle::Float64, t::Float64; decay_rate::Float64=0.1)
    new_angle = mod(angle + t * 2π / 3, 2π)
    confidence = (cos(3 * new_angle) + 1) / 2
    # Apply decay for staleness
    confidence * exp(-decay_rate * t)
end

# =============================================================================
# Polymarket API Integration
# =============================================================================

const CLOB_HOST = "https://clob.polymarket.com"
const GAMMA_HOST = "https://gamma-api.polymarket.com"

"""
    Market

Represents a Polymarket prediction market.
"""
struct Market
    id::String
    question::String
    token_id::String
    outcomes::Vector{String}
    current_price::Float64
    volume::Float64
    end_date::Union{Nothing, DateTime}
end

"""
    fetch_markets(; limit::Int=20, active_only::Bool=true)

Fetch available markets from Polymarket's Gamma API.
"""
function fetch_markets(; limit::Int=20, active_only::Bool=true)
    url = "$GAMMA_HOST/markets?limit=$limit" * (active_only ? "&active=true" : "")
    
    try
        response = HTTP.get(url, ["Accept" => "application/json"])
        data = JSON3.read(String(response.body))
        
        markets = Market[]
        for m in data
            market = Market(
                string(get(m, :id, "")),
                string(get(m, :question, "Unknown")),
                string(get(m, :conditionId, "")),  # token_id
                string.(get(m, :outcomes, ["Yes", "No"])),
                Float64(get(m, :outcomePrices, [0.5, 0.5])[1]),
                Float64(get(m, :volume, 0)),
                nothing  # TODO: parse end date
            )
            push!(markets, market)
        end
        
        return markets
    catch e
        @error "Failed to fetch markets" exception=e
        return Market[]
    end
end

"""
    get_market_price(token_id::String; side::String="BUY")

Get the current price for a specific market token.
"""
function get_market_price(token_id::String; side::String="BUY")
    url = "$CLOB_HOST/price?token_id=$token_id&side=$side"
    
    try
        response = HTTP.get(url, ["Accept" => "application/json"])
        data = JSON3.read(String(response.body))
        return Float64(get(data, :price, 0.5))
    catch e
        @error "Failed to get price" exception=e token_id
        return 0.5
    end
end

"""
    get_order_book(token_id::String)

Get the full order book for analysis.
"""
function get_order_book(token_id::String)
    url = "$CLOB_HOST/book?token_id=$token_id"
    
    try
        response = HTTP.get(url, ["Accept" => "application/json"])
        return JSON3.read(String(response.body))
    catch e
        @error "Failed to get order book" exception=e
        return nothing
    end
end

"""
    calculate_cost_of_wrong(current_price::Float64, predicted_direction::Bool, stake::Float64)

Grace Hopper's calculus applied to prediction markets.
If we predict YES and the market goes to 0, we lose our stake.
If we predict NO and the market goes to 1, we lose our stake.

Returns: (expected_loss, maximum_loss, breakeven_probability)
"""
function calculate_cost_of_wrong(current_price::Float64, predicted_direction::Bool, stake::Float64)
    if predicted_direction  # Betting YES
        # We pay current_price for each share, worth 1 if correct, 0 if wrong
        cost_per_share = current_price
        max_loss = stake  # Total stake lost if market goes to 0
        expected_loss = stake * (1 - current_price)  # Weighted by probability of loss
        breakeven = current_price  # We need the probability to be at least this
    else  # Betting NO
        # We pay (1 - current_price) for each NO share
        cost_per_share = 1 - current_price
        max_loss = stake
        expected_loss = stake * current_price
        breakeven = 1 - current_price
    end
    
    return (expected_loss=expected_loss, maximum_loss=max_loss, breakeven_probability=breakeven)
end

# =============================================================================
# The "Connect the Dots" Engine
# =============================================================================

"""
    Observation

A single piece of information that contributes to prediction.
"""
struct Observation
    source::String
    content::String
    timestamp::DateTime
    relevance_score::Float64
    contradicts::Vector{UUID}  # IDs of observations this contradicts
end

"""
    LogicalDeduction

The "come on, it's obvious" engine. Tracks observations and their logical connections.
"""
mutable struct LogicalDeduction
    observations::Dict{UUID, Observation}
    implications::Dict{UUID, Vector{UUID}}  # A implies B
    contradictions::Dict{UUID, Vector{UUID}}  # A contradicts B
    confidence_graph::Dict{UUID, Float64}
    
    function LogicalDeduction()
        new(Dict(), Dict(), Dict(), Dict())
    end
end

"""
    add_observation!(engine::LogicalDeduction, obs::Observation)

Add an observation and update the logical graph.
When contradictions are detected, confidence in conflicting observations decreases.
"""
function add_observation!(engine::LogicalDeduction, obs::Observation)
    id = uuid4()
    engine.observations[id] = obs
    engine.confidence_graph[id] = obs.relevance_score
    
    # Track contradictions
    for contra_id in obs.contradicts
        if haskey(engine.observations, contra_id)
            push!(get!(engine.contradictions, id, UUID[]), contra_id)
            push!(get!(engine.contradictions, contra_id, UUID[]), id)
            
            # Reduce confidence in contradicted observations
            engine.confidence_graph[contra_id] *= 0.7
        end
    end
    
    return id
end

"""
    synthesize_prediction(engine::LogicalDeduction, market::Market)

Synthesize a prediction from all observations. This is where "connect the dots" happens.
"""
function synthesize_prediction(engine::LogicalDeduction, market::Market)
    if isempty(engine.observations)
        return (direction=nothing, confidence=0.0, reasoning="No observations")
    end
    
    # Weight observations by confidence and recency
    now_ts = now(UTC)
    
    weighted_sum = 0.0
    total_weight = 0.0
    
    for (id, obs) in engine.observations
        # Time decay: observations older than 24h have reduced weight
        age_hours = Dates.value(now_ts - obs.timestamp) / (1000 * 60 * 60)
        time_weight = exp(-age_hours / 24)
        
        confidence = get(engine.confidence_graph, id, obs.relevance_score)
        weight = confidence * time_weight
        
        # Simple heuristic: positive sentiment in content increases YES probability
        sentiment = contains(lowercase(obs.content), "likely") || 
                   contains(lowercase(obs.content), "expect") ||
                   contains(lowercase(obs.content), "confirm") ? 0.7 : 0.3
        
        weighted_sum += sentiment * weight
        total_weight += weight
    end
    
    predicted_prob = total_weight > 0 ? weighted_sum / total_weight : 0.5
    
    direction = predicted_prob > 0.5
    confidence = abs(predicted_prob - 0.5) * 2  # Map 0.5 -> 0, 1.0 -> 1.0
    
    return (direction=direction, confidence=confidence, predicted_probability=predicted_prob)
end

# =============================================================================
# Entry Point: The Oracle
# =============================================================================

"""
    Oracle

The main interface. Combines prediction chains, logical deduction, and market data.
"""
mutable struct Oracle
    chains::Dict{String, PredictionChain}  # market_id -> chain
    deduction_engines::Dict{String, LogicalDeduction}  # market_id -> engine
    total_stake::Float64
    total_profit_loss::Float64
    
    function Oracle()
        new(Dict(), Dict(), 0.0, 0.0)
    end
end

"""
    analyze_market(oracle::Oracle, market_id::String)

Full analysis pipeline for a market.
"""
function analyze_market(oracle::Oracle, market_id::String)
    # Get or create prediction chain
    chain = get!(oracle.chains, market_id) do
        PredictionChain()
    end
    
    # Get or create deduction engine
    engine = get!(oracle.deduction_engines, market_id) do
        LogicalDeduction()
    end
    
    # Fetch current market state
    # TODO: Implement with actual token_id lookup
    
    # Synthesize prediction
    # prediction = synthesize_prediction(engine, market)
    
    return chain, engine
end

end # module

#!/usr/bin/env julia
#=
=====================================================================
PRAESCIENTIA - DEMONSTRATION
=====================================================================
Latin: praescientia (foreknowledge)

"We should be looking at the information flow, and then selecting
the computers to implement that information flow."
                                        - Grace Hopper, 1982

This script demonstrates the core insight: narrowing the gap between
human "come on, it's obvious" pattern recognition and GenAI's need
to reprocess entire contexts.

The solution: Discrete, hashed state checkpoints with O(1) rollback
identification instead of O(n) context reprocessing.
=====================================================================
=#

include("src/Praescientia.jl")
using .Praescientia
using Dates
using UUIDs

"""
Demonstration of the prediction chain with rollback capability.
"""
function demonstrate_rollback()
    println("="^70)
    println("DEMONSTRATION: State Rollback in Prediction Markets")
    println("="^70)
    println()
    
    # Create a prediction chain
    chain = PredictionChain()
    
    println("Genesis block created: ", chain.blocks[1].hash[1:16], "...")
    println()
    
    # Simulate a series of predictions about a market
    # Let's say: "Will Congress pass the AI regulation bill by Q2 2026?"
    
    predictions = [
        (Dict("predicted_price" => 0.35, "reasoning" => "Initial analysis: unlikely"), 0.60, 100.0),
        (Dict("predicted_price" => 0.42, "reasoning" => "New sponsor joined"), 0.65, 100.0),
        (Dict("predicted_price" => 0.55, "reasoning" => "Committee vote passed"), 0.75, 150.0),
        (Dict("predicted_price" => 0.70, "reasoning" => "Floor vote scheduled"), 0.80, 200.0),
        (Dict("predicted_price" => 0.45, "reasoning" => "Filibuster threat"), 0.70, 100.0),  # ← Divergence point
    ]
    
    println("Adding prediction blocks...")
    for (i, (pred, conf, stake)) in enumerate(predictions)
        block = add_prediction(chain, pred, conf, stake)
        cost = calculate_cost_of_wrong(pred["predicted_price"], true, stake)
        
        println("  Block $i: price=$(pred["predicted_price"]) confidence=$conf")
        println("           Cost if wrong: \$$(round(cost.expected_loss, digits=2))")
        println("           Hash: $(block.hash[1:16])...")
    end
    
    println("\nTotal blocks in chain: ", length(chain.blocks))
    println("Cumulative confidence: ", round(chain.cumulative_confidence, digits=4))
    println()
    
    # Now simulate reality diverging from our predictions
    # The actual market prices were different starting at block 4
    reality = [0.34, 0.40, 0.58, 0.38, 0.32]  # Block 4 diverged significantly
    
    println("-"^70)
    println("REALITY CHECK: Comparing predictions to actual market prices")
    println("-"^70)
    
    divergence = calculate_divergence_point(chain, reality; threshold=0.15)
    
    if divergence !== nothing
        println()
        println("⚠️  DIVERGENCE DETECTED at block $divergence")
        println()
        
        # This is the key insight: A human would say "the filibuster threat
        # prediction was where we went wrong" - they can instantly identify it.
        # GenAI typically needs to reprocess everything to figure this out.
        # Our architecture gives O(1) identification of the divergence point.
        
        predicted = chain.blocks[divergence].prediction["predicted_price"]
        actual = reality[divergence - 1]  # -1 for genesis offset
        
        println("   Predicted: $predicted")
        println("   Actual:    $actual")
        println("   Δ:         $(abs(predicted - actual))")
        println()
        
        # Calculate what this error cost us (Grace Hopper's calculus)
        stake = 100.0  # From the prediction
        cost = calculate_cost_of_wrong(predicted, predicted > 0.5, stake)
        println("   Potential loss from this error: \$$(round(cost.expected_loss, digits=2))")
        println()
        
        # Now demonstrate rollback
        println("-"^70)
        println("ROLLBACK: Creating new chain from last valid state")
        println("-"^70)
        
        # Rollback to block before divergence
        new_chain = rollback_to_block(chain, divergence - 1)
        
        println()
        println("Original chain length: $(length(chain.blocks))")
        println("New chain length:      $(length(new_chain.blocks))")
        println()
        println("We can now make new predictions from block $(divergence - 1)")
        println("without reprocessing the entire context.")
        println()
        
        # Add a corrected prediction
        corrected_pred = Dict(
            "predicted_price" => 0.38,
            "reasoning" => "CORRECTED: Filibuster threat underestimated opposition strength"
        )
        corrected_block = add_prediction(new_chain, corrected_pred, 0.85, 100.0)
        
        println("Added corrected prediction: $(corrected_pred["predicted_price"])")
        println("New chain length: $(length(new_chain.blocks))")
        
    else
        println("✓ No significant divergence detected")
    end
    
    println()
    println("="^70)
    println("KEY INSIGHT")
    println("="^70)
    println("""
    Traditional GenAI approach: Reprocess entire conversation to find error
    → O(n) computational cost, unclear where "truth" stops
    
    Our approach: Hashed state checkpoints with parent pointers
    → O(1) divergence identification via reality comparison
    → Fork from valid state, no need to invalidate shared history
    → Cost-of-wrong calculated BEFORE betting (Hopper's calculus)
    
    "Who determines what is true and what is false? We can't."
    → But we CAN determine where our predictions diverged from reality,
      and rollback to that exact point.
    """)
end

"""
Demonstrate the "connect the dots" logical deduction engine.
"""
function demonstrate_logical_deduction()
    println()
    println("="^70)
    println("DEMONSTRATION: Connect-the-Dots Logical Deduction")
    println("="^70)
    println()
    
    engine = LogicalDeduction()
    
    # Simulate observations about a market
    obs1 = Observation(
        "Reuters",
        "Senate Majority Leader confirms AI regulation bill will reach floor vote",
        now(UTC) - Hour(2),
        0.9,
        UUID[]
    )
    
    obs2 = Observation(
        "WSJ",
        "Tech industry lobbying group likely to block bill progress",
        now(UTC) - Hour(1),
        0.75,
        UUID[]
    )
    
    id1 = add_observation!(engine, obs1)
    id2 = add_observation!(engine, obs2)
    
    # Third observation contradicts the second
    obs3 = Observation(
        "Bloomberg",
        "Lobbying efforts expected to fail; bipartisan support confirmed",
        now(UTC) - Minute(30),
        0.85,
        [id2]  # Contradicts the WSJ observation
    )
    
    id3 = add_observation!(engine, obs3)
    
    println("Observations added:")
    for (id, obs) in engine.observations
        conf = engine.confidence_graph[id]
        println("  [$(string(id)[1:8])...] $(obs.source): confidence=$(round(conf, digits=2))")
    end
    
    println()
    println("Notice: WSJ observation confidence reduced due to contradiction")
    println("        from Bloomberg source.")
    println()
    
    # The "come on, it's obvious" moment
    println("Logical synthesis:")
    println("  - Floor vote confirmed (high confidence)")
    println("  - Lobby block claim (reduced confidence - contradicted)")
    println("  - Bipartisan support (high confidence, recent)")
    println()
    println("→ 'Obviously' the bill will pass. A human sees this instantly.")
    println("  Our engine tracks the confidence graph to reach the same conclusion.")
end

"""
Demonstrate the confidence decay function from the trigonometric model.
"""
function demonstrate_confidence_decay()
    println()
    println("="^70)
    println("DEMONSTRATION: Trigonometric Confidence Decay")
    println("="^70)
    println()
    
    # Your model: confidence = (cos(3θ) + 1) / 2
    # θ evolves with time and new information
    
    initial_angle = 0.0
    
    println("Initial angle: 0.0, Confidence: $(confidence_decay(0.0, 0.0))")
    println()
    println("Time evolution (with decay rate 0.1):")
    
    for t in 0.0:0.5:3.0
        conf = confidence_decay(initial_angle, t)
        bar = repeat("█", Int(round(conf * 40)))
        println("  t=$t: $bar $(round(conf, digits=3))")
    end
    
    println()
    println("The oscillation represents uncertainty waves - confidence")
    println("naturally cycles as new information creates and resolves")
    println("ambiguity. The decay represents staleness.")
end

# =============================================================================
# Main
# =============================================================================

function main()
    println()
    println("╔══════════════════════════════════════════════════════════════════╗")
    println("║  PRAESCIENTIA                                                    ║")
    println("║  Latin: foreknowledge                                            ║")
    println("║  Conversational State Rollback for Prediction Markets            ║")
    println("║                                                                   ║")
    println("║  'The hardware and software are, after all, only the tools       ║")
    println("║   with which we do the processing and should not occupied        ║")
    println("║   the primary position in our thinking.'                         ║")
    println("║                                    - Grace Hopper, 1982          ║")
    println("╚══════════════════════════════════════════════════════════════════╝")
    println()
    
    demonstrate_rollback()
    demonstrate_logical_deduction()
    demonstrate_confidence_decay()
    
    println()
    println("="^70)
    println("NEXT STEPS FOR POLYMARKET INTEGRATION")
    println("="^70)
    println("""
    1. API Authentication (requires private key):
       - Create/derive API credentials via EIP-712 signing
       - Set up L2 authentication headers
       
    2. Market Discovery:
       - Fetch available markets from Gamma API
       - Filter by category, volume, and time-to-resolution
       
    3. Observation Pipeline:
       - Ingest news feeds (Reuters, Bloomberg, etc.)
       - Extract observations with NLP
       - Build logical deduction graph
       
    4. Automated Trading:
       - Synthesize predictions with confidence thresholds
       - Calculate cost-of-wrong before each bet
       - Place orders via CLOB API
       - Track reality vs predictions for rollback
       
    5. The Gap Narrowing:
       - Each prediction is a checkpoint
       - Reality checks identify divergence
       - Rollback without reprocessing entire context
    """)
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end

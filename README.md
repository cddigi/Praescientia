# Praescientia

**Latin:** *praescientia* (foreknowledge)

> "The hardware and software are, after all, only the tools with which we do the processing and should not occupied the primary position in our thinking. It's high time we began to turn our attention to the data and the information."
> — **Grace Hopper, 1982**

## The Problem

You are having a conversation. Multiple messages are exchanged. Except now, something is off. Someone made an error. You need to go back and start the conversation at that moment in time.

**Humans** do this instantly. They know exactly where to reset.

**GenAI** requires massive computational power. Why? Because it has no natural checkpoint system. The entire context must be reprocessed to identify divergence.

This project narrows that gap.

## The Insight

Grace Hopper identified two critical concepts in 1982 that apply directly:

1. **The Cost of Incorrect Information**: "We've almost never made any computation of the possible costs of incorrect information in the system... I now know economically: I can go up to almost half a million dollars to get that file to a higher level of correctness, because that's what I stand to lose."

2. **Systems of Computers**: "The minute we get to systems of computers, we don't go down anymore... So the sooner I move to systems of computers, the faster I'm going to go. The better security I'll have. And the less it will cost me."

## The Architecture

### State Chains with Rollback

Instead of a monolithic conversation context, we use discrete, hashed state blocks:

```
┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐
│  Genesis Block  │────▶│  Prediction 1   │────▶│  Prediction 2   │
│  hash: 0x0000   │     │  hash: 0xa1b2   │     │  hash: 0xc3d4   │
│  confidence: 1.0│     │  confidence: 0.6│     │  confidence: 0.7│
└─────────────────┘     └─────────────────┘     └─────────────────┘
                                                         │
                                                         ▼
                        ┌─────────────────┐     ┌─────────────────┐
                        │  Prediction 4   │◀────│  Prediction 3   │
                        │  hash: 0xg7h8   │     │  hash: 0xe5f6   │
                        │  confidence: 0.8│     │  confidence: 0.75│
                        │  ⚠️ DIVERGENCE  │     │                 │
                        └─────────────────┘     └─────────────────┘
```

When reality diverges from prediction, we identify the exact block and fork:

```julia
divergence = calculate_divergence_point(chain, reality; threshold=0.15)
# Returns: 4 (where our prediction diverged from market reality)

new_chain = rollback_to_block(chain, divergence - 1)
# Fork from last valid state, no reprocessing needed
```

### The "Connect the Dots" Engine

Human pattern recognition is fast because it maintains a **logical graph** of implications and contradictions. We replicate this:

```julia
engine = LogicalDeduction()

# Observation 1: High confidence, supports YES
id1 = add_observation!(engine, Observation(
    "Reuters", 
    "Floor vote confirmed for AI bill",
    now(UTC),
    0.9,    # relevance
    UUID[]  # no contradictions
))

# Observation 2: Contradicts observation 1
id2 = add_observation!(engine, Observation(
    "Lobbyist",
    "Bill will be blocked",
    now(UTC),
    0.6,
    [id1]  # contradicts observation 1
))

# Observation 1's confidence is automatically reduced
# The graph self-corrects based on logical structure
```

### Confidence Decay

Inspired by the trigonometric conversation model in the project files:

```julia
# Confidence oscillates and decays
# θ evolves with new information, confidence = (cos(3θ) + 1) / 2
confidence = confidence_decay(angle, time; decay_rate=0.1)
```

This captures the reality that confidence isn't static—it naturally oscillates as new information creates and resolves ambiguity.

## Polymarket Integration

### API Structure

| Endpoint | Purpose |
|----------|---------|
| `https://clob.polymarket.com` | Central Limit Order Book (trading) |
| `https://gamma-api.polymarket.com` | Market discovery |
| `wss://clob.polymarket.com/ws` | Real-time price feeds |

### Authentication Levels

1. **Public**: Market data, prices, order books
2. **L1**: Derive API credentials (requires private key signing)
3. **L2**: Place orders (requires API credentials + order signing)

### Example Flow

```julia
using Praescientia, PolymarketAuth

# Initialize client (read-only)
client = CLOBClient()

# Fetch market data
markets = get_markets(client)
price = get_midpoint(client, "token_id_here")
book = get_order_book(client, "token_id_here")

# Create prediction chain
chain = PredictionChain()

# Add prediction with cost-of-wrong calculation
prediction = Dict("predicted_price" => 0.65, "reasoning" => "Bipartisan support confirmed")
stake = 100.0  # USDC

# Grace Hopper's calculus: What do we stand to lose?
cost = calculate_cost_of_wrong(price, true, stake)
# => (expected_loss=35.0, maximum_loss=100.0, breakeven_probability=0.65)

# Only bet if cost is acceptable
if cost.expected_loss < stake * 0.3
    block = add_prediction(chain, prediction, 0.75, stake)
end
```

## Project Structure

```
praescientia/
├── Project.toml              # Julia package manifest
├── demo.jl                   # Demonstration script
├── README.md                 # This file
└── src/
    ├── Praescientia.jl       # Core state chain + prediction logic
    └── PolymarketAuth.jl     # API authentication + trading
```

## Requirements

- Julia 1.9+
- Packages: HTTP.jl, JSON3.jl, SHA.jl, Dates, UUIDs
- For trading: Polygon wallet with USDC.e

## Installation

```julia
using Pkg
Pkg.activate("praescientia")
Pkg.instantiate()
```

## Philosophy

The central insight is that **the gap between human and AI reasoning** in error identification isn't a fundamental limitation—it's an architectural choice.

Humans don't reprocess their entire life history when they realize they made a wrong turn. They have checkpoint systems: "I was fine until I turned left at the gas station."

This project gives GenAI the same capability for prediction markets:
1. Each prediction is a checkpoint
2. Reality provides ground truth
3. Divergence is identified by comparison, not reprocessing
4. Rollback forks from valid state

> "Who determines what is true and what is false? We can't. Who is the definitive source of truth?"

For prediction markets, the market IS the source of truth. When our model diverges from the market, we know exactly where we went wrong—because we have the checkpoints.

## License

MIT

---

*Praescientia — Built for First Trust GenAI team. Grace Hopper is our hero.*

#!/usr/bin/env julia
"""
    Kalshi Orders API Scripts

Endpoints:
  GET    /portfolio/orders                        - List orders
  POST   /portfolio/orders                        - Create order
  GET    /portfolio/orders/{order_id}              - Get order details
  DELETE /portfolio/orders/{order_id}              - Cancel order
  POST   /portfolio/orders/batched                 - Batch create orders (up to 20)
  DELETE /portfolio/orders/batched                  - Batch cancel orders (up to 20)
  POST   /portfolio/orders/{order_id}/amend        - Amend order (price/quantity)
  POST   /portfolio/orders/{order_id}/decrease      - Decrease order quantity
  GET    /portfolio/orders/queue_positions           - Queue positions for all resting orders
  GET    /portfolio/orders/{order_id}/queue_position - Queue position for specific order

Usage:
  julia --project=. scripts/kalshi_orders.jl list [--ticker=T] [--status=resting]
  julia --project=. scripts/kalshi_orders.jl create --ticker=T --side=yes --type=limit --count=10 --yes_price=50
  julia --project=. scripts/kalshi_orders.jl get ORDER_ID
  julia --project=. scripts/kalshi_orders.jl cancel ORDER_ID
  julia --project=. scripts/kalshi_orders.jl amend ORDER_ID --price=55 [--count=15]
  julia --project=. scripts/kalshi_orders.jl decrease ORDER_ID --reduce_by=5
  julia --project=. scripts/kalshi_orders.jl queue_positions
  julia --project=. scripts/kalshi_orders.jl queue_position ORDER_ID
"""

include(joinpath(@__DIR__, "..", "src", "KalshiAuth.jl"))
using .KalshiAuth
using JSON3

# =============================================================================
# Orders Endpoints
# =============================================================================

"""
    list_orders(config; ticker, event_ticker, status, limit, cursor) -> response

List user's orders with optional filters.

Status values: resting, canceled, executed, pending
"""
function list_orders(config::KalshiConfig;
    ticker::String = "",
    event_ticker::String = "",
    status::String = "",
    limit::Int = 100,
    cursor::String = ""
)
    params = Dict{String,Any}("limit" => limit)
    !isempty(ticker) && (params["ticker"] = ticker)
    !isempty(event_ticker) && (params["event_ticker"] = event_ticker)
    !isempty(status) && (params["status"] = status)
    !isempty(cursor) && (params["cursor"] = cursor)
    return kalshi_get(config, "/portfolio/orders"; params)
end

"""
    create_order(config; ticker, side, type, action, count, yes_price, no_price,
                 expiration_ts, sell_position_floor, buy_max_cost) -> response

Create a new order.

Parameters:
  - ticker:              Market ticker (required)
  - side:                "yes" or "no" (required)
  - type:                "limit" or "market" (required)
  - action:              "buy" or "sell" (required, default "buy")
  - count:               Number of contracts (required)
  - yes_price:           Limit price in cents for YES side (1-99)
  - no_price:            Limit price in cents for NO side (1-99)
  - expiration_ts:       Order expiration timestamp (epoch seconds)
  - sell_position_floor: Min contracts to keep when selling
  - buy_max_cost:        Max total cost in cents for market orders
"""
function create_order(config::KalshiConfig;
    ticker::String,
    side::String,
    type::String = "limit",
    action::String = "buy",
    count::Int,
    yes_price::Union{Int,Nothing} = nothing,
    no_price::Union{Int,Nothing} = nothing,
    expiration_ts::Union{Int,Nothing} = nothing,
    sell_position_floor::Union{Int,Nothing} = nothing,
    buy_max_cost::Union{Int,Nothing} = nothing
)
    body = Dict{String,Any}(
        "ticker" => ticker,
        "side" => side,
        "type" => type,
        "action" => action,
        "count" => count
    )
    yes_price !== nothing && (body["yes_price"] = yes_price)
    no_price !== nothing && (body["no_price"] = no_price)
    expiration_ts !== nothing && (body["expiration_ts"] = expiration_ts)
    sell_position_floor !== nothing && (body["sell_position_floor"] = sell_position_floor)
    buy_max_cost !== nothing && (body["buy_max_cost"] = buy_max_cost)

    return kalshi_post(config, "/portfolio/orders"; body)
end

"""
    get_order(config, order_id) -> response

Get details for a specific order.
"""
function get_order(config::KalshiConfig, order_id::String)
    return kalshi_get(config, "/portfolio/orders/$order_id")
end

"""
    cancel_order(config, order_id) -> response

Cancel a resting order.
"""
function cancel_order(config::KalshiConfig, order_id::String)
    return kalshi_delete(config, "/portfolio/orders/$order_id")
end

"""
    batch_create_orders(config, orders::Vector{Dict}) -> response

Create multiple orders in a single request (up to 20).
Each order in the vector should have: ticker, side, type, action, count, and optional price fields.
"""
function batch_create_orders(config::KalshiConfig, orders::Vector{Dict{String,Any}})
    body = Dict{String,Any}("orders" => orders)
    return kalshi_post(config, "/portfolio/orders/batched"; body)
end

"""
    batch_cancel_orders(config, order_ids::Vector{String}) -> response

Cancel multiple orders in a single request (up to 20).
Each cancel counts as 0.2 transactions against rate limit.
"""
function batch_cancel_orders(config::KalshiConfig, order_ids::Vector{String})
    body = Dict{String,Any}("ids" => order_ids)
    return kalshi_delete(config, "/portfolio/orders/batched"; body)
end

"""
    amend_order(config, order_id; price, count) -> response

Modify price and/or quantity of an existing resting order.
At least one of price or count must be provided.
"""
function amend_order(config::KalshiConfig, order_id::String;
    price::Union{Int,Nothing} = nothing,
    count::Union{Int,Nothing} = nothing
)
    body = Dict{String,Any}()
    price !== nothing && (body["price"] = price)
    count !== nothing && (body["count"] = count)
    isempty(body) && error("At least one of price or count must be provided")
    return kalshi_post(config, "/portfolio/orders/$order_id/amend"; body)
end

"""
    decrease_order(config, order_id; reduce_by) -> response

Reduce the quantity of an existing order.
"""
function decrease_order(config::KalshiConfig, order_id::String; reduce_by::Int)
    body = Dict{String,Any}("reduce_by" => reduce_by)
    return kalshi_post(config, "/portfolio/orders/$order_id/decrease"; body)
end

"""
    get_queue_positions(config) -> response

Get queue positions for all resting orders.
"""
function get_queue_positions(config::KalshiConfig)
    return kalshi_get(config, "/portfolio/orders/queue_positions")
end

"""
    get_queue_position(config, order_id) -> response

Get queue position for a specific resting order.
"""
function get_queue_position(config::KalshiConfig, order_id::String)
    return kalshi_get(config, "/portfolio/orders/$order_id/queue_position")
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
        Usage: julia --project=. scripts/kalshi_orders.jl <command> [options]

        Commands:
          list                     List orders
          create                   Create a new order
          get ORDER_ID             Get order details
          cancel ORDER_ID          Cancel an order
          amend ORDER_ID           Amend price/quantity
          decrease ORDER_ID        Decrease quantity
          queue_positions          All resting order queue positions
          queue_position ORDER_ID  Specific order queue position

        Create options:
          --ticker=TICKER          Market ticker (required)
          --side=yes|no            Side (required)
          --type=limit|market      Order type (default: limit)
          --action=buy|sell        Action (default: buy)
          --count=N                Number of contracts (required)
          --yes_price=N            YES price in cents (1-99)
          --no_price=N             NO price in cents (1-99)

        Amend options:
          --price=N                New price in cents
          --count=N                New count

        Decrease options:
          --reduce_by=N            Number to reduce by

        Common options:
          --ticker=TICKER          Filter by ticker
          --status=STATUS          Filter by status
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
        result = list_orders(config;
            ticker = parse_arg(ARGS, "ticker"),
            event_ticker = parse_arg(ARGS, "event_ticker"),
            status = parse_arg(ARGS, "status"),
            limit = something(parse_int_arg(ARGS, "limit"), 100))
        println(JSON3.pretty(JSON3.write(result)))

    elseif cmd == "create"
        ticker = parse_arg(ARGS, "ticker")
        isempty(ticker) && error("--ticker required")
        side = parse_arg(ARGS, "side")
        isempty(side) && error("--side required (yes or no)")
        count = parse_int_arg(ARGS, "count")
        count === nothing && error("--count required")

        result = create_order(config;
            ticker,
            side,
            type = let t = parse_arg(ARGS, "type"); isempty(t) ? "limit" : t end,
            action = let a = parse_arg(ARGS, "action"); isempty(a) ? "buy" : a end,
            count,
            yes_price = parse_int_arg(ARGS, "yes_price"),
            no_price = parse_int_arg(ARGS, "no_price"),
            expiration_ts = parse_int_arg(ARGS, "expiration_ts"))
        println(JSON3.pretty(JSON3.write(result)))

    elseif cmd == "get"
        order_id = isempty(rest) ? error("Order ID required") : rest[1]
        result = get_order(config, order_id)
        println(JSON3.pretty(JSON3.write(result)))

    elseif cmd == "cancel"
        order_id = isempty(rest) ? error("Order ID required") : rest[1]
        result = cancel_order(config, order_id)
        println(JSON3.pretty(JSON3.write(result)))

    elseif cmd == "amend"
        order_id = isempty(rest) ? error("Order ID required") : rest[1]
        result = amend_order(config, order_id;
            price = parse_int_arg(ARGS, "price"),
            count = parse_int_arg(ARGS, "count"))
        println(JSON3.pretty(JSON3.write(result)))

    elseif cmd == "decrease"
        order_id = isempty(rest) ? error("Order ID required") : rest[1]
        reduce_by = parse_int_arg(ARGS, "reduce_by")
        reduce_by === nothing && error("--reduce_by required")
        result = decrease_order(config, order_id; reduce_by)
        println(JSON3.pretty(JSON3.write(result)))

    elseif cmd == "queue_positions"
        result = get_queue_positions(config)
        println(JSON3.pretty(JSON3.write(result)))

    elseif cmd == "queue_position"
        order_id = isempty(rest) ? error("Order ID required") : rest[1]
        result = get_queue_position(config, order_id)
        println(JSON3.pretty(JSON3.write(result)))

    else
        println("Unknown command: $cmd")
    end
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end

#!/usr/bin/env julia
"""
    Kalshi Communications (RFQ & Quotes) API Scripts

RFQ (Request for Quote) workflow:
  1. Create an RFQ specifying what you want to trade
  2. Other users submit quotes in response
  3. Accept a quote, then confirm to execute

Endpoints:
  GET    /communications/id                         - Get communications ID
  GET    /communications/rfqs                       - List RFQs
  POST   /communications/rfqs                       - Create RFQ (max 100 open)
  GET    /communications/rfqs/{rfq_id}              - Get specific RFQ
  DELETE /communications/rfqs/{rfq_id}              - Delete RFQ
  GET    /communications/quotes                     - List quotes
  POST   /communications/quotes                     - Create quote (response to RFQ)
  GET    /communications/quotes/{quote_id}          - Get specific quote
  DELETE /communications/quotes/{quote_id}          - Delete quote
  PUT    /communications/quotes/{quote_id}/accept   - Accept quote
  PUT    /communications/quotes/{quote_id}/confirm  - Confirm quote (finalize)

Usage:
  julia --project=. scripts/kalshi_communications.jl comms_id
  julia --project=. scripts/kalshi_communications.jl list_rfqs [--status=open]
  julia --project=. scripts/kalshi_communications.jl create_rfq --ticker=T --side=yes --count=10
  julia --project=. scripts/kalshi_communications.jl get_rfq RFQ_ID
  julia --project=. scripts/kalshi_communications.jl delete_rfq RFQ_ID
  julia --project=. scripts/kalshi_communications.jl list_quotes [--rfq_id=ID]
  julia --project=. scripts/kalshi_communications.jl create_quote --rfq_id=ID --price=50 --count=10
  julia --project=. scripts/kalshi_communications.jl accept_quote QUOTE_ID
  julia --project=. scripts/kalshi_communications.jl confirm_quote QUOTE_ID
"""

include(joinpath(@__DIR__, "..", "src", "KalshiAuth.jl"))
using .KalshiAuth
using JSON3

# =============================================================================
# Communications Endpoints
# =============================================================================

"""
    get_comms_id(config) -> response

Get the communications ID of the logged-in user.
"""
function get_comms_id(config::KalshiConfig)
    return kalshi_get(config, "/communications/id")
end

# --- RFQs ---

"""
    list_rfqs(config; status, creator, limit, cursor) -> response

List RFQs with optional filters.
"""
function list_rfqs(config::KalshiConfig;
    status::String = "",
    creator::String = "",
    limit::Int = 100,
    cursor::String = ""
)
    params = Dict{String,Any}("limit" => limit)
    !isempty(status) && (params["status"] = status)
    !isempty(creator) && (params["creator"] = creator)
    !isempty(cursor) && (params["cursor"] = cursor)
    return kalshi_get(config, "/communications/rfqs"; params)
end

"""
    create_rfq(config; ticker, side, count, expiration_ts) -> response

Create a new RFQ. Max 100 open RFQs per user.
"""
function create_rfq(config::KalshiConfig;
    ticker::String,
    side::String,
    count::Int,
    expiration_ts::Union{Int,Nothing} = nothing
)
    body = Dict{String,Any}(
        "ticker" => ticker,
        "side" => side,
        "count" => count
    )
    expiration_ts !== nothing && (body["expiration_ts"] = expiration_ts)
    return kalshi_post(config, "/communications/rfqs"; body)
end

"""
    get_rfq(config, rfq_id) -> response

Get a specific RFQ.
"""
function get_rfq(config::KalshiConfig, rfq_id::String)
    return kalshi_get(config, "/communications/rfqs/$rfq_id")
end

"""
    delete_rfq(config, rfq_id) -> response

Delete an RFQ.
"""
function delete_rfq(config::KalshiConfig, rfq_id::String)
    return kalshi_delete(config, "/communications/rfqs/$rfq_id")
end

# --- Quotes ---

"""
    list_quotes(config; rfq_id, status, limit, cursor) -> response

List quotes with optional filters.
"""
function list_quotes(config::KalshiConfig;
    rfq_id::String = "",
    status::String = "",
    limit::Int = 100,
    cursor::String = ""
)
    params = Dict{String,Any}("limit" => limit)
    !isempty(rfq_id) && (params["rfq_id"] = rfq_id)
    !isempty(status) && (params["status"] = status)
    !isempty(cursor) && (params["cursor"] = cursor)
    return kalshi_get(config, "/communications/quotes"; params)
end

"""
    create_quote(config; rfq_id, price, count, side, expiration_ts) -> response

Create a quote in response to an RFQ.
"""
function create_quote(config::KalshiConfig;
    rfq_id::String,
    price::Int,
    count::Int,
    side::String = "",
    expiration_ts::Union{Int,Nothing} = nothing
)
    body = Dict{String,Any}(
        "rfq_id" => rfq_id,
        "price" => price,
        "count" => count
    )
    !isempty(side) && (body["side"] = side)
    expiration_ts !== nothing && (body["expiration_ts"] = expiration_ts)
    return kalshi_post(config, "/communications/quotes"; body)
end

"""
    get_quote(config, quote_id) -> response

Get a specific quote.
"""
function get_quote(config::KalshiConfig, quote_id::String)
    return kalshi_get(config, "/communications/quotes/$quote_id")
end

"""
    delete_quote(config, quote_id) -> response

Delete a quote.
"""
function delete_quote(config::KalshiConfig, quote_id::String)
    return kalshi_delete(config, "/communications/quotes/$quote_id")
end

"""
    accept_quote(config, quote_id) -> response

Accept a quote.
"""
function accept_quote(config::KalshiConfig, quote_id::String)
    return kalshi_put(config, "/communications/quotes/$quote_id/accept")
end

"""
    confirm_quote(config, quote_id) -> response

Confirm a quote (finalize the trade).
"""
function confirm_quote(config::KalshiConfig, quote_id::String)
    return kalshi_put(config, "/communications/quotes/$quote_id/confirm")
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
        Usage: julia --project=. scripts/kalshi_communications.jl <command> [options]

        Commands:
          comms_id                  Get your communications ID
          list_rfqs                 List RFQs
          create_rfq                Create RFQ
          get_rfq RFQ_ID            Get specific RFQ
          delete_rfq RFQ_ID         Delete RFQ
          list_quotes               List quotes
          create_quote              Create quote (response to RFQ)
          get_quote QUOTE_ID        Get specific quote
          delete_quote QUOTE_ID     Delete quote
          accept_quote QUOTE_ID     Accept quote
          confirm_quote QUOTE_ID    Confirm quote

        RFQ options:
          --ticker=TICKER           Market ticker
          --side=yes|no             Side
          --count=N                 Number of contracts

        Quote options:
          --rfq_id=ID               RFQ ID to respond to
          --price=N                 Price in cents
          --count=N                 Number of contracts

        Common options:
          --status=STATUS           Filter by status
          --limit=N                 Results per page
          --demo / --live           Environment
          --verbose                 Debug output
        """)
        return
    end

    demo = !("--live" in ARGS)
    verbose = "--verbose" in ARGS
    config = load_config(; demo, verbose)

    cmd = ARGS[1]
    rest = filter(a -> !startswith(a, "--"), ARGS[2:end])

    if cmd == "comms_id"
        result = get_comms_id(config)
        println(JSON3.pretty(JSON3.write(result)))

    elseif cmd == "list_rfqs"
        result = list_rfqs(config;
            status = parse_arg(ARGS, "status"),
            limit = something(parse_int_arg(ARGS, "limit"), 100))
        println(JSON3.pretty(JSON3.write(result)))

    elseif cmd == "create_rfq"
        ticker = parse_arg(ARGS, "ticker")
        side = parse_arg(ARGS, "side")
        count = parse_int_arg(ARGS, "count")
        isempty(ticker) && error("--ticker required")
        isempty(side) && error("--side required")
        count === nothing && error("--count required")
        result = create_rfq(config; ticker, side, count)
        println(JSON3.pretty(JSON3.write(result)))

    elseif cmd == "get_rfq"
        rfq_id = isempty(rest) ? error("RFQ ID required") : rest[1]
        result = get_rfq(config, rfq_id)
        println(JSON3.pretty(JSON3.write(result)))

    elseif cmd == "delete_rfq"
        rfq_id = isempty(rest) ? error("RFQ ID required") : rest[1]
        result = delete_rfq(config, rfq_id)
        println(JSON3.pretty(JSON3.write(result)))

    elseif cmd == "list_quotes"
        result = list_quotes(config;
            rfq_id = parse_arg(ARGS, "rfq_id"),
            status = parse_arg(ARGS, "status"),
            limit = something(parse_int_arg(ARGS, "limit"), 100))
        println(JSON3.pretty(JSON3.write(result)))

    elseif cmd == "create_quote"
        rfq_id = parse_arg(ARGS, "rfq_id")
        price = parse_int_arg(ARGS, "price")
        count = parse_int_arg(ARGS, "count")
        isempty(rfq_id) && error("--rfq_id required")
        price === nothing && error("--price required")
        count === nothing && error("--count required")
        result = create_quote(config; rfq_id, price, count,
            side = parse_arg(ARGS, "side"))
        println(JSON3.pretty(JSON3.write(result)))

    elseif cmd == "get_quote"
        quote_id = isempty(rest) ? error("Quote ID required") : rest[1]
        result = get_quote(config, quote_id)
        println(JSON3.pretty(JSON3.write(result)))

    elseif cmd == "delete_quote"
        quote_id = isempty(rest) ? error("Quote ID required") : rest[1]
        result = delete_quote(config, quote_id)
        println(JSON3.pretty(JSON3.write(result)))

    elseif cmd == "accept_quote"
        quote_id = isempty(rest) ? error("Quote ID required") : rest[1]
        result = accept_quote(config, quote_id)
        println(JSON3.pretty(JSON3.write(result)))

    elseif cmd == "confirm_quote"
        quote_id = isempty(rest) ? error("Quote ID required") : rest[1]
        result = confirm_quote(config, quote_id)
        println(JSON3.pretty(JSON3.write(result)))

    else
        println("Unknown command: $cmd")
    end
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end

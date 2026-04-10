#!/usr/bin/env julia
"""
    Kalshi Trading Dashboard — Oxygen.jl Server

Web frontend for the Kalshi API using Oxygen.jl framework.
Proxies authenticated requests to Kalshi's Trading API via KalshiAuth.

Usage:
  julia --project=. kalshi_server.jl [--port=8080] [--live] [--verbose]

Sections:
  /                                  - Dashboard (serves kalshi_dashboard.html)
  /api/kalshi/exchange/status        - Exchange status
  /api/kalshi/exchange/schedule      - Exchange schedule
  /api/kalshi/exchange/announcements - Announcements
  /api/kalshi/markets                - Browse markets
  /api/kalshi/markets/:ticker        - Market details
  /api/kalshi/markets/:ticker/orderbook - Order book
  /api/kalshi/events                 - Browse events
  /api/kalshi/events/:ticker         - Event details
  /api/kalshi/portfolio/balance      - Account balance
  /api/kalshi/portfolio/positions    - Open positions
  /api/kalshi/portfolio/settlements  - Settlement history
  /api/kalshi/portfolio/fills        - Fill history
  /api/kalshi/orders                 - List orders
  /api/kalshi/orders (POST)          - Create order
  /api/kalshi/orders/:id (DELETE)    - Cancel order
  /api/kalshi/search/tags            - Market tags/categories
"""

using Oxygen
using HTTP
using JSON3
using Dates

include(joinpath(@__DIR__, "src", "KalshiAuth.jl"))
using .KalshiAuth

# =============================================================================
# Global Config (set once at startup)
# =============================================================================

const KALSHI_CONFIG = Ref{KalshiConfig}()

function init_config(; demo::Bool=true, verbose::Bool=false)
    KALSHI_CONFIG[] = load_config(; demo, verbose)
end

cfg() = KALSHI_CONFIG[]

# =============================================================================
# Helpers
# =============================================================================

function api_response(data; status::Int=200)
    return json(Dict("success" => true, "data" => data, "timestamp" => Dates.format(now(UTC), "yyyy-mm-ddTHH:MM:SSZ")); status)
end

function api_error(message::String; status::Int=500)
    return json(Dict("success" => false, "error" => message, "timestamp" => Dates.format(now(UTC), "yyyy-mm-ddTHH:MM:SSZ")); status)
end

function safe_call(f)
    try
        return api_response(f())
    catch e
        msg = sprint(showerror, e)
        @error "API error" exception=e
        return api_error(msg; status=500)
    end
end

# =============================================================================
# Routes — Dashboard
# =============================================================================

@get "/" function(req::HTTP.Request)
    return file(joinpath(@__DIR__, "kalshi_dashboard.html"); headers=["Content-Type" => "text/html"])
end

# =============================================================================
# Routes — Exchange
# =============================================================================

@get "/api/kalshi/exchange/status" function(req::HTTP.Request)
    safe_call() do
        kalshi_get(cfg(), "/exchange/status")
    end
end

@get "/api/kalshi/exchange/schedule" function(req::HTTP.Request)
    safe_call() do
        kalshi_get(cfg(), "/exchange/schedule")
    end
end

@get "/api/kalshi/exchange/announcements" function(req::HTTP.Request)
    safe_call() do
        kalshi_get(cfg(), "/exchange/announcements")
    end
end

# =============================================================================
# Routes — Markets
# =============================================================================

@get "/api/kalshi/markets" function(req::HTTP.Request)
    safe_call() do
        qp = queryparams(req)
        params = Dict{String,Any}()
        haskey(qp, "status") && (params["status"] = qp["status"])
        haskey(qp, "series_ticker") && (params["series_ticker"] = qp["series_ticker"])
        haskey(qp, "event_ticker") && (params["event_ticker"] = qp["event_ticker"])
        haskey(qp, "limit") && (params["limit"] = parse(Int, qp["limit"]))
        haskey(qp, "cursor") && (params["cursor"] = qp["cursor"])
        kalshi_get(cfg(), "/markets"; params)
    end
end

# NOTE: literal "/trades" route must be defined before parameterized "/{ticker}"
@get "/api/kalshi/markets/trades" function(req::HTTP.Request)
    safe_call() do
        qp = queryparams(req)
        params = Dict{String,Any}()
        haskey(qp, "ticker") && (params["ticker"] = qp["ticker"])
        haskey(qp, "limit") && (params["limit"] = parse(Int, qp["limit"]))
        haskey(qp, "cursor") && (params["cursor"] = qp["cursor"])
        kalshi_get(cfg(), "/markets/trades"; params)
    end
end

@get "/api/kalshi/markets/{ticker}" function(req::HTTP.Request, ticker::String)
    safe_call() do
        kalshi_get(cfg(), "/markets/$ticker")
    end
end

@get "/api/kalshi/markets/{ticker}/orderbook" function(req::HTTP.Request, ticker::String)
    safe_call() do
        kalshi_get(cfg(), "/markets/$ticker/orderbook")
    end
end

# =============================================================================
# Routes — Events
# =============================================================================

@get "/api/kalshi/events" function(req::HTTP.Request)
    safe_call() do
        qp = queryparams(req)
        params = Dict{String,Any}()
        haskey(qp, "status") && (params["status"] = qp["status"])
        haskey(qp, "series_ticker") && (params["series_ticker"] = qp["series_ticker"])
        haskey(qp, "limit") && (params["limit"] = parse(Int, qp["limit"]))
        haskey(qp, "cursor") && (params["cursor"] = qp["cursor"])
        haskey(qp, "with_nested_markets") && (params["with_nested_markets"] = qp["with_nested_markets"])
        kalshi_get(cfg(), "/events"; params)
    end
end

@get "/api/kalshi/events/{ticker}" function(req::HTTP.Request, ticker::String)
    safe_call() do
        qp = queryparams(req)
        params = Dict{String,Any}()
        haskey(qp, "with_nested_markets") && (params["with_nested_markets"] = qp["with_nested_markets"])
        kalshi_get(cfg(), "/events/$ticker"; params)
    end
end

# =============================================================================
# Routes — Portfolio
# =============================================================================

@get "/api/kalshi/portfolio/balance" function(req::HTTP.Request)
    safe_call() do
        kalshi_get(cfg(), "/portfolio/balance")
    end
end

@get "/api/kalshi/portfolio/positions" function(req::HTTP.Request)
    safe_call() do
        qp = queryparams(req)
        params = Dict{String,Any}()
        haskey(qp, "ticker") && (params["ticker"] = qp["ticker"])
        haskey(qp, "event_ticker") && (params["event_ticker"] = qp["event_ticker"])
        haskey(qp, "settlement_status") && (params["settlement_status"] = qp["settlement_status"])
        haskey(qp, "limit") && (params["limit"] = parse(Int, qp["limit"]))
        haskey(qp, "cursor") && (params["cursor"] = qp["cursor"])
        kalshi_get(cfg(), "/portfolio/positions"; params)
    end
end

@get "/api/kalshi/portfolio/settlements" function(req::HTTP.Request)
    safe_call() do
        qp = queryparams(req)
        params = Dict{String,Any}()
        haskey(qp, "limit") && (params["limit"] = parse(Int, qp["limit"]))
        haskey(qp, "cursor") && (params["cursor"] = qp["cursor"])
        kalshi_get(cfg(), "/portfolio/settlements"; params)
    end
end

@get "/api/kalshi/portfolio/fills" function(req::HTTP.Request)
    safe_call() do
        qp = queryparams(req)
        params = Dict{String,Any}()
        haskey(qp, "ticker") && (params["ticker"] = qp["ticker"])
        haskey(qp, "limit") && (params["limit"] = parse(Int, qp["limit"]))
        haskey(qp, "cursor") && (params["cursor"] = qp["cursor"])
        kalshi_get(cfg(), "/portfolio/fills"; params)
    end
end

# =============================================================================
# Routes — Orders
# =============================================================================

@get "/api/kalshi/orders" function(req::HTTP.Request)
    safe_call() do
        qp = queryparams(req)
        params = Dict{String,Any}()
        haskey(qp, "ticker") && (params["ticker"] = qp["ticker"])
        haskey(qp, "event_ticker") && (params["event_ticker"] = qp["event_ticker"])
        haskey(qp, "status") && (params["status"] = qp["status"])
        haskey(qp, "limit") && (params["limit"] = parse(Int, qp["limit"]))
        haskey(qp, "cursor") && (params["cursor"] = qp["cursor"])
        kalshi_get(cfg(), "/portfolio/orders"; params)
    end
end

@post "/api/kalshi/orders" function(req::HTTP.Request)
    safe_call() do
        body = JSON3.read(String(req.body), Dict)
        kalshi_post(cfg(), "/portfolio/orders"; body)
    end
end

@delete "/api/kalshi/orders/{order_id}" function(req::HTTP.Request, order_id::String)
    safe_call() do
        kalshi_delete(cfg(), "/portfolio/orders/$order_id")
    end
end

# =============================================================================
# Routes — Search / Discovery
# =============================================================================

@get "/api/kalshi/search/tags" function(req::HTTP.Request)
    safe_call() do
        kalshi_get(cfg(), "/search/tags_by_categories")
    end
end

@get "/api/kalshi/series/{ticker}" function(req::HTTP.Request, ticker::String)
    safe_call() do
        kalshi_get(cfg(), "/series/$ticker")
    end
end

# =============================================================================
# Main
# =============================================================================

function main()
    port = 8080
    demo = true
    verbose = false

    for arg in ARGS
        if startswith(arg, "--port=")
            port = parse(Int, split(arg, "=")[2])
        elseif arg == "--live"
            demo = false
        elseif arg == "--verbose"
            verbose = true
        end
    end

    init_config(; demo, verbose)

    env = demo ? "DEMO" : "LIVE"
    println("""
    ============================================================
                    PRAESCIENTIA — KALSHI DASHBOARD
                       Oxygen.jl Web Server
    ============================================================
      Environment:  $env
      Server:       http://localhost:$port
      Dashboard:    http://localhost:$port/

      API Endpoints:
        Exchange:   /api/kalshi/exchange/{status,schedule,announcements}
        Markets:    /api/kalshi/markets[/:ticker][/orderbook]
        Events:     /api/kalshi/events[/:ticker]
        Portfolio:  /api/kalshi/portfolio/{balance,positions,settlements,fills}
        Orders:     /api/kalshi/orders (GET/POST/DELETE)
        Search:     /api/kalshi/search/tags
        Series:     /api/kalshi/series/:ticker
    ============================================================
    """)

    serve(; host="0.0.0.0", port, show_banner=false, middleware=[cors_middleware])
end

function cors_middleware(handler)
    return function(req::HTTP.Request)
        if req.method == "OPTIONS"
            return HTTP.Response(200, [
                "Access-Control-Allow-Origin" => "*",
                "Access-Control-Allow-Methods" => "GET, POST, PUT, DELETE, OPTIONS",
                "Access-Control-Allow-Headers" => "Content-Type"
            ])
        end
        resp = handler(req)
        HTTP.setheader(resp, "Access-Control-Allow-Origin" => "*")
        return resp
    end
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end

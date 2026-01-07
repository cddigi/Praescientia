#!/usr/bin/env julia
"""
    Praescientia API Server (Julia)

HTTP server with JSONL blockchain-style transaction logging.
Each portfolio has a dedicated JSONL file tracking all transactions.

Usage:
  julia --project=. server.jl
  julia --project=. server.jl --port=8080

Endpoints:
  GET  /                           - Serve dashboard
  GET  /api/portfolios             - Get all portfolio states
  GET  /api/portfolios/:id         - Get specific portfolio state
  GET  /api/portfolios/:id/logs    - Get transaction log stats
  GET  /api/portfolios/:id/txs     - Get raw transactions
  POST /api/portfolios/:id/init    - Initialize a new portfolio
  POST /api/trades                 - Execute trades
  POST /api/reset                  - Reset all portfolios to defaults
  GET  /api/audit/:id              - Audit portfolio chain integrity
"""

using HTTP
using JSON3
using Dates

# Include the TxLog module
include(joinpath(@__DIR__, "src", "TxLog.jl"))
using .TxLog

# Server configuration
const DEFAULT_PORT = 3000
const SERVER_ROOT = @__DIR__

# Default portfolio definitions (for initialization)
const DEFAULT_PORTFOLIOS = Dict(
    "daily" => Dict(
        "name" => "Daily (Jan 7)",
        "color" => "#4dabf7",
        "status" => "closed",
        "positions" => [
            Dict("id" => "d1", "market" => "BTC Up/Down Jan 7", "position" => "UP", "shares" => 26, "price" => 0.575, "confidence" => 0, "action" => "closed", "reason" => "Market resolved"),
            Dict("id" => "d2", "market" => "ETH Up/Down Jan 7", "position" => "UP", "shares" => 24, "price" => 0.62, "confidence" => 0, "action" => "closed", "reason" => "Market resolved"),
            Dict("id" => "d3", "market" => "SOL Up/Down Jan 7", "position" => "DOWN", "shares" => 26, "price" => 0.38, "confidence" => 0, "action" => "closed", "reason" => "Market resolved"),
            Dict("id" => "d4", "market" => "SPX Up/Down Jan 7", "position" => "DOWN", "shares" => 25, "price" => 0.395, "confidence" => 0, "action" => "closed", "reason" => "Market resolved"),
        ]
    ),
    "weekly" => Dict(
        "name" => "Weekly (Jan 6-12)",
        "color" => "#da77f2",
        "status" => "active",
        "positions" => [
            Dict("id" => "w1", "market" => "BTC hits \$100k", "position" => "NO", "shares" => 115, "price" => 0.87, "confidence" => 85, "action" => "hold", "reason" => "High confidence, near max profit"),
            Dict("id" => "w2", "market" => "ETH dips to \$3k", "position" => "NO", "shares" => 95, "price" => 0.84, "confidence" => 80, "action" => "hold", "reason" => "Strong support above \$3k"),
            Dict("id" => "w3", "market" => "BTC dips to \$88k", "position" => "NO", "shares" => 90, "price" => 0.78, "confidence" => 65, "action" => "sell", "reason" => "BTC weakness - consider taking profit"),
            Dict("id" => "w4", "market" => "ETH hits \$3.4k", "position" => "NO", "shares" => 89, "price" => 0.996, "confidence" => 90, "action" => "hold", "reason" => "Already flipped, ride to resolution"),
            Dict("id" => "w5", "market" => "BTC hits \$96k", "position" => "NO", "shares" => 80, "price" => 0.996, "confidence" => 85, "action" => "hold", "reason" => "Already flipped, ride to resolution"),
            Dict("id" => "w6", "market" => "SOL hits \$150", "position" => "NO", "shares" => 112, "price" => 0.71, "confidence" => 75, "action" => "sell", "reason" => "SOL recovering - lock in gains"),
        ]
    ),
    "contrarian" => Dict(
        "name" => "Contrarian (2026)",
        "color" => "#ff922b",
        "status" => "pending",
        "positions" => [
            Dict("id" => "c1", "market" => "US Recession 2026", "position" => "YES", "shares" => 235, "price" => 0.255, "confidence" => 70, "action" => "buy", "reason" => "Sahm Rule triggered - add to position"),
            Dict("id" => "c2", "market" => "Fed Rate Hike 2026", "position" => "YES", "shares" => 175, "price" => 0.115, "confidence" => 55, "action" => "hold", "reason" => "Wait for inflation data"),
            Dict("id" => "c3", "market" => "Fed Emergency Cut", "position" => "YES", "shares" => 154, "price" => 0.130, "confidence" => 60, "action" => "hold", "reason" => "Tail risk position - hold"),
        ]
    )
)

# =============================================================================
# Helper Functions
# =============================================================================

"""
    json_response(data; status=200) -> HTTP.Response

Create a JSON HTTP response.
"""
function json_response(data; status::Int=200)
    body = JSON3.write(data)
    return HTTP.Response(status, [
        "Content-Type" => "application/json",
        "Access-Control-Allow-Origin" => "*",
        "Access-Control-Allow-Methods" => "GET, POST, OPTIONS",
        "Access-Control-Allow-Headers" => "Content-Type"
    ], body)
end

"""
    error_response(message, status=500) -> HTTP.Response

Create an error JSON response.
"""
function error_response(message::String; status::Int=500)
    return json_response(Dict("success" => false, "error" => message); status=status)
end

"""
    success_response(data) -> HTTP.Response

Create a success JSON response.
"""
function success_response(data)
    return json_response(Dict("success" => true, "data" => data, "lastUpdated" => Dates.format(now(UTC), "yyyy-mm-ddTHH:MM:SS.sssZ")))
end

"""
    read_static_file(path) -> HTTP.Response

Read and serve a static file.
"""
function read_static_file(path::String)
    full_path = joinpath(SERVER_ROOT, path)

    if !isfile(full_path)
        return HTTP.Response(404, "Not Found")
    end

    # Determine content type
    ext = lowercase(splitext(path)[2])
    content_type = if ext == ".html"
        "text/html"
    elseif ext == ".js"
        "application/javascript"
    elseif ext == ".css"
        "text/css"
    elseif ext == ".json"
        "application/json"
    elseif ext == ".png"
        "image/png"
    elseif ext == ".svg"
        "image/svg+xml"
    else
        "application/octet-stream"
    end

    content = read(full_path)
    return HTTP.Response(200, ["Content-Type" => content_type], content)
end

"""
    initialize_portfolio(portfolio_id) -> Nothing

Initialize a portfolio with default positions.
"""
function initialize_portfolio(portfolio_id::String)
    def = get(DEFAULT_PORTFOLIOS, portfolio_id, nothing)
    if def === nothing
        error("Unknown portfolio: $portfolio_id")
    end

    # Create genesis transaction
    TxLog.init_portfolio(portfolio_id, Dict(
        "name" => def["name"],
        "color" => def["color"],
        "status" => def["status"],
        "description" => "Initialized $(def["name"]) portfolio"
    ))

    # Record initial positions as BUY transactions
    for pos in def["positions"]
        TxLog.record_buy(portfolio_id;
            positionId=pos["id"],
            market=pos["market"],
            position=pos["position"],
            shares=pos["shares"],
            price=pos["price"],
            confidence=pos["confidence"],
            action=pos["action"],
            reason=pos["reason"]
        )
    end

    @info "Initialized portfolio" portfolio_id
end

"""
    get_portfolio_for_dashboard(portfolio_id) -> Dict

Get portfolio state in dashboard-compatible format.
"""
function get_portfolio_for_dashboard(portfolio_id::String)
    state = TxLog.calculate_state(portfolio_id)
    def = get(DEFAULT_PORTFOLIOS, portfolio_id, Dict())

    # Convert positions to dashboard format
    positions = []
    for (_, pos) in state["positions"]
        push!(positions, Dict(
            "id" => get(pos, "id", ""),
            "market" => get(pos, "market", ""),
            "position" => get(pos, "position", ""),
            "entry" => get(pos, "avgEntry", 0.0),
            "current" => get(pos, "current", 0.0),
            "cost" => get(pos, "totalCost", 0.0),
            "pl" => get(pos, "pl", 0.0),
            "confidence" => get(pos, "confidence", 50),
            "action" => get(pos, "action", "hold"),
            "reason" => get(pos, "reason", ""),
            "exit" => get(pos, "exit", nothing)
        ))
    end

    # Calculate starting value from initial positions
    starting = sum(p["entry"] * (p["cost"] / max(p["entry"], 0.001)) for p in positions; init=0.0)
    if starting == 0 && haskey(def, "positions")
        starting = sum(p["shares"] * p["price"] for p in def["positions"])
    end

    return Dict(
        "name" => get(state, "name", get(def, "name", "")),
        "color" => get(state, "color", get(def, "color", "")),
        "starting" => starting,
        "realized" => state["realized"],
        "unrealized" => state["unrealized"],
        "status" => get(state, "status", "active"),
        "positions" => positions,
        "timeline" => [
            Dict("date" => "2026-01-06", "value" => starting),
            Dict("date" => "2026-01-07", "value" => starting + state["realized"] + state["unrealized"])
        ]
    )
end

# =============================================================================
# Request Handlers
# =============================================================================

"""
    handle_request(req) -> HTTP.Response

Main request router.
"""
function handle_request(req::HTTP.Request)
    method = req.method
    path = HTTP.URI(req.target).path

    # Handle CORS preflight
    if method == "OPTIONS"
        return HTTP.Response(200, [
            "Access-Control-Allow-Origin" => "*",
            "Access-Control-Allow-Methods" => "GET, POST, OPTIONS",
            "Access-Control-Allow-Headers" => "Content-Type"
        ])
    end

    try
        # Static files
        if method == "GET" && (path == "/" || path == "/dashboard.html")
            return read_static_file("dashboard.html")
        end

        # API routes
        if startswith(path, "/api/")
            return handle_api(req, method, path)
        end

        # Other static files
        if method == "GET"
            # Remove leading slash
            file_path = path[2:end]
            return read_static_file(file_path)
        end

        return HTTP.Response(404, "Not Found")

    catch e
        @error "Request handler error" exception=e
        return error_response(string(e); status=500)
    end
end

"""
    handle_api(req, method, path) -> HTTP.Response

Handle API routes.
"""
function handle_api(req::HTTP.Request, method::String, path::String)
    # Parse path segments
    segments = filter(!isempty, split(path, "/"))

    # GET /api/portfolios - Get all portfolio states
    if method == "GET" && path == "/api/portfolios"
        portfolio_ids = TxLog.list_portfolios()

        # If no portfolios exist, initialize defaults
        if isempty(portfolio_ids)
            for id in keys(DEFAULT_PORTFOLIOS)
                initialize_portfolio(id)
            end
            portfolio_ids = collect(keys(DEFAULT_PORTFOLIOS))
        end

        portfolios = Dict{String, Any}()
        for id in portfolio_ids
            portfolios[id] = get_portfolio_for_dashboard(id)
        end

        return success_response(portfolios)
    end

    # GET /api/portfolios/:id - Get specific portfolio state
    if method == "GET" && length(segments) == 3 && segments[2] == "portfolios"
        portfolio_id = segments[3]
        portfolio = get_portfolio_for_dashboard(portfolio_id)
        return success_response(portfolio)
    end

    # GET /api/portfolios/:id/logs - Get transaction log stats
    if method == "GET" && length(segments) == 4 && segments[2] == "portfolios" && segments[4] == "logs"
        portfolio_id = segments[3]
        stats = TxLog.get_log_stats(portfolio_id)
        return success_response(stats)
    end

    # GET /api/portfolios/:id/txs - Get raw transactions
    if method == "GET" && length(segments) == 4 && segments[2] == "portfolios" && segments[4] == "txs"
        portfolio_id = segments[3]
        log_path = TxLog.get_log_path(portfolio_id)
        transactions = TxLog.read_transactions(log_path)
        return success_response(Dict("transactions" => transactions, "count" => length(transactions)))
    end

    # POST /api/portfolios/:id/init - Initialize a new portfolio
    if method == "POST" && length(segments) == 4 && segments[2] == "portfolios" && segments[4] == "init"
        portfolio_id = segments[3]
        initialize_portfolio(portfolio_id)
        portfolio = get_portfolio_for_dashboard(portfolio_id)
        return success_response(portfolio)
    end

    # POST /api/trades - Execute trades
    if method == "POST" && path == "/api/trades"
        body = JSON3.read(String(req.body))
        actions = get(body, :actions, Dict())

        results = Dict(
            "bought" => 0,
            "sold" => 0,
            "flipped" => 0,
            "transactions" => []
        )

        # Get current states to look up position details
        portfolio_ids = TxLog.list_portfolios()
        states = Dict{String, Any}()
        for id in portfolio_ids
            states[id] = TxLog.calculate_state(id)
        end

        # Process SELL actions
        for pos in get(actions, :sell, [])
            pos_id = string(get(pos, :id, ""))
            for (portfolio_id, state) in states
                positions = state["positions"]
                if haskey(positions, pos_id)
                    position = positions[pos_id]
                    tx = TxLog.record_sell(portfolio_id;
                        positionId=pos_id,
                        shares=position["shares"],
                        price=position["current"],
                        reason="User executed sell"
                    )
                    results["sold"] += 1
                    push!(results["transactions"], tx)
                    break
                end
            end
        end

        # Process BUY actions (add to position - record adjust)
        for pos in get(actions, :buy, [])
            pos_id = string(get(pos, :id, ""))
            for (portfolio_id, state) in states
                positions = state["positions"]
                if haskey(positions, pos_id)
                    tx = TxLog.record_adjust(portfolio_id;
                        positionId=pos_id,
                        action="hold",
                        reason="Added to position"
                    )
                    results["bought"] += 1
                    push!(results["transactions"], tx)
                    break
                end
            end
        end

        # Process FLIP actions
        for pos in get(actions, :flip, [])
            pos_id = string(get(pos, :id, ""))
            for (portfolio_id, state) in states
                positions = state["positions"]
                if haskey(positions, pos_id)
                    position = positions[pos_id]
                    tx = TxLog.record_flip(portfolio_id;
                        positionId=pos_id,
                        price=position["current"],
                        reason="User flipped position"
                    )
                    results["flipped"] += 1
                    push!(results["transactions"], tx)
                    break
                end
            end
        end

        return json_response(Dict(
            "success" => true,
            "results" => results,
            "message" => "Bought $(results["bought"]), Sold $(results["sold"]), Flipped $(results["flipped"]) position(s)"
        ))
    end

    # POST /api/reset - Reset all portfolios to defaults
    if method == "POST" && path == "/api/reset"
        # Delete all JSONL files
        for f in readdir(TxLog.PORTFOLIOS_DIR)
            if endswith(f, ".jsonl")
                rm(joinpath(TxLog.PORTFOLIOS_DIR, f))
            end
        end

        # Re-initialize all portfolios
        for id in keys(DEFAULT_PORTFOLIOS)
            initialize_portfolio(id)
        end

        return json_response(Dict("success" => true, "message" => "All portfolios reset to defaults"))
    end

    # GET /api/audit/:id - Audit portfolio chain integrity
    if method == "GET" && length(segments) == 3 && segments[2] == "audit"
        portfolio_id = segments[3]
        chain_result = TxLog.verify_chain(portfolio_id)
        stats = TxLog.get_log_stats(portfolio_id)

        return success_response(Dict(
            "chainIntegrity" => chain_result,
            "logStats" => stats
        ))
    end

    # GET /api/audit/:id/archive/:archive - Audit checkpoint against archive
    if method == "GET" && length(segments) == 5 && segments[2] == "audit" && segments[4] == "archive"
        portfolio_id = segments[3]
        archive_name = segments[5]
        archive_path = joinpath(TxLog.ARCHIVE_DIR, archive_name)
        audit_result = TxLog.audit_checkpoint(portfolio_id, archive_path)
        return success_response(audit_result)
    end

    return HTTP.Response(404, "API endpoint not found")
end

# =============================================================================
# Server Main
# =============================================================================

function main()
    # Parse command line arguments
    port = DEFAULT_PORT
    for arg in ARGS
        if startswith(arg, "--port=")
            port = parse(Int, split(arg, "=")[2])
        end
    end

    # Ensure directories exist
    TxLog.ensure_directories()

    println("""
    ============================================================
                       PRAESCIENTIA API
              JSONL Blockchain Transaction Log (Julia)
    ============================================================
      Server running at: http://localhost:$port
      Dashboard:         http://localhost:$port/

      API Endpoints:
        GET  /api/portfolios              - Get all portfolios
        GET  /api/portfolios/:id          - Get specific portfolio
        GET  /api/portfolios/:id/logs     - Transaction log stats
        GET  /api/portfolios/:id/txs      - Raw transactions
        POST /api/trades                  - Execute trades
        POST /api/reset                   - Reset to defaults
        GET  /api/audit/:id               - Audit chain integrity

      Transaction Logs:
        portfolios/*.jsonl                - Active logs
        portfolios/archive/*_<ts>.jsonl   - Archived logs (>1MB)
    ============================================================
    """)

    # Start HTTP server
    HTTP.serve(handle_request, "0.0.0.0", port)
end

# Run if executed directly
if abspath(PROGRAM_FILE) == @__FILE__
    main()
end

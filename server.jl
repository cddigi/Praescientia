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

# Portfolio colors for different types
const PORTFOLIO_COLORS = Dict(
    "daily" => "#4dabf7",
    "weekly" => "#da77f2",
    "contrarian" => "#ff922b",
    "default" => "#69db7c"
)

"""
    discover_portfolios() -> Dict{String, Dict}

Discover all portfolios from:
- portfolios/*.jsonl (transaction logs)
- portfolios/*.md (markdown files)
- data/*.json (JSON data files)
"""
function discover_portfolios()
    portfolios = Dict{String, Dict}()

    # 1. Discover from JSONL transaction logs
    for f in readdir(TxLog.PORTFOLIOS_DIR)
        if endswith(f, ".jsonl")
            portfolio_id = replace(f, ".jsonl" => "")
            portfolios[portfolio_id] = Dict(
                "source" => "jsonl",
                "path" => joinpath(TxLog.PORTFOLIOS_DIR, f)
            )
        end
    end

    # 2. Discover from markdown files
    for f in readdir(TxLog.PORTFOLIOS_DIR)
        if endswith(f, ".md") && !startswith(f, "seneca")  # Skip strategy docs
            # Extract portfolio ID from filename (e.g., "daily_jan9_2026.md" -> "daily_jan9")
            portfolio_id = replace(f, ".md" => "")
            # Simplify: remove date suffix for grouping if desired, or keep full name
            if !haskey(portfolios, portfolio_id)
                portfolios[portfolio_id] = Dict(
                    "source" => "markdown",
                    "path" => joinpath(TxLog.PORTFOLIOS_DIR, f)
                )
            end
        end
    end

    # 3. Discover from data/*.json files
    data_dir = joinpath(SERVER_ROOT, "data")
    if isdir(data_dir)
        for f in readdir(data_dir)
            if endswith(f, ".json") && contains(f, "predictions")
                portfolio_id = replace(f, ".json" => "")
                if !haskey(portfolios, portfolio_id)
                    portfolios[portfolio_id] = Dict(
                        "source" => "json",
                        "path" => joinpath(data_dir, f)
                    )
                end
            end
        end
    end

    return portfolios
end

"""
    parse_markdown_portfolio(path::String) -> Dict

Parse a markdown portfolio file for display data.
"""
function parse_markdown_portfolio(path::String)
    content = read(path, String)
    lines = split(content, '\n')

    result = Dict{String, Any}(
        "name" => "",
        "status" => "active",
        "color" => PORTFOLIO_COLORS["default"],
        "positions" => [],
        "starting" => 0.0,
        "realized" => 0.0,
        "unrealized" => 0.0,
        "timeline" => []
    )

    # Extract title from first H1
    for line in lines
        if startswith(line, "# ")
            result["name"] = strip(replace(line, "# " => ""))
            break
        end
    end

    # Determine color based on filename
    filename = lowercase(basename(path))
    if contains(filename, "daily")
        result["color"] = PORTFOLIO_COLORS["daily"]
    elseif contains(filename, "week")
        result["color"] = PORTFOLIO_COLORS["weekly"]
    elseif contains(filename, "contrarian")
        result["color"] = PORTFOLIO_COLORS["contrarian"]
    end

    # Extract status
    for line in lines
        lower_line = lowercase(line)
        if contains(lower_line, "status:")
            if contains(lower_line, "closed")
                result["status"] = "closed"
            elseif contains(lower_line, "active")
                result["status"] = "active"
            elseif contains(lower_line, "pending")
                result["status"] = "pending"
            end
            break
        end
    end

    # Parse positions table
    in_positions_table = false
    header_found = false
    for line in lines
        stripped = strip(line)

        # Detect position table headers
        if contains(stripped, "| #") && contains(stripped, "Market") && contains(stripped, "Position")
            in_positions_table = true
            header_found = false
            continue
        end

        # Skip header separator line
        if in_positions_table && !header_found && startswith(stripped, "|") && contains(stripped, ":-")
            header_found = true
            continue
        end

        # Parse position rows
        if in_positions_table && header_found && startswith(stripped, "|") && !contains(stripped, ":-")
            cells = [strip(c) for c in split(stripped, "|") if !isempty(strip(c))]
            if length(cells) >= 6
                try
                    pos_num = tryparse(Int, replace(cells[1], r"[^0-9]" => ""))
                    market = cells[2]
                    position = replace(cells[3], r"\*+" => "")
                    entry_str = replace(cells[4], r"[^\d.]" => "")
                    entry = tryparse(Float64, entry_str)
                    shares_str = replace(cells[5], r"[^\d.]" => "")
                    shares = tryparse(Float64, shares_str)
                    cost_str = replace(cells[6], r"[^\d.]" => "")
                    cost = tryparse(Float64, cost_str)

                    if entry !== nothing && shares !== nothing && cost !== nothing
                        push!(result["positions"], Dict(
                            "id" => "p$(pos_num !== nothing ? pos_num : length(result["positions"]) + 1)",
                            "market" => market,
                            "position" => position,
                            "entry" => entry,
                            "current" => entry,  # Default to entry
                            "shares" => shares,
                            "cost" => cost,
                            "pl" => 0.0,
                            "confidence" => 50,
                            "action" => "hold",
                            "reason" => ""
                        ))
                    end
                catch e
                    @debug "Failed to parse position row" line exception=e
                end
            end
        end

        # End of table detection
        if in_positions_table && header_found && !startswith(stripped, "|") && !isempty(stripped)
            in_positions_table = false
        end
    end

    # Calculate starting value
    result["starting"] = sum(p["cost"] for p in result["positions"]; init=0.0)

    return result
end

"""
    parse_json_portfolio(path::String) -> Dict

Parse a JSON data file for portfolio data.
"""
function parse_json_portfolio(path::String)
    content = read(path, String)
    data = JSON3.read(content, Dict)

    metadata = get(data, "metadata", Dict())
    positions_data = get(data, "positions", [])

    result = Dict{String, Any}(
        "name" => get(metadata, "portfolio_name", basename(path)),
        "status" => lowercase(get(metadata, "status", "active")),
        "color" => PORTFOLIO_COLORS["weekly"],  # Default
        "positions" => [],
        "starting" => 0.0,
        "realized" => 0.0,
        "unrealized" => 0.0,
        "timeline" => []
    )

    # Parse positions
    for pos in positions_data
        push!(result["positions"], Dict(
            "id" => get(pos, "id", ""),
            "market" => get(pos, "market", ""),
            "position" => get(pos, "position", ""),
            "entry" => get(pos, "entry_price", 0.0),
            "current" => get(pos, "entry_price", 0.0),
            "shares" => get(pos, "shares", 0),
            "cost" => get(pos, "cost", 0.0),
            "pl" => get(pos, "pnl", 0.0),
            "confidence" => round(Int, get(pos, "confidence", 0.5) * 100),
            "action" => "hold",
            "reason" => get(pos, "reasoning", "")
        ))
    end

    # Get summary data
    summary = get(data, "summary", Dict())
    result["starting"] = get(summary, "total_invested", sum(p["cost"] for p in result["positions"]; init=0.0))

    # Parse timeline from daily_tracking
    tracking = get(data, "daily_tracking", [])
    for entry in tracking
        push!(result["timeline"], Dict(
            "date" => get(entry, "date", ""),
            "value" => get(entry, "portfolio_value", result["starting"])
        ))
    end

    return result
end

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
function read_static_file(path::AbstractString)
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
function initialize_portfolio(portfolio_id::AbstractString)
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

Get portfolio state in dashboard-compatible format (from JSONL transaction log).
"""
function get_portfolio_for_dashboard(portfolio_id::AbstractString)
    state = TxLog.calculate_state(portfolio_id)

    # Convert positions to dashboard format
    positions = []
    total_cost = 0.0
    for (_, pos) in state["positions"]
        cost = get(pos, "totalCost", 0.0)
        total_cost += cost
        push!(positions, Dict(
            "id" => get(pos, "id", ""),
            "market" => get(pos, "market", ""),
            "position" => get(pos, "position", ""),
            "entry" => get(pos, "avgEntry", 0.0),
            "current" => get(pos, "current", 0.0),
            "cost" => cost,
            "pl" => get(pos, "pl", 0.0),
            "confidence" => get(pos, "confidence", 50),
            "action" => get(pos, "action", "hold"),
            "reason" => get(pos, "reason", ""),
            "exit" => get(pos, "exit", nothing)
        ))
    end

    # Calculate starting value from positions
    starting = total_cost > 0 ? total_cost : sum(p["cost"] for p in positions; init=0.0)

    # Determine color based on portfolio ID
    color = if contains(portfolio_id, "daily")
        PORTFOLIO_COLORS["daily"]
    elseif contains(portfolio_id, "week")
        PORTFOLIO_COLORS["weekly"]
    elseif contains(portfolio_id, "contrarian")
        PORTFOLIO_COLORS["contrarian"]
    else
        get(state, "color", PORTFOLIO_COLORS["default"])
    end

    return Dict(
        "name" => get(state, "name", portfolio_id),
        "color" => color,
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
function handle_api(req::HTTP.Request, method::AbstractString, path::AbstractString)
    # Parse path segments
    segments = filter(!isempty, split(path, "/"))

    # GET /api/portfolios - Get all portfolio states (dynamic discovery)
    if method == "GET" && path == "/api/portfolios"
        discovered = discover_portfolios()

        portfolios = Dict{String, Any}()
        for (id, info) in discovered
            try
                source = get(info, "source", "")
                filepath = get(info, "path", "")

                if source == "jsonl"
                    portfolios[id] = get_portfolio_for_dashboard(id)
                elseif source == "markdown"
                    portfolios[id] = parse_markdown_portfolio(filepath)
                elseif source == "json"
                    portfolios[id] = parse_json_portfolio(filepath)
                end
            catch e
                @warn "Failed to load portfolio" id exception=e
            end
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

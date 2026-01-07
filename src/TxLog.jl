"""
    TxLog - JSONL Transaction Log (Blockchain-style)

Each portfolio has a dedicated JSONL file tracking all transactions.
Current holdings are calculated by parsing the transaction log.

Transaction Types:
  - GENESIS:    Initial portfolio creation
  - CHECKPOINT: Summation of all positions (used when rotating logs)
  - BUY:        Purchase shares
  - SELL:       Sell shares
  - FLIP:       Flip position (YES<->NO, UP<->DOWN)
  - RESOLVE:    Market resolved, position closed
  - ADJUST:     Price/confidence updates

File Structure:
  portfolios/<portfolio_id>.jsonl     - Active transaction log
  portfolios/archive/<portfolio_id>_<timestamp>.jsonl - Archived logs

Archive Trigger: File size >= 1MB
"""
module TxLog

using JSON3
using SHA
using Dates
using UUIDs

export TX_TYPE, PORTFOLIOS_DIR, ARCHIVE_DIR, MAX_LOG_SIZE
export generate_tx_id, hash_transaction, get_log_path
export ensure_directories, read_transactions, append_transaction
export init_portfolio, record_buy, record_sell, record_flip, record_resolve, record_adjust
export calculate_state, rotate_log, verify_chain, audit_checkpoint
export list_portfolios, list_archives, get_log_stats

# Constants
const PORTFOLIOS_DIR = joinpath(@__DIR__, "..", "portfolios")
const ARCHIVE_DIR = joinpath(PORTFOLIOS_DIR, "archive")
const MAX_LOG_SIZE = 1024 * 1024  # 1MB

# Transaction types
const TX_TYPE = (
    GENESIS = "GENESIS",
    CHECKPOINT = "CHECKPOINT",
    BUY = "BUY",
    SELL = "SELL",
    FLIP = "FLIP",
    RESOLVE = "RESOLVE",
    ADJUST = "ADJUST"
)

"""
    generate_tx_id() -> String

Generate a unique transaction ID using timestamp and random bytes.
"""
function generate_tx_id()
    timestamp = string(round(Int, time() * 1000), base=36)
    random = bytes2hex(rand(UInt8, 4))
    return "tx_$(timestamp)_$(random)"
end

"""
    hash_transaction(tx::Dict) -> String

Generate a SHA-256 hash of a transaction (first 16 chars).
"""
function hash_transaction(tx::Dict)
    data = JSON3.write(tx)
    return bytes2hex(sha256(data))[1:16]
end

"""
    get_log_path(portfolio_id::String) -> String

Get the log file path for a portfolio.
"""
function get_log_path(portfolio_id::String)
    return joinpath(PORTFOLIOS_DIR, "$(portfolio_id).jsonl")
end

"""
    ensure_directories()

Ensure portfolio and archive directories exist.
"""
function ensure_directories()
    mkpath(PORTFOLIOS_DIR)
    mkpath(ARCHIVE_DIR)
end

"""
    get_file_size(file_path::String) -> Int

Get file size in bytes, or 0 if file doesn't exist.
"""
function get_file_size(file_path::String)
    try
        return filesize(file_path)
    catch
        return 0
    end
end

"""
    read_transactions(file_path::String) -> Vector{Dict}

Read all transactions from a JSONL file.
"""
function read_transactions(file_path::String)
    transactions = Dict[]

    if !isfile(file_path)
        return transactions
    end

    try
        for line in eachline(file_path)
            stripped = strip(line)
            if !isempty(stripped)
                tx = JSON3.read(stripped, Dict)
                push!(transactions, tx)
            end
        end
    catch e
        @error "Error reading transactions" file_path exception=e
    end

    return transactions
end

"""
    append_transaction(portfolio_id::String, tx::Dict) -> Dict

Append a transaction to the portfolio log, handling rotation if needed.
"""
function append_transaction(portfolio_id::String, tx::Dict)
    ensure_directories()
    log_path = get_log_path(portfolio_id)

    # Check if rotation needed
    if get_file_size(log_path) >= MAX_LOG_SIZE
        rotate_log(portfolio_id)
    end

    # Get last transaction hash for chain integrity
    transactions = read_transactions(log_path)
    prev_hash = if isempty(transactions)
        "0" ^ 16
    else
        hash_transaction(transactions[end])
    end

    # Complete the transaction
    full_tx = Dict{String, Any}(
        "id" => generate_tx_id(),
        "timestamp" => Dates.format(now(UTC), "yyyy-mm-ddTHH:MM:SS.sssZ"),
        "prevHash" => prev_hash
    )

    # Merge in the provided transaction data
    for (k, v) in tx
        full_tx[string(k)] = v
    end

    # Append to file
    open(log_path, "a") do io
        println(io, JSON3.write(full_tx))
    end

    return full_tx
end

"""
    rotate_log(portfolio_id::String) -> Union{String, Nothing}

Rotate log file to archive, creating a checkpoint in the new log.
"""
function rotate_log(portfolio_id::String)
    ensure_directories()
    log_path = get_log_path(portfolio_id)

    if get_file_size(log_path) == 0
        return nothing
    end

    # Calculate current state before archiving
    state = calculate_state(portfolio_id)

    # Archive current log
    timestamp = replace(Dates.format(now(UTC), "yyyy-mm-ddTHH:MM:SS.sss"), ":" => "-", "." => "-")
    archive_path = joinpath(ARCHIVE_DIR, "$(portfolio_id)_$(timestamp).jsonl")
    mv(log_path, archive_path)

    # Create new log with CHECKPOINT entry
    checkpoint_tx = Dict(
        "type" => TX_TYPE.CHECKPOINT,
        "description" => "Checkpoint from archived log: $(basename(archive_path))",
        "positions" => state["positions"],
        "realized" => state["realized"],
        "unrealized" => state["unrealized"]
    )

    append_transaction(portfolio_id, checkpoint_tx)

    @info "Rotated log" portfolio_id archive_path
    return archive_path
end

"""
    calculate_state(portfolio_id::String) -> Dict

Calculate current portfolio state from transaction log.
"""
function calculate_state(portfolio_id::String)
    log_path = get_log_path(portfolio_id)
    transactions = read_transactions(log_path)

    # Initialize state
    state = Dict{String, Any}(
        "portfolioId" => portfolio_id,
        "positions" => Dict{String, Any}(),
        "realized" => 0.0,
        "unrealized" => 0.0,
        "transactionCount" => length(transactions)
    )

    positions = state["positions"]

    for tx in transactions
        tx_type = get(tx, "type", "")

        if tx_type == TX_TYPE.GENESIS
            state["name"] = get(tx, "name", "")
            state["color"] = get(tx, "color", "")
            state["status"] = get(tx, "status", "active")

        elseif tx_type == TX_TYPE.CHECKPOINT
            # Restore state from checkpoint
            state["positions"] = copy(get(tx, "positions", Dict()))
            positions = state["positions"]
            state["realized"] = get(tx, "realized", 0.0)
            state["unrealized"] = get(tx, "unrealized", 0.0)

        elseif tx_type == TX_TYPE.BUY
            pos_id = get(tx, "positionId", "")
            if !haskey(positions, pos_id)
                positions[pos_id] = Dict{String, Any}(
                    "id" => pos_id,
                    "market" => get(tx, "market", ""),
                    "position" => get(tx, "position", ""),
                    "shares" => 0,
                    "totalCost" => 0.0,
                    "avgEntry" => 0.0,
                    "current" => get(tx, "price", 0.0),
                    "confidence" => get(tx, "confidence", 50),
                    "action" => "hold",
                    "reason" => get(tx, "reason", "")
                )
            end

            pos = positions[pos_id]
            shares = get(tx, "shares", 0)
            price = get(tx, "price", 0.0)
            new_shares = pos["shares"] + shares
            new_cost = pos["totalCost"] + shares * price

            pos["shares"] = new_shares
            pos["totalCost"] = new_cost
            pos["avgEntry"] = new_shares > 0 ? new_cost / new_shares : 0.0
            pos["current"] = price

            if haskey(tx, "confidence")
                pos["confidence"] = tx["confidence"]
            end
            if haskey(tx, "action")
                pos["action"] = tx["action"]
            end
            if haskey(tx, "reason")
                pos["reason"] = tx["reason"]
            end

        elseif tx_type == TX_TYPE.SELL
            pos_id = get(tx, "positionId", "")
            if haskey(positions, pos_id)
                pos = positions[pos_id]
                sell_shares = min(get(tx, "shares", 0), pos["shares"])
                price = get(tx, "price", 0.0)
                cost_basis = pos["avgEntry"] * sell_shares
                proceeds = price * sell_shares
                pnl = proceeds - cost_basis

                pos["shares"] -= sell_shares
                pos["totalCost"] -= cost_basis
                state["realized"] += pnl

                if pos["shares"] <= 0
                    pos["action"] = "closed"
                    pos["reason"] = get(tx, "reason", "Position sold")
                    pos["exit"] = price
                end
            end

        elseif tx_type == TX_TYPE.FLIP
            pos_id = get(tx, "positionId", "")
            if haskey(positions, pos_id)
                pos = positions[pos_id]
                # Flip direction
                if pos["position"] == "YES"
                    pos["position"] = "NO"
                elseif pos["position"] == "NO"
                    pos["position"] = "YES"
                elseif pos["position"] == "UP"
                    pos["position"] = "DOWN"
                elseif pos["position"] == "DOWN"
                    pos["position"] = "UP"
                end

                pos["avgEntry"] = get(tx, "price", pos["avgEntry"])
                pos["current"] = get(tx, "price", pos["current"])
                pos["action"] = "hold"
                pos["reason"] = get(tx, "reason", "Position flipped")
            end

        elseif tx_type == TX_TYPE.RESOLVE
            pos_id = get(tx, "positionId", "")
            if haskey(positions, pos_id)
                pos = positions[pos_id]
                outcome = get(tx, "outcome", false)
                resolve_pnl = (outcome ? 1.0 : 0.0) * pos["shares"] - pos["totalCost"]
                state["realized"] += resolve_pnl
                pos["action"] = "closed"
                pos["reason"] = "Resolved: $(outcome ? "WIN" : "LOSS")"
                pos["exit"] = outcome ? 1.0 : 0.0
                pos["shares"] = 0
            end

        elseif tx_type == TX_TYPE.ADJUST
            pos_id = get(tx, "positionId", "")
            if haskey(positions, pos_id)
                pos = positions[pos_id]
                if haskey(tx, "current")
                    pos["current"] = tx["current"]
                end
                if haskey(tx, "confidence")
                    pos["confidence"] = tx["confidence"]
                end
                if haskey(tx, "action")
                    pos["action"] = tx["action"]
                end
                if haskey(tx, "reason")
                    pos["reason"] = tx["reason"]
                end
            end
        end
    end

    # Calculate unrealized P/L
    state["unrealized"] = 0.0
    for (_, pos) in positions
        if pos["shares"] > 0 && get(pos, "action", "") != "closed"
            current_value = pos["current"] * pos["shares"]
            cost_basis = pos["totalCost"]
            pos["pl"] = current_value - cost_basis
            state["unrealized"] += pos["pl"]
        else
            pos["pl"] = 0.0
        end
    end

    return state
end

"""
    init_portfolio(portfolio_id::String, metadata::Dict) -> Dict

Initialize a new portfolio with GENESIS transaction.
"""
function init_portfolio(portfolio_id::String, metadata::Dict)
    ensure_directories()
    log_path = get_log_path(portfolio_id)

    if get_file_size(log_path) > 0
        error("Portfolio $portfolio_id already exists")
    end

    genesis_tx = Dict(
        "type" => TX_TYPE.GENESIS,
        "portfolioId" => portfolio_id,
        "name" => get(metadata, "name", ""),
        "color" => get(metadata, "color", ""),
        "status" => get(metadata, "status", "active"),
        "description" => get(metadata, "description", "Portfolio $portfolio_id created")
    )

    return append_transaction(portfolio_id, genesis_tx)
end

"""
    record_buy(portfolio_id, pos_id, market, position, shares, price, confidence, action, reason) -> Dict

Record a BUY transaction.
"""
function record_buy(portfolio_id::String;
                   positionId::String,
                   market::String,
                   position::String,
                   shares::Number,
                   price::Number,
                   confidence::Number=50,
                   action::String="hold",
                   reason::String="")
    return append_transaction(portfolio_id, Dict(
        "type" => TX_TYPE.BUY,
        "positionId" => positionId,
        "market" => market,
        "position" => position,
        "shares" => shares,
        "price" => price,
        "confidence" => confidence,
        "action" => action,
        "reason" => reason
    ))
end

"""
    record_sell(portfolio_id, pos_id, shares, price, reason) -> Dict

Record a SELL transaction.
"""
function record_sell(portfolio_id::String;
                    positionId::String,
                    shares::Number,
                    price::Number,
                    reason::String="Position sold")
    return append_transaction(portfolio_id, Dict(
        "type" => TX_TYPE.SELL,
        "positionId" => positionId,
        "shares" => shares,
        "price" => price,
        "reason" => reason
    ))
end

"""
    record_flip(portfolio_id, pos_id, price, reason) -> Dict

Record a FLIP transaction.
"""
function record_flip(portfolio_id::String;
                    positionId::String,
                    price::Number,
                    reason::String="Position flipped")
    return append_transaction(portfolio_id, Dict(
        "type" => TX_TYPE.FLIP,
        "positionId" => positionId,
        "price" => price,
        "reason" => reason
    ))
end

"""
    record_resolve(portfolio_id, pos_id, outcome, reason) -> Dict

Record a RESOLVE transaction.
"""
function record_resolve(portfolio_id::String;
                       positionId::String,
                       outcome::Bool,
                       reason::String="")
    default_reason = "Market resolved: $(outcome ? "YES" : "NO")"
    return append_transaction(portfolio_id, Dict(
        "type" => TX_TYPE.RESOLVE,
        "positionId" => positionId,
        "outcome" => outcome,
        "reason" => isempty(reason) ? default_reason : reason
    ))
end

"""
    record_adjust(portfolio_id, pos_id; current, confidence, action, reason) -> Dict

Record an ADJUST transaction for price/confidence updates.
"""
function record_adjust(portfolio_id::String;
                      positionId::String,
                      current::Union{Number, Nothing}=nothing,
                      confidence::Union{Number, Nothing}=nothing,
                      action::Union{String, Nothing}=nothing,
                      reason::Union{String, Nothing}=nothing)
    tx = Dict{String, Any}(
        "type" => TX_TYPE.ADJUST,
        "positionId" => positionId
    )

    if current !== nothing
        tx["current"] = current
    end
    if confidence !== nothing
        tx["confidence"] = confidence
    end
    if action !== nothing
        tx["action"] = action
    end
    if reason !== nothing
        tx["reason"] = reason
    end

    return append_transaction(portfolio_id, tx)
end

"""
    verify_chain(portfolio_id::String) -> Dict

Verify chain integrity by checking hashes.
"""
function verify_chain(portfolio_id::String)
    log_path = get_log_path(portfolio_id)
    transactions = read_transactions(log_path)

    if isempty(transactions)
        return Dict("valid" => true, "errors" => String[], "transactionCount" => 0)
    end

    errors = String[]

    # Check first transaction has zero prevHash
    if get(transactions[1], "prevHash", "") != "0" ^ 16
        push!(errors, "First transaction should have zero prevHash")
    end

    # Check chain integrity
    for i in 2:length(transactions)
        prev = transactions[i-1]
        curr = transactions[i]
        expected_hash = hash_transaction(prev)

        if get(curr, "prevHash", "") != expected_hash
            push!(errors, "Chain broken at transaction $i: expected $expected_hash, got $(get(curr, "prevHash", ""))")
        end
    end

    return Dict(
        "valid" => isempty(errors),
        "errors" => errors,
        "transactionCount" => length(transactions)
    )
end

"""
    audit_checkpoint(portfolio_id::String, archive_path::String) -> Dict

Verify checkpoint matches calculated state from archive.
"""
function audit_checkpoint(portfolio_id::String, archive_path::String)
    # Calculate state from archive
    archive_txs = read_transactions(archive_path)

    archive_state = Dict{String, Any}(
        "positions" => Dict{String, Any}(),
        "realized" => 0.0
    )

    # Replay archive transactions (simplified)
    for tx in archive_txs
        tx_type = get(tx, "type", "")

        if tx_type == TX_TYPE.CHECKPOINT
            archive_state["positions"] = copy(get(tx, "positions", Dict()))
            archive_state["realized"] = get(tx, "realized", 0.0)
        elseif tx_type == TX_TYPE.BUY
            pos_id = get(tx, "positionId", "")
            if !haskey(archive_state["positions"], pos_id)
                archive_state["positions"][pos_id] = Dict(
                    "shares" => 0, "totalCost" => 0.0, "avgEntry" => 0.0
                )
            end
            pos = archive_state["positions"][pos_id]
            shares = get(tx, "shares", 0)
            price = get(tx, "price", 0.0)
            pos["shares"] += shares
            pos["totalCost"] += shares * price
            pos["avgEntry"] = pos["shares"] > 0 ? pos["totalCost"] / pos["shares"] : 0.0
        elseif tx_type == TX_TYPE.SELL
            pos_id = get(tx, "positionId", "")
            if haskey(archive_state["positions"], pos_id)
                pos = archive_state["positions"][pos_id]
                cost_basis = pos["avgEntry"] * get(tx, "shares", 0)
                archive_state["realized"] += get(tx, "price", 0.0) * get(tx, "shares", 0) - cost_basis
                pos["shares"] -= get(tx, "shares", 0)
                pos["totalCost"] -= cost_basis
            end
        end
    end

    # Get first checkpoint in current log
    current_txs = read_transactions(get_log_path(portfolio_id))
    checkpoint = nothing
    for tx in current_txs
        if get(tx, "type", "") == TX_TYPE.CHECKPOINT
            checkpoint = tx
            break
        end
    end

    if checkpoint === nothing
        return Dict("valid" => false, "error" => "No checkpoint found in current log")
    end

    errors = String[]

    if abs(get(checkpoint, "realized", 0.0) - archive_state["realized"]) > 0.01
        push!(errors, "Realized P/L mismatch: checkpoint=$(get(checkpoint, "realized", 0)), archive=$(archive_state["realized"])")
    end

    # Compare positions
    checkpoint_positions = get(checkpoint, "positions", Dict())
    for (pos_id, pos) in checkpoint_positions
        archive_pos = get(archive_state["positions"], pos_id, nothing)
        if archive_pos === nothing
            push!(errors, "Position $pos_id in checkpoint but not in archive")
        elseif abs(get(pos, "shares", 0) - get(archive_pos, "shares", 0)) > 0.001
            push!(errors, "Position $pos_id shares mismatch: checkpoint=$(get(pos, "shares", 0)), archive=$(get(archive_pos, "shares", 0))")
        end
    end

    return Dict(
        "valid" => isempty(errors),
        "errors" => errors,
        "archiveFile" => basename(archive_path)
    )
end

"""
    list_portfolios() -> Vector{String}

List all portfolio IDs.
"""
function list_portfolios()
    ensure_directories()
    files = readdir(PORTFOLIOS_DIR)
    return [replace(f, ".jsonl" => "") for f in files
            if endswith(f, ".jsonl") && !contains(f, "_")]
end

"""
    list_archives(portfolio_id::String) -> Vector{String}

List archived logs for a portfolio.
"""
function list_archives(portfolio_id::String)
    ensure_directories()
    files = readdir(ARCHIVE_DIR)
    return sort([f for f in files
                 if startswith(f, "$(portfolio_id)_") && endswith(f, ".jsonl")])
end

"""
    get_log_stats(portfolio_id::String) -> Dict

Get transaction log statistics.
"""
function get_log_stats(portfolio_id::String)
    log_path = get_log_path(portfolio_id)
    size = get_file_size(log_path)
    transactions = read_transactions(log_path)
    archives = list_archives(portfolio_id)

    return Dict(
        "portfolioId" => portfolio_id,
        "currentLogSize" => size,
        "currentLogSizeHuman" => "$(round(size / 1024, digits=2)) KB",
        "maxLogSize" => MAX_LOG_SIZE,
        "percentFull" => round(size / MAX_LOG_SIZE * 100, digits=1),
        "transactionCount" => length(transactions),
        "archiveCount" => length(archives),
        "archives" => archives
    )
end

end # module

#!/usr/bin/env julia
"""
    Kalshi Order Groups API Scripts

Order groups allow you to set contract limits across multiple orders.

Endpoints:
  GET    /portfolio/order_groups                            - List all order groups
  POST   /portfolio/order_groups/create                     - Create order group
  GET    /portfolio/order_groups/{order_group_id}            - Get order group details
  DELETE /portfolio/order_groups/{order_group_id}            - Delete group & cancel orders
  PUT    /portfolio/order_groups/{order_group_id}/reset      - Reset matched contracts counter
  PUT    /portfolio/order_groups/{order_group_id}/trigger    - Trigger group & cancel orders
  PUT    /portfolio/order_groups/{order_group_id}/limit      - Update contract limit

Usage:
  julia --project=. scripts/kalshi_order_groups.jl list
  julia --project=. scripts/kalshi_order_groups.jl create --max_contracts=100
  julia --project=. scripts/kalshi_order_groups.jl get GROUP_ID
  julia --project=. scripts/kalshi_order_groups.jl delete GROUP_ID
  julia --project=. scripts/kalshi_order_groups.jl reset GROUP_ID
  julia --project=. scripts/kalshi_order_groups.jl trigger GROUP_ID
  julia --project=. scripts/kalshi_order_groups.jl set_limit GROUP_ID --max_contracts=200
"""

include(joinpath(@__DIR__, "..", "src", "KalshiAuth.jl"))
using .KalshiAuth
using JSON3

# =============================================================================
# Order Groups Endpoints
# =============================================================================

"""
    list_order_groups(config) -> response

List all order groups for the authenticated user.
"""
function list_order_groups(config::KalshiConfig)
    return kalshi_get(config, "/portfolio/order_groups")
end

"""
    create_order_group(config; max_contracts) -> response

Create a new order group with a contract limit.
Orders added to this group will collectively respect the max_contracts limit.
"""
function create_order_group(config::KalshiConfig; max_contracts::Int)
    body = Dict{String,Any}("max_contracts" => max_contracts)
    return kalshi_post(config, "/portfolio/order_groups/create"; body)
end

"""
    get_order_group(config, group_id) -> response

Get details for a specific order group.
"""
function get_order_group(config::KalshiConfig, group_id::String)
    return kalshi_get(config, "/portfolio/order_groups/$group_id")
end

"""
    delete_order_group(config, group_id) -> response

Delete an order group and cancel all orders in it.
"""
function delete_order_group(config::KalshiConfig, group_id::String)
    return kalshi_delete(config, "/portfolio/order_groups/$group_id")
end

"""
    reset_order_group(config, group_id) -> response

Reset the matched contracts counter for an order group.
"""
function reset_order_group(config::KalshiConfig, group_id::String)
    return kalshi_put(config, "/portfolio/order_groups/$group_id/reset")
end

"""
    trigger_order_group(config, group_id) -> response

Trigger an order group, which cancels all orders in the group.
"""
function trigger_order_group(config::KalshiConfig, group_id::String)
    return kalshi_put(config, "/portfolio/order_groups/$group_id/trigger")
end

"""
    update_order_group_limit(config, group_id; max_contracts) -> response

Update the contract limit for an order group.
"""
function update_order_group_limit(config::KalshiConfig, group_id::String; max_contracts::Int)
    body = Dict{String,Any}("max_contracts" => max_contracts)
    return kalshi_put(config, "/portfolio/order_groups/$group_id/limit"; body)
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
        Usage: julia --project=. scripts/kalshi_order_groups.jl <command> [options]

        Commands:
          list                          List all order groups
          create --max_contracts=N      Create order group
          get GROUP_ID                  Get order group details
          delete GROUP_ID               Delete group & cancel orders
          reset GROUP_ID                Reset matched contracts counter
          trigger GROUP_ID              Trigger group & cancel orders
          set_limit GROUP_ID --max_contracts=N  Update contract limit

        Options:
          --demo / --live               Environment
          --verbose                     Debug output
        """)
        return
    end

    demo = !("--live" in ARGS)
    verbose = "--verbose" in ARGS
    config = load_config(; demo, verbose)

    cmd = ARGS[1]
    rest = filter(a -> !startswith(a, "--"), ARGS[2:end])

    if cmd == "list"
        result = list_order_groups(config)
        println(JSON3.pretty(JSON3.write(result)))

    elseif cmd == "create"
        max_c = parse_int_arg(ARGS, "max_contracts")
        max_c === nothing && error("--max_contracts required")
        result = create_order_group(config; max_contracts=max_c)
        println(JSON3.pretty(JSON3.write(result)))

    elseif cmd == "get"
        group_id = isempty(rest) ? error("Group ID required") : rest[1]
        result = get_order_group(config, group_id)
        println(JSON3.pretty(JSON3.write(result)))

    elseif cmd == "delete"
        group_id = isempty(rest) ? error("Group ID required") : rest[1]
        result = delete_order_group(config, group_id)
        println(JSON3.pretty(JSON3.write(result)))

    elseif cmd == "reset"
        group_id = isempty(rest) ? error("Group ID required") : rest[1]
        result = reset_order_group(config, group_id)
        println(JSON3.pretty(JSON3.write(result)))

    elseif cmd == "trigger"
        group_id = isempty(rest) ? error("Group ID required") : rest[1]
        result = trigger_order_group(config, group_id)
        println(JSON3.pretty(JSON3.write(result)))

    elseif cmd == "set_limit"
        group_id = isempty(rest) ? error("Group ID required") : rest[1]
        max_c = parse_int_arg(ARGS, "max_contracts")
        max_c === nothing && error("--max_contracts required")
        result = update_order_group_limit(config, group_id; max_contracts=max_c)
        println(JSON3.pretty(JSON3.write(result)))

    else
        println("Unknown command: $cmd")
    end
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end

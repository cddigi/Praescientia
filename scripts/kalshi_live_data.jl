#!/usr/bin/env julia
"""
    Kalshi Milestones & Live Data API Scripts

Milestones track real-world data points that drive market resolution.
Live data provides real-time updates for these milestones.

Endpoints:
  GET /milestones                                           - List milestones
  GET /milestones/{milestone_id}                            - Get specific milestone
  GET /live_data/milestone/{milestone_id}                   - Live data for milestone
  GET /live_data/{type}/milestone/{milestone_id}            - Legacy: live data with type
  GET /live_data/batch                                      - Batch live data
  GET /live_data/milestone/{milestone_id}/game_stats        - Play-by-play game stats

Usage:
  julia --project=. scripts/kalshi_live_data.jl milestones [--category=C] [--competition=C] [--limit=20]
  julia --project=. scripts/kalshi_live_data.jl milestone MILESTONE_ID
  julia --project=. scripts/kalshi_live_data.jl live MILESTONE_ID
  julia --project=. scripts/kalshi_live_data.jl live_legacy TYPE MILESTONE_ID
  julia --project=. scripts/kalshi_live_data.jl batch MILESTONE_ID1,MILESTONE_ID2,...
  julia --project=. scripts/kalshi_live_data.jl game_stats MILESTONE_ID
"""

include(joinpath(@__DIR__, "..", "src", "KalshiAuth.jl"))
using .KalshiAuth
using JSON3

# =============================================================================
# Milestones
# =============================================================================

"""
    list_milestones(config; category, competition, limit, cursor) -> response

List milestones with optional category/competition filters.
"""
function list_milestones(config::KalshiConfig;
    category::String = "",
    competition::String = "",
    limit::Int = 20,
    cursor::String = ""
)
    params = Dict{String,Any}("limit" => limit)
    !isempty(category) && (params["category"] = category)
    !isempty(competition) && (params["competition"] = competition)
    !isempty(cursor) && (params["cursor"] = cursor)
    return kalshi_get(config, "/milestones"; params)
end

"""
    get_milestone(config, milestone_id) -> response

Get specific milestone data.
"""
function get_milestone(config::KalshiConfig, milestone_id::String)
    return kalshi_get(config, "/milestones/$milestone_id")
end

# =============================================================================
# Live Data
# =============================================================================

"""
    get_live_data(config, milestone_id) -> response

Get real-time live data for a milestone.
"""
function get_live_data(config::KalshiConfig, milestone_id::String)
    return kalshi_get(config, "/live_data/milestone/$milestone_id")
end

"""
    get_live_data_legacy(config, type, milestone_id) -> response

Legacy endpoint: get live data with explicit type parameter.
"""
function get_live_data_legacy(config::KalshiConfig, type::String, milestone_id::String)
    return kalshi_get(config, "/live_data/$type/milestone/$milestone_id")
end

"""
    get_live_data_batch(config, milestone_ids::Vector{String}) -> response

Get live data for multiple milestones in a single request.
"""
function get_live_data_batch(config::KalshiConfig, milestone_ids::Vector{String})
    params = Dict{String,Any}("milestone_ids" => join(milestone_ids, ","))
    return kalshi_get(config, "/live_data/batch"; params)
end

"""
    get_game_stats(config, milestone_id) -> response

Get play-by-play game statistics for a sports milestone.
"""
function get_game_stats(config::KalshiConfig, milestone_id::String)
    return kalshi_get(config, "/live_data/milestone/$milestone_id/game_stats")
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
        Usage: julia --project=. scripts/kalshi_live_data.jl <command> [options]

        Commands:
          milestones                     List milestones
          milestone MILESTONE_ID         Get specific milestone
          live MILESTONE_ID              Live data for milestone
          live_legacy TYPE MILESTONE_ID  Legacy: live data with type
          batch ID1,ID2,...              Batch live data
          game_stats MILESTONE_ID        Play-by-play game stats

        Options:
          --category=CATEGORY      Filter milestones by category
          --competition=COMP       Filter milestones by competition
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

    if cmd == "milestones"
        result = list_milestones(config;
            category = parse_arg(ARGS, "category"),
            competition = parse_arg(ARGS, "competition"),
            limit = something(parse_int_arg(ARGS, "limit"), 20))
        println(JSON3.pretty(JSON3.write(result)))

    elseif cmd == "milestone"
        id = isempty(rest) ? error("Milestone ID required") : rest[1]
        result = get_milestone(config, id)
        println(JSON3.pretty(JSON3.write(result)))

    elseif cmd == "live"
        id = isempty(rest) ? error("Milestone ID required") : rest[1]
        result = get_live_data(config, id)
        println(JSON3.pretty(JSON3.write(result)))

    elseif cmd == "live_legacy"
        length(rest) < 2 && error("Usage: live_legacy TYPE MILESTONE_ID")
        result = get_live_data_legacy(config, rest[1], rest[2])
        println(JSON3.pretty(JSON3.write(result)))

    elseif cmd == "batch"
        isempty(rest) && error("Milestone IDs required (comma-separated)")
        ids = String.(split(rest[1], ","))
        result = get_live_data_batch(config, ids)
        println(JSON3.pretty(JSON3.write(result)))

    elseif cmd == "game_stats"
        id = isempty(rest) ? error("Milestone ID required") : rest[1]
        result = get_game_stats(config, id)
        println(JSON3.pretty(JSON3.write(result)))

    else
        println("Unknown command: $cmd")
    end
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end

# Console UI Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a 4-quadrant terminal UI (Sneakers/Hackers/Swordfish aesthetic) for selecting bets, viewing positions, browsing history, and monitoring market intel — with a February 2026 simulation mode using resolved data.

**Architecture:** Single-screen, 4-quadrant layout rendered with raw ANSI escape codes. One mutable `ConsoleState` struct drives the entire UI. Raw terminal mode captures individual keypresses. The render loop redraws on every input. February simulation replays resolved market data with simulated price ticks to create a "real-time" P&L tracking experience.

**Tech Stack:** Julia stdlib only (`REPL.Terminals`, `Dates`, `UUIDs`), existing deps (`JSON3`, `HTTP`, `SHA`), existing modules (`TxLog.jl`, `Praescientia.jl`). Zero new dependencies.

---

## Task 1: ConsoleUI Module — ANSI Rendering Engine

**Files:**
- Create: `src/ConsoleUI.jl`
- Test: `test/test_console_ui.jl`

**Step 1: Write failing tests for ANSI helpers**

```julia
# test/test_console_ui.jl
using Test
include(joinpath(@__DIR__, "..", "src", "ConsoleUI.jl"))
using .ConsoleUI

@testset "ConsoleUI Module" begin
    @testset "ANSI helpers" begin
        @test ConsoleUI.move_to(1, 1) == "\e[1;1H"
        @test ConsoleUI.move_to(10, 5) == "\e[10;5H"
        @test ConsoleUI.clear_screen() == "\e[2J\e[H"
        @test ConsoleUI.set_color(:green) == "\e[32m"
        @test ConsoleUI.set_color(:bright_cyan) == "\e[96m"
        @test ConsoleUI.set_color(:red) == "\e[31m"
        @test ConsoleUI.set_color(:reset) == "\e[0m"
        @test ConsoleUI.set_color(:dim) == "\e[2m"
        @test ConsoleUI.set_color(:bold) == "\e[1m"
    end

    @testset "Box drawing" begin
        box = ConsoleUI.draw_box(1, 1, 20, 5, "TEST", true)
        @test occursin("╔", box)
        @test occursin("TEST", box)
        @test occursin("╚", box)

        inactive_box = ConsoleUI.draw_box(1, 1, 20, 5, "TEST", false)
        @test occursin("┌", inactive_box)
        @test occursin("└", inactive_box)
    end

    @testset "Text truncation" begin
        @test ConsoleUI.truncate_text("Hello World", 5) == "Hell…"
        @test ConsoleUI.truncate_text("Hi", 5) == "Hi"
        @test ConsoleUI.truncate_text("Hello", 5) == "Hello"
    end

    @testset "P&L formatting" begin
        @test occursin("+", ConsoleUI.format_pnl(10.5))
        @test occursin("-", ConsoleUI.format_pnl(-5.0))
        @test occursin("32m", ConsoleUI.format_pnl(10.5))  # green
        @test occursin("31m", ConsoleUI.format_pnl(-5.0))   # red
    end

    @testset "Percentage formatting" begin
        @test occursin("▲", ConsoleUI.format_pct(10.5))
        @test occursin("▼", ConsoleUI.format_pct(-5.0))
    end
end
```

**Step 2: Run test to verify it fails**

Run: `cd /Volumes/Sidecar/GraceLMP/Praescientia && julia --project=. test/test_console_ui.jl`
Expected: FAIL — module not found

**Step 3: Write ConsoleUI module with ANSI helpers**

```julia
# src/ConsoleUI.jl
module ConsoleUI

using Dates
using JSON3

export ConsoleState, SimulationState
export move_to, clear_screen, set_color, draw_box, truncate_text
export format_pnl, format_pct, hide_cursor, show_cursor
export render_frame, handle_input

# ─────────────────────────────────────────────────────────────
# ANSI Color Palette — Sneakers meets Hackers meets Swordfish
# ─────────────────────────────────────────────────────────────
const COLORS = Dict{Symbol, String}(
    :reset       => "\e[0m",
    :bold        => "\e[1m",
    :dim         => "\e[2m",
    :italic      => "\e[3m",
    :underline   => "\e[4m",
    :blink       => "\e[5m",
    :reverse     => "\e[7m",
    # Foreground
    :black       => "\e[30m",
    :red         => "\e[31m",
    :green       => "\e[32m",
    :yellow      => "\e[33m",
    :blue        => "\e[34m",
    :magenta     => "\e[35m",
    :cyan        => "\e[36m",
    :white       => "\e[37m",
    # Bright foreground
    :bright_red    => "\e[91m",
    :bright_green  => "\e[92m",
    :bright_yellow => "\e[93m",
    :bright_blue   => "\e[94m",
    :bright_magenta=> "\e[95m",
    :bright_cyan   => "\e[96m",
    :bright_white  => "\e[97m",
    # Background
    :bg_black    => "\e[40m",
    :bg_red      => "\e[41m",
    :bg_green    => "\e[42m",
    :bg_blue     => "\e[44m",
    :bg_cyan     => "\e[46m",
    :bg_white    => "\e[47m",
    # Dim/gray
    :gray        => "\e[90m",
)

move_to(row::Int, col::Int) = "\e[$(row);$(col)H"
clear_screen() = "\e[2J\e[H"
hide_cursor() = "\e[?25l"
show_cursor() = "\e[?25h"

function set_color(c::Symbol)
    get(COLORS, c, "\e[0m")
end

function truncate_text(text::String, max_len::Int)
    if length(text) <= max_len
        return text
    end
    return text[1:max_len-1] * "…"
end

function format_pnl(value::Number)
    c = value >= 0 ? :green : :red
    sign = value >= 0 ? "+" : ""
    "$(set_color(c))$(sign)\$$(round(value, digits=2))$(set_color(:reset))"
end

function format_pct(value::Number)
    c = value >= 0 ? :green : :red
    arrow = value >= 0 ? "▲" : "▼"
    sign = value >= 0 ? "+" : ""
    "$(set_color(c))$(sign)$(round(value, digits=1))%$(arrow)$(set_color(:reset))"
end

# ─────────────────────────────────────────────────────────────
# Box Drawing
# ─────────────────────────────────────────────────────────────
function draw_box(row::Int, col::Int, width::Int, height::Int, title::String, active::Bool)
    buf = IOBuffer()
    if active
        tl, tr, bl, br, h, v = '╔', '╗', '╚', '╝', '═', '║'
        title_color = set_color(:bright_cyan)
    else
        tl, tr, bl, br, h, v = '┌', '┐', '└', '┘', '─', '│'
        title_color = set_color(:gray)
    end

    border_color = active ? set_color(:bright_cyan) : set_color(:gray)
    rst = set_color(:reset)

    # Top border with title
    top_bar = string(h) ^ (width - 2)
    title_display = " $(title) "
    if length(title_display) < width - 4
        insert_pos = 2
        top_bar = string(h)^insert_pos * title_display * string(h)^(width - 2 - insert_pos - length(title_display))
    end
    print(buf, move_to(row, col), border_color, tl, title_color, top_bar, border_color, tr, rst)

    # Side borders
    for r in 1:(height - 2)
        print(buf, move_to(row + r, col), border_color, v, rst)
        print(buf, move_to(row + r, col + width - 1), border_color, v, rst)
    end

    # Bottom border
    print(buf, move_to(row + height - 1, col), border_color, bl, string(h)^(width - 2), br, rst)

    return String(take!(buf))
end

# ─────────────────────────────────────────────────────────────
# State
# ─────────────────────────────────────────────────────────────

# A single market available for betting
struct MarketOption
    id::String
    question::String
    category::String
    position::String        # YES or NO
    entry_price::Float64    # simulated entry odds
    resolution_date::String
    outcome::String         # resolved outcome text
    won::Union{Bool, Nothing}
end

# Simulation state for February replay
mutable struct SimulationState
    markets::Vector{MarketOption}
    day_index::Int                     # current sim day (1-28)
    sim_date::Date                     # current simulated date
    tick_prices::Dict{String, Vector{Float64}}  # market_id -> daily prices
    price_data::Dict{String, Dict}     # asset -> {open, close, high, low}
    running::Bool
    speed::Float64                     # seconds per tick
    budget::Float64
end

mutable struct ConsoleState
    active_quadrant::Int               # 1-4
    term_rows::Int
    term_cols::Int

    # Q1 — Market Select
    market_tab::Symbol                 # :daily, :weekly, :monthly
    available_markets::Vector{MarketOption}
    selected::Set{Int}                 # indices into available_markets
    q1_scroll::Int
    q1_cursor::Int                     # highlighted row

    # Q2 — Positions
    portfolio_tab::Symbol              # :contrarian, :weekly, :daily, :sim_feb
    positions::Vector{Dict{String,Any}}
    q2_scroll::Int
    q2_cursor::Int
    expanded_position::Union{Nothing, Int}

    # Q3 — TX Log
    tx_log::Vector{Dict{String,Any}}
    tx_scroll::Int
    tx_filter::Set{Symbol}             # :BUY, :SELL, :FLIP, :RESOLVE, :ADJUST
    tx_search::String
    search_mode::Bool

    # Q4 — Intel
    prices::Dict{String, Any}
    hopper_metrics::Dict{String, Any}
    signals::Vector{String}
    last_refresh::DateTime

    # Simulation
    sim::Union{Nothing, SimulationState}
    message::String                    # status bar message
    running::Bool                      # main loop flag
end

function ConsoleState()
    rows, cols = displaysize(stdout)
    ConsoleState(
        1, rows, cols,
        :daily, MarketOption[], Set{Int}(), 0, 1,
        :contrarian, Dict{String,Any}[], 0, 1, nothing,
        Dict{String,Any}[], 0, Set([:BUY, :SELL, :FLIP, :RESOLVE, :ADJUST, :GENESIS]), "", false,
        Dict{String,Any}(), Dict{String,Any}(), String[], now(UTC),
        nothing, "", true
    )
end

end # module
```

**Step 4: Run tests to verify they pass**

Run: `cd /Volumes/Sidecar/GraceLMP/Praescientia && julia --project=. test/test_console_ui.jl`
Expected: All ANSI helper tests PASS

**Step 5: Commit**

Record via GitButler: "feat: add ConsoleUI module with ANSI rendering engine"

---

## Task 2: Quadrant Renderers

**Files:**
- Modify: `src/ConsoleUI.jl` (add render functions)
- Test: `test/test_console_ui.jl` (add render tests)

**Step 1: Write failing tests for quadrant renderers**

Add to `test/test_console_ui.jl`:

```julia
@testset "Quadrant renderers produce output" begin
    state = ConsoleUI.ConsoleState()

    # Each renderer should return a non-empty string
    q1 = ConsoleUI.render_q1_market_select(state, 2, 2, 38, 14)
    @test length(q1) > 0
    @test occursin("MARKET SELECT", q1)

    q2 = ConsoleUI.render_q2_positions(state, 2, 42, 38, 14)
    @test length(q2) > 0
    @test occursin("POSITIONS", q2)

    q3 = ConsoleUI.render_q3_txlog(state, 17, 2, 38, 14)
    @test length(q3) > 0
    @test occursin("TX LOG", q3)

    q4 = ConsoleUI.render_q4_intel(state, 17, 42, 38, 14)
    @test length(q4) > 0
    @test occursin("INTEL", q4)
end
```

**Step 2: Run tests, verify failure**

**Step 3: Implement quadrant renderers**

Add these functions to `src/ConsoleUI.jl` before the `end # module`:

```julia
# ─────────────────────────────────────────────────────────────
# Q1 — MARKET SELECT
# ─────────────────────────────────────────────────────────────
function render_q1_market_select(state::ConsoleState, row::Int, col::Int, w::Int, h::Int)
    buf = IOBuffer()
    active = state.active_quadrant == 1
    inner_w = w - 4
    rst = set_color(:reset)

    # Box
    print(buf, draw_box(row, col, w, h, "MARKET SELECT", active))

    # Tab bar
    r = row + 1
    tabs = [:daily, :weekly, :monthly]
    tab_str = ""
    for t in tabs
        if t == state.market_tab
            tab_str *= " $(set_color(:bright_cyan))$(set_color(:bold))▸$(uppercase(string(t)))$(rst) │"
        else
            tab_str *= " $(set_color(:gray))$(uppercase(string(t)))$(rst) │"
        end
    end
    print(buf, move_to(r, col + 2), truncate_text(tab_str, inner_w + 40))  # allow for escape seqs

    # Separator
    r += 1
    print(buf, move_to(r, col + 1), set_color(active ? :bright_cyan : :gray), "─"^(w-2), rst)

    # Market list
    markets = state.available_markets
    visible_rows = h - 6  # box + tabs + separator + footer
    scroll = state.q1_scroll
    for i in 1:visible_rows
        idx = scroll + i
        r += 1
        if idx > length(markets)
            print(buf, move_to(r, col + 2), " "^inner_w)
            continue
        end
        m = markets[idx]
        is_selected = idx in state.selected
        is_cursor = idx == state.q1_cursor

        bullet = is_selected ? "$(set_color(:bright_green))●" : "$(set_color(:gray))○"
        cursor_indicator = is_cursor && active ? "$(set_color(:bright_white))▸" : " "
        name = truncate_text(m.question, inner_w - 16)
        price_str = "$(m.position) $(round(m.entry_price, digits=2))"

        print(buf, move_to(r, col + 2),
              cursor_indicator, bullet, " ", set_color(:white), name,
              set_color(:yellow), "  ", price_str, rst)
    end

    # Footer
    r = row + h - 2
    sel_count = length(state.selected)
    cost = sum(markets[i].entry_price * 100 for i in state.selected; init=0.0)
    print(buf, move_to(r, col + 1), set_color(active ? :bright_cyan : :gray), "─"^(w-2), rst)
    r += 1
    # Omit the last line; it's part of the box bottom
    # Instead, overlay footer text on the second-to-last row
    footer = " $(sel_count) selected │ Cost: \$$(round(cost, digits=2))"
    print(buf, move_to(r - 1, col + 2), set_color(:white), truncate_text(footer, inner_w), rst)

    return String(take!(buf))
end

# ─────────────────────────────────────────────────────────────
# Q2 — POSITIONS
# ─────────────────────────────────────────────────────────────
function render_q2_positions(state::ConsoleState, row::Int, col::Int, w::Int, h::Int)
    buf = IOBuffer()
    active = state.active_quadrant == 2
    inner_w = w - 4
    rst = set_color(:reset)

    print(buf, draw_box(row, col, w, h, "POSITIONS", active))

    # Tab bar
    r = row + 1
    tabs = [:contrarian, :weekly, :daily]
    if state.sim !== nothing
        push!(tabs, :sim_feb)
    end
    tab_str = ""
    for t in tabs
        label = t == :sim_feb ? "SIM:FEB" : uppercase(string(t))
        if t == state.portfolio_tab
            tab_str *= " $(set_color(:bright_cyan))$(set_color(:bold))▸$(label)$(rst) │"
        else
            tab_str *= " $(set_color(:gray))$(label)$(rst) │"
        end
    end
    print(buf, move_to(r, col + 2), tab_str)

    # Separator
    r += 1
    print(buf, move_to(r, col + 1), set_color(active ? :bright_cyan : :gray), "─"^(w-2), rst)

    # Header row
    r += 1
    print(buf, move_to(r, col + 2), set_color(:dim),
          rpad("ID", 4), rpad("Market", inner_w - 18), rpad("Pos", 5), rpad("P&L", 10), rst)

    # Position rows
    visible_rows = h - 7
    for i in 1:visible_rows
        idx = state.q2_scroll + i
        r += 1
        if idx > length(state.positions)
            print(buf, move_to(r, col + 2), " "^inner_w)
            continue
        end
        pos = state.positions[idx]
        pos_id = truncate_text(string(get(pos, "id", "")), 3)
        market = truncate_text(string(get(pos, "market", "")), inner_w - 18)
        direction = string(get(pos, "position", ""))
        pl = get(pos, "pl", 0.0)
        is_cursor = idx == state.q2_cursor && active

        cursor_ind = is_cursor ? "$(set_color(:bright_white))▸" : " "
        print(buf, move_to(r, col + 2), cursor_ind,
              set_color(:white), rpad(pos_id, 4),
              rpad(market, inner_w - 18),
              set_color(:yellow), rpad(direction, 5),
              format_pnl(isa(pl, Number) ? pl : 0.0), rst)
    end

    # Summary footer
    r = row + h - 3
    realized = sum(get(p, "realized", 0.0) for p in state.positions; init=0.0)
    unrealized = sum((isa(get(p, "pl", 0), Number) ? get(p, "pl", 0.0) : 0.0) for p in state.positions; init=0.0)
    print(buf, move_to(r, col + 1), set_color(active ? :bright_cyan : :gray), "─"^(w-2), rst)
    r += 1
    print(buf, move_to(r, col + 2), set_color(:white), "Realized: ", format_pnl(realized), "  Unreal: ", format_pnl(unrealized), rst)

    return String(take!(buf))
end

# ─────────────────────────────────────────────────────────────
# Q3 — TX LOG
# ─────────────────────────────────────────────────────────────
function render_q3_txlog(state::ConsoleState, row::Int, col::Int, w::Int, h::Int)
    buf = IOBuffer()
    active = state.active_quadrant == 3
    inner_w = w - 4
    rst = set_color(:reset)

    print(buf, draw_box(row, col, w, h, "TX LOG", active))

    # Filter tabs
    r = row + 1
    filter_types = [:BUY, :SELL, :FLIP, :RESOLVE, :ADJUST]
    filter_str = ""
    for ft in filter_types
        if ft in state.tx_filter
            filter_str *= " $(set_color(:bright_green))$(ft)$(rst) │"
        else
            filter_str *= " $(set_color(:gray))$(ft)$(rst) │"
        end
    end
    print(buf, move_to(r, col + 2), filter_str)

    # Separator
    r += 1
    print(buf, move_to(r, col + 1), set_color(active ? :bright_cyan : :gray), "─"^(w-2), rst)

    # TX type colors
    type_colors = Dict(
        "BUY" => :cyan, "SELL" => :magenta, "FLIP" => :yellow,
        "RESOLVE" => :bright_green, "ADJUST" => :yellow, "GENESIS" => :dim
    )

    # Filtered + searched transactions
    filtered = filter(state.tx_log) do tx
        tx_type = Symbol(get(tx, "type", ""))
        in_filter = tx_type in state.tx_filter
        in_search = isempty(state.tx_search) || occursin(lowercase(state.tx_search), lowercase(string(get(tx, "market", get(tx, "positionId", "")))))
        in_filter && in_search
    end

    visible_rows = h - 5
    for i in 1:visible_rows
        idx = state.tx_scroll + i
        r += 1
        if idx > length(filtered)
            print(buf, move_to(r, col + 2), " "^inner_w)
            continue
        end
        tx = filtered[idx]
        tx_type = string(get(tx, "type", ""))
        ts = get(tx, "timestamp", "")
        date_str = length(ts) >= 10 ? ts[6:10] : "     "  # MM-DD
        pos_id = truncate_text(string(get(tx, "positionId", "")), 3)
        tc = get(type_colors, tx_type, :white)

        # Format depends on type
        detail = if tx_type == "BUY"
            price = get(tx, "price", 0.0)
            shares = get(tx, "shares", 0)
            "\$$(round(price, digits=3)) $(shares)sh"
        elseif tx_type == "RESOLVE"
            outcome = get(tx, "outcome", false)
            outcome ? "$(set_color(:bright_green))WON" : "$(set_color(:red))LOST"
        elseif tx_type == "ADJUST"
            current = get(tx, "current", 0.0)
            "\$$(round(current, digits=3))"
        elseif tx_type == "SELL"
            price = get(tx, "price", 0.0)
            "\$$(round(price, digits=3))"
        else
            ""
        end

        line = " $(date_str) $(set_color(tc))$(rpad(tx_type, 7))$(rst) $(rpad(pos_id, 4)) $(detail)$(rst)"
        print(buf, move_to(r, col + 2), truncate_text(line, inner_w + 30))  # escape seq padding
    end

    # Footer
    r = row + h - 2
    total = length(filtered)
    shown = min(visible_rows, total)
    print(buf, move_to(r, col + 2), set_color(:gray),
          "── $(shown)/$(total) ", state.search_mode ? "[/]$(state.tx_search)█" : "[↑↓] scroll [F]ilter [/]search",
          rst)

    return String(take!(buf))
end

# ─────────────────────────────────────────────────────────────
# Q4 — INTEL
# ─────────────────────────────────────────────────────────────
function render_q4_intel(state::ConsoleState, row::Int, col::Int, w::Int, h::Int)
    buf = IOBuffer()
    active = state.active_quadrant == 4
    inner_w = w - 4
    rst = set_color(:reset)

    print(buf, draw_box(row, col, w, h, "INTEL", active))

    r = row + 1
    # Live Prices section
    print(buf, move_to(r, col + 2), set_color(:dim), "░░ LIVE PRICES ░░", rst)
    r += 1

    for (asset, label) in [("btc", "BTC"), ("eth", "ETH"), ("sol", "SOL"), ("spx", "SPX")]
        r += 1
        data = get(state.prices, asset, nothing)
        if data !== nothing
            price = get(data, "price", 0.0)
            change = get(data, "change_pct", 0.0)
            price_str = asset == "spx" ? string(round(price, digits=0)) : "\$$(round(price, digits=0))"
            print(buf, move_to(r, col + 2), set_color(:white), rpad(label, 5),
                  rpad(price_str, 10), format_pct(change), rst)
        else
            print(buf, move_to(r, col + 2), set_color(:gray), rpad(label, 5), "---", rst)
        end
    end

    # Separator
    r += 1
    print(buf, move_to(r, col + 1), set_color(active ? :bright_cyan : :gray), "─"^(w-2), rst)

    # Hopper Calculus
    r += 1
    print(buf, move_to(r, col + 2), set_color(:dim), "░░ HOPPER CALCULUS ░░", rst)
    metrics = state.hopper_metrics
    for (key, label) in [("total_at_risk", "At risk:"), ("worst_case", "Worst case:"),
                          ("best_case", "Best case:"), ("risk_reward", "Risk/reward:")]
        r += 1
        val = get(metrics, key, nothing)
        if val !== nothing
            if key == "risk_reward"
                print(buf, move_to(r, col + 2), set_color(:white), rpad(label, 14), "$(round(val, digits=2))x", rst)
            else
                print(buf, move_to(r, col + 2), set_color(:white), rpad(label, 14), format_pnl(val), rst)
            end
        end
    end

    # Separator
    r += 1
    print(buf, move_to(r, col + 1), set_color(active ? :bright_cyan : :gray), "─"^(w-2), rst)

    # Signals
    r += 1
    print(buf, move_to(r, col + 2), set_color(:dim), "░░ SIGNALS ░░", rst)
    for (i, sig) in enumerate(state.signals)
        r += 1
        if r >= row + h - 2
            break
        end
        print(buf, move_to(r, col + 2), set_color(:yellow), "⚡ ", set_color(:white), truncate_text(sig, inner_w - 3), rst)
    end

    # Last refresh
    r = row + h - 2
    ts = Dates.format(state.last_refresh, "HH:MM:SS")
    print(buf, move_to(r, col + 2), set_color(:gray), "Last refresh: $(ts)", rst)

    return String(take!(buf))
end
```

**Step 4: Run tests, verify pass**

**Step 5: Commit**

Record via GitButler: "feat: add 4-quadrant renderers (market select, positions, tx log, intel)"

---

## Task 3: February Simulation Data Loader

**Files:**
- Modify: `src/ConsoleUI.jl` (add simulation loader)
- Test: `test/test_console_ui.jl` (add sim tests)

**Step 1: Write failing test**

```julia
@testset "February simulation loader" begin
    sim = ConsoleUI.load_february_simulation(
        joinpath(@__DIR__, "..", "data", "february_2026_resolved.json"),
        joinpath(@__DIR__, "..", "data", "january_2026_resolved.json")
    )
    @test sim !== nothing
    @test sim.budget == 100.0
    @test length(sim.markets) > 0
    @test sim.sim_date == Date(2026, 2, 1)
    @test sim.day_index == 1

    # Check price ticks were generated
    @test haskey(sim.tick_prices, "btc")
    @test length(sim.tick_prices["btc"]) == 28  # 28 days in Feb
end
```

**Step 2: Run test, verify failure**

**Step 3: Implement simulation loader**

Add to `src/ConsoleUI.jl`:

```julia
# ─────────────────────────────────────────────────────────────
# February 2026 Simulation
# ─────────────────────────────────────────────────────────────

"""
    generate_price_ticks(open, close, high, low, days)

Generate synthetic daily prices that move from open to close,
touching high and low at realistic points. Uses a random walk
bounded by the known min/max.
"""
function generate_price_ticks(open::Number, close::Number, high::Number, low::Number, days::Int)
    prices = Float64[]
    # Create a path: open → high/low → close with noise
    mid = days ÷ 2
    for d in 1:days
        if d == 1
            push!(prices, Float64(open))
        elseif d == days
            push!(prices, Float64(close))
        else
            # Linear interpolation with noise, clamped to [low, high]
            t = (d - 1) / (days - 1)
            base = open + (close - open) * t
            # Add volatility (±5% of range)
            range_size = high - low
            noise = (rand() - 0.5) * range_size * 0.1
            price = clamp(base + noise, Float64(low), Float64(high))
            push!(prices, price)
        end
    end
    # Ensure high and low are hit at some point
    if high > maximum(prices)
        prices[argmax(prices)] = Float64(high)
    end
    if low < minimum(prices)
        prices[argmin(prices)] = Float64(low)
    end
    return prices
end

"""
Build simulated betting markets from February 2026 resolved data.
These are the markets the user can "bet on" during the simulation.
"""
function build_february_markets(feb_data::Dict)
    markets = MarketOption[]
    raw_markets = get(feb_data, "markets", [])

    for m in raw_markets
        id = string(get(m, "id", ""))
        question = string(get(m, "question", ""))
        category = string(get(m, "category", ""))
        resolution_date = string(get(m, "resolution_date", ""))
        outcome_text = string(get(m, "outcome", ""))

        options = get(m, "options", nothing)
        if options !== nothing
            # Multi-option market (e.g., US strikes Iran YES/NO)
            for opt in options
                label = string(get(opt, "label", ""))
                opt_outcome = string(get(opt, "outcome", ""))
                final_price = Float64(get(opt, "final_price", 0.5))
                won = opt_outcome == "YES"
                # Simulate entry price: inverse of final (cheap bets that resolve)
                entry = won ? clamp(1.0 - final_price + rand() * 0.3, 0.05, 0.95) :
                              clamp(final_price + rand() * 0.2, 0.05, 0.95)
                push!(markets, MarketOption(
                    "$(id)-$(lowercase(label))",
                    "$(question) — $(label)",
                    category,
                    opt_outcome == "YES" ? "YES" : "NO",
                    round(entry, digits=3),
                    resolution_date,
                    outcome_text,
                    won
                ))
            end
        else
            # Simple market — create YES/NO pair
            # Heuristic: if outcome contains "Yes" it resolved YES
            resolved_yes = occursin(r"(?i)yes"i, outcome_text) || occursin(r"(?i)unexpected|decline|crash"i, outcome_text)
            entry_yes = resolved_yes ? clamp(0.15 + rand() * 0.3, 0.05, 0.5) : clamp(0.5 + rand() * 0.3, 0.5, 0.95)
            push!(markets, MarketOption(
                "$(id)-yes", "$(question) — YES", category, "YES",
                round(entry_yes, digits=3), resolution_date, outcome_text, resolved_yes
            ))
            push!(markets, MarketOption(
                "$(id)-no", "$(question) — NO", category, "NO",
                round(1.0 - entry_yes, digits=3), resolution_date, outcome_text, !resolved_yes
            ))
        end
    end

    return markets
end

function load_february_simulation(feb_path::String, jan_path::String="")
    feb_data = JSON3.read(read(feb_path, String), Dict)
    price_summary = get(feb_data, "price_summary", Dict())

    # Generate daily price ticks for each asset
    tick_prices = Dict{String, Vector{Float64}}()
    price_data = Dict{String, Dict}()
    days = 28  # February 2026

    for (asset, key) in [("btc", "btc"), ("eth", "eth"), ("sol", "sol")]
        data = get(price_summary, key, nothing)
        if data !== nothing
            open_p = Float64(get(data, "month_open", 0))
            close_p = Float64(get(data, "month_close", 0))
            high_p = Float64(get(data, "month_high", 0))
            low_p = Float64(get(data, "month_low", 0))
            change = Float64(get(data, "change_pct", 0))
            tick_prices[asset] = generate_price_ticks(open_p, close_p, high_p, low_p, days)
            price_data[asset] = Dict("price" => open_p, "change_pct" => 0.0,
                                      "open" => open_p, "close" => close_p)
        end
    end

    markets = build_february_markets(feb_data)

    return SimulationState(
        markets,
        1,
        Date(2026, 2, 1),
        tick_prices,
        price_data,
        false,
        1.0,  # 1 second per day tick
        100.0
    )
end
```

**Step 4: Run tests, verify pass**

**Step 5: Commit**

Record via GitButler: "feat: add February 2026 simulation data loader with price tick generation"

---

## Task 4: Input Handler & Main Loop

**Files:**
- Modify: `src/ConsoleUI.jl` (add input handling)
- Create: `console.jl` (entry point)
- Test: `test/test_console_ui.jl` (add input tests)

**Step 1: Write failing test for input handling**

```julia
@testset "Input handling" begin
    state = ConsoleUI.ConsoleState()

    # TAB cycles quadrants
    new_state = ConsoleUI.handle_key(state, :tab)
    @test new_state.active_quadrant == 2
    new_state = ConsoleUI.handle_key(new_state, :tab)
    @test new_state.active_quadrant == 3
    new_state = ConsoleUI.handle_key(new_state, :tab)
    @test new_state.active_quadrant == 4
    new_state = ConsoleUI.handle_key(new_state, :tab)
    @test new_state.active_quadrant == 1

    # Arrow keys move cursor in Q1
    state.active_quadrant = 1
    state.available_markets = [
        ConsoleUI.MarketOption("m1", "Test 1", "test", "YES", 0.5, "2026-02-28", "Yes", true),
        ConsoleUI.MarketOption("m2", "Test 2", "test", "NO", 0.7, "2026-02-28", "No", false),
    ]
    state.q1_cursor = 1
    new_state = ConsoleUI.handle_key(state, :down)
    @test new_state.q1_cursor == 2
    new_state = ConsoleUI.handle_key(new_state, :up)
    @test new_state.q1_cursor == 1

    # SPACE toggles selection in Q1
    state.q1_cursor = 1
    new_state = ConsoleUI.handle_key(state, :space)
    @test 1 in new_state.selected
    new_state = ConsoleUI.handle_key(new_state, :space)
    @test !(1 in new_state.selected)
end
```

**Step 2: Run test, verify failure**

**Step 3: Implement input handler**

Add to `src/ConsoleUI.jl`:

```julia
# ─────────────────────────────────────────────────────────────
# Input Handling
# ─────────────────────────────────────────────────────────────

function handle_key(state::ConsoleState, key::Symbol)
    # Global keys
    if key == :quit
        state.running = false
        return state
    elseif key == :tab
        state.active_quadrant = mod1(state.active_quadrant + 1, 4)
        return state
    elseif key == :shift_tab
        state.active_quadrant = mod1(state.active_quadrant - 1, 4)
        return state
    elseif key == :refresh
        state.message = "Refreshing..."
        return state
    end

    # Quadrant-specific keys
    if state.active_quadrant == 1
        return handle_q1_input(state, key)
    elseif state.active_quadrant == 2
        return handle_q2_input(state, key)
    elseif state.active_quadrant == 3
        return handle_q3_input(state, key)
    elseif state.active_quadrant == 4
        return handle_q4_input(state, key)
    end

    return state
end

function handle_q1_input(state::ConsoleState, key::Symbol)
    n = length(state.available_markets)
    if key == :up
        state.q1_cursor = max(1, state.q1_cursor - 1)
    elseif key == :down
        state.q1_cursor = min(n, state.q1_cursor + 1)
    elseif key == :space && n > 0
        if state.q1_cursor in state.selected
            delete!(state.selected, state.q1_cursor)
        else
            push!(state.selected, state.q1_cursor)
        end
    elseif key == :left
        tabs = [:daily, :weekly, :monthly]
        idx = findfirst(==(state.market_tab), tabs)
        if idx !== nothing && idx > 1
            state.market_tab = tabs[idx - 1]
            state.q1_cursor = 1
            state.q1_scroll = 0
            state.selected = Set{Int}()
        end
    elseif key == :right
        tabs = [:daily, :weekly, :monthly]
        idx = findfirst(==(state.market_tab), tabs)
        if idx !== nothing && idx < length(tabs)
            state.market_tab = tabs[idx + 1]
            state.q1_cursor = 1
            state.q1_scroll = 0
            state.selected = Set{Int}()
        end
    elseif key == :submit
        # Submit selected bets
        if !isempty(state.selected) && state.sim !== nothing
            submit_bets!(state)
        end
    end
    return state
end

function handle_q2_input(state::ConsoleState, key::Symbol)
    n = length(state.positions)
    if key == :up
        state.q2_cursor = max(1, state.q2_cursor - 1)
    elseif key == :down
        state.q2_cursor = min(n, state.q2_cursor + 1)
    elseif key == :enter
        if state.expanded_position == state.q2_cursor
            state.expanded_position = nothing
        else
            state.expanded_position = state.q2_cursor
        end
    elseif key == :left || key == :right
        tabs = [:contrarian, :weekly, :daily]
        if state.sim !== nothing
            push!(tabs, :sim_feb)
        end
        idx = findfirst(==(state.portfolio_tab), tabs)
        if key == :left && idx !== nothing && idx > 1
            state.portfolio_tab = tabs[idx - 1]
        elseif key == :right && idx !== nothing && idx < length(tabs)
            state.portfolio_tab = tabs[idx + 1]
        end
        state.q2_cursor = 1
        state.q2_scroll = 0
    end
    return state
end

function handle_q3_input(state::ConsoleState, key::Symbol)
    n = length(state.tx_log)
    if state.search_mode
        if key == :escape
            state.search_mode = false
            state.tx_search = ""
        elseif key == :enter
            state.search_mode = false
        elseif key == :backspace
            if !isempty(state.tx_search)
                state.tx_search = state.tx_search[1:end-1]
            end
        end
        # Character input handled separately in read_key
        return state
    end

    if key == :up
        state.tx_scroll = max(0, state.tx_scroll - 1)
    elseif key == :down
        state.tx_scroll = min(max(0, n - 5), state.tx_scroll + 1)
    elseif key == :filter
        # Cycle through filter presets
        if state.tx_filter == Set([:BUY, :SELL, :FLIP, :RESOLVE, :ADJUST, :GENESIS])
            state.tx_filter = Set([:BUY])
        elseif state.tx_filter == Set([:BUY])
            state.tx_filter = Set([:SELL, :FLIP])
        elseif state.tx_filter == Set([:SELL, :FLIP])
            state.tx_filter = Set([:RESOLVE])
        else
            state.tx_filter = Set([:BUY, :SELL, :FLIP, :RESOLVE, :ADJUST, :GENESIS])
        end
        state.tx_scroll = 0
    elseif key == :search
        state.search_mode = true
        state.tx_search = ""
    end
    return state
end

function handle_q4_input(state::ConsoleState, key::Symbol)
    # Q4 is mostly passive; R refreshes
    if key == :refresh
        state.message = "Refreshing intel..."
    end
    return state
end

"""
    submit_bets!(state)

Record selected markets as BUY transactions in the simulation portfolio.
"""
function submit_bets!(state::ConsoleState)
    sim = state.sim
    if sim === nothing return end

    n_selected = length(state.selected)
    per_bet = sim.budget / n_selected

    for idx in state.selected
        if idx <= length(state.available_markets)
            m = state.available_markets[idx]
            shares = floor(Int, per_bet / m.entry_price)
            cost = shares * m.entry_price

            pos = Dict{String, Any}(
                "id" => m.id,
                "market" => m.question,
                "position" => m.position,
                "shares" => shares,
                "totalCost" => cost,
                "avgEntry" => m.entry_price,
                "current" => m.entry_price,
                "confidence" => 50,
                "action" => "hold",
                "reason" => "Sim bet placed",
                "pl" => 0.0,
                "won" => m.won
            )
            push!(state.positions, pos)
        end
    end

    state.selected = Set{Int}()
    state.message = "$(n_selected) bets placed!"
    state.portfolio_tab = :sim_feb
end

# ─────────────────────────────────────────────────────────────
# Raw Terminal Key Reading
# ─────────────────────────────────────────────────────────────

function read_key(io::IO)
    b = read(io, UInt8)

    # ESC sequences
    if b == 0x1b
        if bytesavailable(io) > 0
            b2 = read(io, UInt8)
            if b2 == UInt8('[')
                b3 = read(io, UInt8)
                if b3 == UInt8('A') return :up end
                if b3 == UInt8('B') return :down end
                if b3 == UInt8('C') return :right end
                if b3 == UInt8('D') return :left end
                if b3 == UInt8('Z') return :shift_tab end  # Shift+Tab
            end
        end
        return :escape
    end

    if b == UInt8('\t') return :tab end
    if b == UInt8(' ') return :space end
    if b == UInt8('\r') || b == UInt8('\n') return :enter end
    if b == 0x7f || b == 0x08 return :backspace end  # DEL or BS

    c = Char(b)
    if c == 'q' || c == 'Q' return :quit end
    if c == 'r' || c == 'R' return :refresh end
    if c == 'f' || c == 'F' return :filter end
    if c == 's' || c == 'S' return :submit end
    if c == '/' return :search end

    # If in search mode, return the character
    return Symbol("char_$c")
end

# ─────────────────────────────────────────────────────────────
# Full Frame Render
# ─────────────────────────────────────────────────────────────

function render_header(cols::Int)
    buf = IOBuffer()
    rst = set_color(:reset)
    print(buf, move_to(1, 1))

    # ASCII banner line 1
    print(buf, set_color(:bright_cyan), set_color(:bold))
    banner = " ▄▄▄▄▄▄   PRAESCIENTIA v0.1"
    print(buf, banner)

    # Right side: key hints
    hint = "[TAB] cycle  [Q] quit  [S] submit"
    padding = cols - length(banner) - length(hint) - 2
    if padding > 0
        print(buf, set_color(:dim), " "^padding, set_color(:gray), hint)
    end
    print(buf, rst)

    # Line 2: Tagline
    print(buf, move_to(2, 1), set_color(:dim), set_color(:cyan),
          " ██████▓   \"Too many secrets\"  ░ SETEC ASTRONOMY ░", rst)

    # Sim status on line 2 right
    sim_status = ""
    # Will be filled by caller

    return String(take!(buf))
end

function render_status_bar(state::ConsoleState, row::Int, cols::Int)
    buf = IOBuffer()
    rst = set_color(:reset)

    # Status bar at bottom
    print(buf, move_to(row, 1), set_color(:bg_blue), set_color(:bright_white))
    bar = " $(state.message)"
    if state.sim !== nothing
        sim_info = "  SIM: $(Dates.format(state.sim.sim_date, "yyyy-mm-dd")) Day $(state.sim.day_index)/28  Budget: \$$(round(state.sim.budget, digits=2))"
        bar *= sim_info
    end
    bar *= " "^max(0, cols - length(bar))
    print(buf, truncate_text(bar, cols), rst)

    return String(take!(buf))
end

function render_frame(state::ConsoleState)
    buf = IOBuffer()
    rows, cols = state.term_rows, state.term_cols

    # Minimum terminal size check
    if cols < 80 || rows < 24
        print(buf, clear_screen(), move_to(1, 1),
              set_color(:red), "Terminal too small. Need 80x24, have $(cols)x$(rows)", set_color(:reset))
        return String(take!(buf))
    end

    print(buf, hide_cursor())

    # Header (rows 1-2)
    print(buf, render_header(cols))

    # Calculate quadrant dimensions
    header_rows = 3  # 2 header + 1 separator
    footer_rows = 1  # status bar
    available_rows = rows - header_rows - footer_rows
    half_rows = available_rows ÷ 2
    half_cols = cols ÷ 2

    # Separator line
    print(buf, move_to(3, 1), set_color(:gray), "─"^cols, set_color(:reset))

    # Q1: Top-Left  (Market Select)
    q1_row = header_rows + 1
    q1_col = 1
    print(buf, render_q1_market_select(state, q1_row, q1_col, half_cols, half_rows))

    # Q2: Top-Right (Positions)
    q2_row = header_rows + 1
    q2_col = half_cols + 1
    print(buf, render_q2_positions(state, q2_row, q2_col, cols - half_cols, half_rows))

    # Q3: Bottom-Left (TX Log)
    q3_row = header_rows + half_rows + 1
    q3_col = 1
    print(buf, render_q3_txlog(state, q3_row, q3_col, half_cols, half_rows))

    # Q4: Bottom-Right (Intel)
    q4_row = header_rows + half_rows + 1
    q4_col = half_cols + 1
    print(buf, render_q4_intel(state, q4_row, q4_col, cols - half_cols, half_rows))

    # Status bar
    print(buf, render_status_bar(state, rows, cols))

    return String(take!(buf))
end
```

**Step 4: Run tests, verify pass**

**Step 5: Create `console.jl` entry point**

```julia
#!/usr/bin/env julia
# console.jl — Praescientia Console UI
# Run: julia --project=. console.jl [--sim-feb]
#
# "Too many secrets" — Sneakers (1992)

using Dates
using JSON3

include(joinpath(@__DIR__, "src", "TxLog.jl"))
include(joinpath(@__DIR__, "src", "ConsoleUI.jl"))

using .TxLog
using .ConsoleUI

function load_tx_log_all()
    txs = Dict{String, Any}[]
    for pid in TxLog.list_portfolios()
        path = TxLog.get_log_path(pid)
        portfolio_txs = TxLog.read_transactions(path)
        for tx in portfolio_txs
            tx["_portfolio"] = pid
            push!(txs, tx)
        end
    end
    sort!(txs, by=tx -> get(tx, "timestamp", ""), rev=true)
    return txs
end

function load_positions(portfolio_id::Symbol)
    pid = string(portfolio_id)
    if pid in TxLog.list_portfolios()
        state = TxLog.calculate_state(pid)
        positions = Dict{String,Any}[]
        for (_, pos) in get(state, "positions", Dict())
            push!(positions, pos)
        end
        return positions
    end
    return Dict{String,Any}[]
end

function update_sim_prices!(state::ConsoleUI.ConsoleState)
    sim = state.sim
    if sim === nothing || sim.day_index > 28
        return
    end

    # Update asset prices to current sim day
    for (asset, ticks) in sim.tick_prices
        if sim.day_index <= length(ticks)
            price = ticks[sim.day_index]
            open_price = ticks[1]
            change_pct = (price - open_price) / open_price * 100
            state.prices[asset] = Dict("price" => price, "change_pct" => change_pct)
        end
    end

    # Update position P&L based on simulation progress
    # Positions move toward resolution price over time
    t = sim.day_index / 28.0  # progress 0→1
    for pos in state.positions
        won = get(pos, "won", nothing)
        if won !== nothing
            entry = get(pos, "avgEntry", 0.5)
            target = won ? 1.0 : 0.0
            # Price drifts toward outcome with noise
            current = entry + (target - entry) * t * (0.7 + rand() * 0.3)
            current = clamp(current, 0.01, 0.99)
            pos["current"] = current
            shares = get(pos, "shares", 0)
            pos["pl"] = (current - entry) * shares
        end
    end

    # Update Hopper metrics
    total_cost = sum(get(p, "totalCost", 0.0) for p in state.positions; init=0.0)
    total_unrealized = sum(isa(get(p, "pl", 0), Number) ? get(p, "pl", 0.0) : 0.0 for p in state.positions; init=0.0)
    best_case = sum(get(p, "shares", 0) * (get(p, "won", false) ? 1.0 : 0.0) - get(p, "totalCost", 0.0) for p in state.positions; init=0.0)

    state.hopper_metrics = Dict{String, Any}(
        "total_at_risk" => total_cost,
        "worst_case" => -total_cost,
        "best_case" => best_case,
        "risk_reward" => total_cost > 0 ? abs(best_case) / total_cost : 0.0
    )

    state.last_refresh = now(UTC)
end

function run_console()
    sim_mode = "--sim-feb" in ARGS

    # Initialize state
    state = ConsoleUI.ConsoleState()

    # Load existing TX log
    state.tx_log = load_tx_log_all()

    # Load positions for default tab
    state.positions = load_positions(state.portfolio_tab)

    # Build signals from CLAUDE.md key dates
    state.signals = [
        "Q1 GDP Advance — Apr 30",
        "FOMC Meeting — May 6-7",
        "FOMC Meeting — Jun 17-18",
        "Q2 GDP — Jul 30"
    ]

    # Load simulation if requested
    if sim_mode
        feb_path = joinpath(@__DIR__, "data", "february_2026_resolved.json")
        jan_path = joinpath(@__DIR__, "data", "january_2026_resolved.json")
        if isfile(feb_path)
            state.sim = ConsoleUI.load_february_simulation(feb_path, jan_path)
            state.available_markets = state.sim.markets
            state.market_tab = :monthly  # Feb markets
            state.message = "SIM MODE: February 2026 — Select bets, then [S]ubmit"
            state.portfolio_tab = :sim_feb
        else
            state.message = "ERROR: february_2026_resolved.json not found"
        end
    else
        state.message = "LIVE MODE — Use --sim-feb for simulation"
    end

    # Raw terminal mode
    terminal = nothing
    old_termios = nothing

    try
        # Enter raw mode
        if Sys.isunix()
            old_termios = read(`stty -g`, String) |> strip
            run(`stty raw -echo`)
        end

        # Initial render
        print(stdout, ConsoleUI.clear_screen())
        print(stdout, ConsoleUI.render_frame(state))
        flush(stdout)

        last_tick = time()
        tick_interval = state.sim !== nothing ? state.sim.speed : 999.0

        while state.running
            # Check for input (non-blocking with timeout)
            if bytesavailable(stdin) > 0
                key = ConsoleUI.read_key(stdin)

                # Handle search mode character input
                if state.search_mode && state.active_quadrant == 3
                    key_str = string(key)
                    if startswith(key_str, "char_")
                        state.tx_search *= key_str[6:end]
                    else
                        ConsoleUI.handle_key(state, key)
                    end
                else
                    ConsoleUI.handle_key(state, key)
                end

                # Refresh positions when tab changes
                if state.portfolio_tab != :sim_feb
                    state.positions = load_positions(state.portfolio_tab)
                end

                # Re-render
                state.term_rows, state.term_cols = displaysize(stdout)
                print(stdout, ConsoleUI.render_frame(state))
                flush(stdout)
            end

            # Simulation tick
            if state.sim !== nothing && time() - last_tick >= tick_interval
                if state.sim.day_index <= 28
                    update_sim_prices!(state)
                    state.sim.day_index += 1
                    state.sim.sim_date += Day(1)
                    state.message = "Day $(state.sim.day_index)/28 — $(Dates.format(state.sim.sim_date, "u d, yyyy"))"

                    if state.sim.day_index > 28
                        # Resolution: finalize all positions
                        for pos in state.positions
                            won = get(pos, "won", false)
                            pos["current"] = won ? 1.0 : 0.0
                            shares = get(pos, "shares", 0)
                            pos["pl"] = (pos["current"] - get(pos, "avgEntry", 0.5)) * shares
                            pos["action"] = "closed"
                            pos["reason"] = won ? "RESOLVED: WON" : "RESOLVED: LOST"
                        end
                        state.message = "SIMULATION COMPLETE — All markets resolved"
                    end

                    print(stdout, ConsoleUI.render_frame(state))
                    flush(stdout)
                end
                last_tick = time()
            end

            sleep(0.05)  # 50ms poll interval
        end

    finally
        # Restore terminal
        if Sys.isunix() && old_termios !== nothing
            run(`stty $old_termios`)
        end
        print(stdout, ConsoleUI.show_cursor())
        print(stdout, ConsoleUI.clear_screen())
        print(stdout, ConsoleUI.move_to(1, 1))
        println("Praescientia console closed.")
        flush(stdout)
    end
end

# Entry point
if abspath(PROGRAM_FILE) == @__FILE__
    run_console()
end
```

**Step 6: Run tests, verify pass**

Run: `cd /Volumes/Sidecar/GraceLMP/Praescientia && julia --project=. test/test_console_ui.jl`

**Step 7: Commit**

Record via GitButler: "feat: add console.jl entry point with Feb simulation loop and input handling"

---

## Task 5: Integration Test & Polish

**Files:**
- Modify: `test/runtests.jl` (add ConsoleUI tests)
- Modify: `src/ConsoleUI.jl` (any fixes from testing)

**Step 1: Add ConsoleUI to test suite**

```julia
# In test/runtests.jl, add:
@testset "ConsoleUI Module" begin
    include("test_console_ui.jl")
end
```

**Step 2: Run full test suite**

Run: `cd /Volumes/Sidecar/GraceLMP/Praescientia && julia --project=. test/runtests.jl`

**Step 3: Manual smoke test**

Run: `cd /Volumes/Sidecar/GraceLMP/Praescientia && julia --project=. console.jl --sim-feb`

Verify:
- [ ] 4 quadrants render correctly
- [ ] TAB cycles active quadrant (cyan border moves)
- [ ] Q1: Arrow keys move cursor, SPACE toggles markets
- [ ] Q1: S submits bets, positions appear in Q2
- [ ] Q3: Shows transaction history, F cycles filters
- [ ] Q4: Shows price ticks advancing each second
- [ ] Simulation advances day-by-day, P&L updates in real-time
- [ ] Q key exits cleanly, terminal restored

**Step 4: Fix any rendering issues found during smoke test**

**Step 5: Final commit**

Record via GitButler: "feat: complete console UI with February 2026 simulation"

---

## Summary

| Task | Description | Files | Est. Lines |
|------|-------------|-------|------------|
| 1 | ANSI rendering engine | `src/ConsoleUI.jl`, `test/test_console_ui.jl` | ~120 |
| 2 | Quadrant renderers (Q1-Q4) | `src/ConsoleUI.jl` | ~300 |
| 3 | February simulation loader | `src/ConsoleUI.jl` | ~120 |
| 4 | Input handler + main loop | `src/ConsoleUI.jl`, `console.jl` | ~250 |
| 5 | Integration test + polish | `test/runtests.jl` | ~20 |

**Total: ~810 lines of new code across 3 files.**

**Run command:** `julia --project=. console.jl --sim-feb`

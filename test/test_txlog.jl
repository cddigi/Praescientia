"""
    Test suite for TxLog module

Run with: julia --project=. test/test_txlog.jl
"""

using Test

# Include the TxLog module
include(joinpath(@__DIR__, "..", "src", "TxLog.jl"))
using .TxLog

# Use a temporary directory for test portfolios
const TEST_DIR = mktempdir()
const TEST_PORTFOLIOS_DIR = joinpath(TEST_DIR, "portfolios")
const TEST_ARCHIVE_DIR = joinpath(TEST_PORTFOLIOS_DIR, "archive")

# Override the module constants for testing
function setup_test_dirs()
    mkpath(TEST_PORTFOLIOS_DIR)
    mkpath(TEST_ARCHIVE_DIR)
end

# Clean up test files
function cleanup_test_files()
    rm(TEST_DIR, recursive=true, force=true)
end

@testset "TxLog Module Tests" begin

    @testset "Transaction ID Generation" begin
        id1 = TxLog.generate_tx_id()
        id2 = TxLog.generate_tx_id()

        @test startswith(id1, "tx_")
        @test startswith(id2, "tx_")
        @test id1 != id2  # Should be unique
        @test length(id1) > 10
    end

    @testset "Transaction Hashing" begin
        tx1 = Dict("type" => "BUY", "amount" => 100)
        tx2 = Dict("type" => "BUY", "amount" => 100)
        tx3 = Dict("type" => "SELL", "amount" => 100)

        hash1 = TxLog.hash_transaction(tx1)
        hash2 = TxLog.hash_transaction(tx2)
        hash3 = TxLog.hash_transaction(tx3)

        @test length(hash1) == 16
        @test hash1 == hash2  # Same content should have same hash
        @test hash1 != hash3  # Different content should have different hash
    end

    @testset "Directory Setup" begin
        TxLog.ensure_directories()
        @test isdir(TxLog.PORTFOLIOS_DIR)
        @test isdir(TxLog.ARCHIVE_DIR)
    end

    @testset "Portfolio Initialization" begin
        # Clean up any existing test portfolio
        test_log = TxLog.get_log_path("test_init")
        isfile(test_log) && rm(test_log)

        # Initialize portfolio
        tx = TxLog.init_portfolio("test_init", Dict(
            "name" => "Test Portfolio",
            "color" => "#ff0000",
            "status" => "active",
            "description" => "Test description"
        ))

        @test haskey(tx, "id")
        @test tx["type"] == TxLog.TX_TYPE.GENESIS
        @test tx["name"] == "Test Portfolio"
        @test tx["color"] == "#ff0000"

        # Verify file was created
        @test isfile(test_log)

        # Should throw error if trying to reinitialize
        @test_throws ErrorException TxLog.init_portfolio("test_init", Dict(
            "name" => "Duplicate",
            "color" => "#00ff00",
            "status" => "active"
        ))

        # Clean up
        rm(test_log)
    end

    @testset "Buy Transaction" begin
        test_log = TxLog.get_log_path("test_buy")
        isfile(test_log) && rm(test_log)

        # Initialize portfolio first
        TxLog.init_portfolio("test_buy", Dict(
            "name" => "Buy Test",
            "color" => "#00ff00",
            "status" => "active"
        ))

        # Record buy
        tx = TxLog.record_buy("test_buy";
            positionId="pos1",
            market="Test Market",
            position="YES",
            shares=100,
            price=0.5,
            confidence=75,
            action="hold",
            reason="Test buy"
        )

        @test tx["type"] == TxLog.TX_TYPE.BUY
        @test tx["positionId"] == "pos1"
        @test tx["shares"] == 100
        @test tx["price"] == 0.5

        # Verify state
        state = TxLog.calculate_state("test_buy")
        @test haskey(state["positions"], "pos1")
        @test state["positions"]["pos1"]["shares"] == 100
        @test state["positions"]["pos1"]["avgEntry"] == 0.5
        @test state["positions"]["pos1"]["totalCost"] == 50.0

        # Clean up
        rm(test_log)
    end

    @testset "Sell Transaction" begin
        test_log = TxLog.get_log_path("test_sell")
        isfile(test_log) && rm(test_log)

        # Initialize and buy
        TxLog.init_portfolio("test_sell", Dict(
            "name" => "Sell Test",
            "color" => "#0000ff",
            "status" => "active"
        ))

        TxLog.record_buy("test_sell";
            positionId="pos1",
            market="Test Market",
            position="YES",
            shares=100,
            price=0.5,
            confidence=75
        )

        # Sell at profit
        tx = TxLog.record_sell("test_sell";
            positionId="pos1",
            shares=100,
            price=0.7,
            reason="Taking profit"
        )

        @test tx["type"] == TxLog.TX_TYPE.SELL

        # Verify state
        state = TxLog.calculate_state("test_sell")
        @test state["positions"]["pos1"]["shares"] == 0
        @test state["positions"]["pos1"]["action"] == "closed"
        @test state["realized"] == 20.0  # (0.7 - 0.5) * 100

        # Clean up
        rm(test_log)
    end

    @testset "Flip Transaction" begin
        test_log = TxLog.get_log_path("test_flip")
        isfile(test_log) && rm(test_log)

        # Initialize and buy YES
        TxLog.init_portfolio("test_flip", Dict(
            "name" => "Flip Test",
            "color" => "#ffff00",
            "status" => "active"
        ))

        TxLog.record_buy("test_flip";
            positionId="pos1",
            market="Test Market",
            position="YES",
            shares=100,
            price=0.5
        )

        # Flip position
        tx = TxLog.record_flip("test_flip";
            positionId="pos1",
            price=0.4,
            reason="Reversing position"
        )

        @test tx["type"] == TxLog.TX_TYPE.FLIP

        # Verify position flipped
        state = TxLog.calculate_state("test_flip")
        @test state["positions"]["pos1"]["position"] == "NO"
        @test state["positions"]["pos1"]["avgEntry"] == 0.4

        # Clean up
        rm(test_log)
    end

    @testset "Chain Verification" begin
        test_log = TxLog.get_log_path("test_chain")
        isfile(test_log) && rm(test_log)

        # Create valid chain
        TxLog.init_portfolio("test_chain", Dict(
            "name" => "Chain Test",
            "color" => "#ff00ff",
            "status" => "active"
        ))

        TxLog.record_buy("test_chain";
            positionId="pos1",
            market="Market 1",
            position="YES",
            shares=50,
            price=0.3
        )

        TxLog.record_buy("test_chain";
            positionId="pos2",
            market="Market 2",
            position="NO",
            shares=75,
            price=0.6
        )

        # Verify chain
        result = TxLog.verify_chain("test_chain")
        @test result["valid"] == true
        @test isempty(result["errors"])
        @test result["transactionCount"] == 3  # genesis + 2 buys

        # Clean up
        rm(test_log)
    end

    @testset "State Calculation" begin
        test_log = TxLog.get_log_path("test_state")
        isfile(test_log) && rm(test_log)

        TxLog.init_portfolio("test_state", Dict(
            "name" => "State Test",
            "color" => "#00ffff",
            "status" => "active"
        ))

        # Multiple buys at different prices (dollar cost averaging)
        TxLog.record_buy("test_state";
            positionId="pos1",
            market="DCA Market",
            position="YES",
            shares=100,
            price=0.4
        )

        TxLog.record_buy("test_state";
            positionId="pos1",
            market="DCA Market",
            position="YES",
            shares=100,
            price=0.6
        )

        state = TxLog.calculate_state("test_state")

        # Average entry should be (0.4*100 + 0.6*100) / 200 = 0.5
        @test state["positions"]["pos1"]["shares"] == 200
        @test state["positions"]["pos1"]["avgEntry"] == 0.5
        @test state["positions"]["pos1"]["totalCost"] == 100.0  # 40 + 60

        # Clean up
        rm(test_log)
    end

    @testset "Adjust Transaction" begin
        test_log = TxLog.get_log_path("test_adjust")
        isfile(test_log) && rm(test_log)

        TxLog.init_portfolio("test_adjust", Dict(
            "name" => "Adjust Test",
            "color" => "#888888",
            "status" => "active"
        ))

        TxLog.record_buy("test_adjust";
            positionId="pos1",
            market="Adjust Market",
            position="YES",
            shares=100,
            price=0.5,
            confidence=50
        )

        # Adjust confidence and action
        TxLog.record_adjust("test_adjust";
            positionId="pos1",
            confidence=80,
            action="sell",
            reason="Updated recommendation"
        )

        state = TxLog.calculate_state("test_adjust")
        @test state["positions"]["pos1"]["confidence"] == 80
        @test state["positions"]["pos1"]["action"] == "sell"
        @test state["positions"]["pos1"]["reason"] == "Updated recommendation"

        # Clean up
        rm(test_log)
    end

    @testset "List Portfolios" begin
        # Use unique test portfolio names
        test_name_a = "list_test_$(rand(1000:9999))"
        test_name_b = "list_test_$(rand(1000:9999))"

        # Create some portfolios
        TxLog.init_portfolio(test_name_a, Dict("name" => "A", "color" => "#aaa", "status" => "active"))
        TxLog.init_portfolio(test_name_b, Dict("name" => "B", "color" => "#bbb", "status" => "active"))

        portfolios = TxLog.list_portfolios()
        @test test_name_a in portfolios
        @test test_name_b in portfolios

        # Clean up
        rm(TxLog.get_log_path(test_name_a))
        rm(TxLog.get_log_path(test_name_b))
    end

    @testset "Log Stats" begin
        test_log = TxLog.get_log_path("test_stats")
        isfile(test_log) && rm(test_log)

        TxLog.init_portfolio("test_stats", Dict(
            "name" => "Stats Test",
            "color" => "#123456",
            "status" => "active"
        ))

        TxLog.record_buy("test_stats";
            positionId="pos1",
            market="Stats Market",
            position="YES",
            shares=100,
            price=0.5
        )

        stats = TxLog.get_log_stats("test_stats")

        @test stats["portfolioId"] == "test_stats"
        @test stats["transactionCount"] == 2  # genesis + buy
        @test stats["currentLogSize"] > 0
        @test stats["archiveCount"] == 0

        # Clean up
        rm(test_log)
    end

    @testset "Unrealized P/L Calculation" begin
        test_log = TxLog.get_log_path("test_unrealized")
        isfile(test_log) && rm(test_log)

        TxLog.init_portfolio("test_unrealized", Dict(
            "name" => "Unrealized Test",
            "color" => "#abcdef",
            "status" => "active"
        ))

        # Buy at 0.4, current stays at 0.4
        TxLog.record_buy("test_unrealized";
            positionId="pos1",
            market="Unrealized Market",
            position="YES",
            shares=100,
            price=0.4
        )

        state = TxLog.calculate_state("test_unrealized")
        # P/L = current_value - cost = 0.4 * 100 - 40 = 0
        @test state["unrealized"] == 0.0

        # Update current price
        TxLog.record_adjust("test_unrealized";
            positionId="pos1",
            current=0.6
        )

        state = TxLog.calculate_state("test_unrealized")
        # P/L = 0.6 * 100 - 40 = 20
        @test state["positions"]["pos1"]["current"] == 0.6
        @test state["positions"]["pos1"]["pl"] == 20.0
        @test state["unrealized"] == 20.0

        # Clean up
        rm(test_log)
    end

end

println("\nAll TxLog tests completed!")

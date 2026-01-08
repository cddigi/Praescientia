"""
    Test suite for Praescientia HTTP Server

Run with: julia --project=. test/test_server.jl

Note: This test starts a server on port 3099 for testing.
"""

using Test
using HTTP
using JSON3

# Server configuration for testing
const TEST_PORT = 3099
const BASE_URL = "http://localhost:$(TEST_PORT)"

# Include server code (but don't start it yet)
include(joinpath(@__DIR__, "..", "server.jl"))

# Server process handle
server_task = nothing

function start_test_server()
    global server_task
    server_task = @async begin
        try
            HTTP.serve(handle_request, "0.0.0.0", TEST_PORT)
        catch e
            if !(e isa InterruptException)
                @error "Server error" exception=e
            end
        end
    end
    sleep(2)  # Give server time to start
    println("Test server started on port $TEST_PORT")
end

function stop_test_server()
    global server_task
    if server_task !== nothing
        # Can't cleanly stop HTTP.serve, just let it be
        server_task = nothing
    end
end

# Helper function to make JSON POST requests
function post_json(url, data)
    body = JSON3.write(data)
    response = HTTP.post(url, ["Content-Type" => "application/json"], body)
    return JSON3.read(String(response.body))
end

# Helper function to make GET requests
function get_json(url)
    response = HTTP.get(url)
    return JSON3.read(String(response.body))
end

@testset "Praescientia Server Tests" begin

    # Start the test server
    start_test_server()

    @testset "Static File Serving" begin
        # Test dashboard HTML
        response = HTTP.get("$(BASE_URL)/")
        @test response.status == 200
        @test occursin("text/html", String(HTTP.header(response, "Content-Type", "")))

        body = String(response.body)
        @test occursin("PRAESCIENTIA", body)
        @test occursin("D3.js", body) || occursin("d3.v7", body)
    end

    @testset "GET /api/portfolios" begin
        result = get_json("$(BASE_URL)/api/portfolios")

        @test result.success == true
        @test haskey(result, :data)
        @test haskey(result, :lastUpdated)

        # Should have the default portfolios
        data = result.data
        # JSON3 uses Symbol keys when accessed via property syntax
        data_keys = collect(keys(data))
        @test :daily in data_keys || "daily" in data_keys
        @test :weekly in data_keys || "weekly" in data_keys
        @test :contrarian in data_keys || "contrarian" in data_keys
    end

    @testset "GET /api/portfolios/:id" begin
        result = get_json("$(BASE_URL)/api/portfolios/weekly")

        @test result.success == true
        @test haskey(result, :data)

        data = result.data
        @test haskey(data, :name) || haskey(data, "name")
        @test haskey(data, :positions) || haskey(data, "positions")
        @test haskey(data, :realized) || haskey(data, "realized")
        @test haskey(data, :unrealized) || haskey(data, "unrealized")
    end

    @testset "GET /api/portfolios/:id/logs" begin
        result = get_json("$(BASE_URL)/api/portfolios/weekly/logs")

        @test result.success == true
        @test haskey(result, :data)

        data = result.data
        @test haskey(data, :portfolioId) || haskey(data, "portfolioId")
        @test haskey(data, :transactionCount) || haskey(data, "transactionCount")
        @test haskey(data, :currentLogSize) || haskey(data, "currentLogSize")
    end

    @testset "GET /api/portfolios/:id/txs" begin
        result = get_json("$(BASE_URL)/api/portfolios/weekly/txs")

        @test result.success == true
        @test haskey(result, :data)

        data = result.data
        @test haskey(data, :transactions) || haskey(data, "transactions")
        @test haskey(data, :count) || haskey(data, "count")
    end

    @testset "GET /api/audit/:id" begin
        result = get_json("$(BASE_URL)/api/audit/weekly")

        @test result.success == true
        @test haskey(result, :data)

        data = result.data
        @test haskey(data, :chainIntegrity) || haskey(data, "chainIntegrity")
        @test haskey(data, :logStats) || haskey(data, "logStats")
    end

    @testset "POST /api/reset" begin
        result = post_json("$(BASE_URL)/api/reset", Dict())

        @test result.success == true
        @test haskey(result, :message)

        # Verify portfolios were recreated
        portfolios = get_json("$(BASE_URL)/api/portfolios")
        @test portfolios.success == true
    end

    @testset "POST /api/trades - Sell" begin
        # Reset first to ensure clean state
        post_json("$(BASE_URL)/api/reset", Dict())

        # Execute a sell trade
        result = post_json("$(BASE_URL)/api/trades", Dict(
            "actions" => Dict(
                "sell" => [Dict("id" => "w3")],
                "buy" => [],
                "flip" => []
            )
        ))

        @test result.success == true
        @test haskey(result, :results)
        @test haskey(result, :message)

        results = result.results
        @test results.sold == 1 || get(results, "sold", 0) == 1
    end

    @testset "POST /api/trades - Flip" begin
        # Reset first
        post_json("$(BASE_URL)/api/reset", Dict())

        # Execute a flip trade
        result = post_json("$(BASE_URL)/api/trades", Dict(
            "actions" => Dict(
                "sell" => [],
                "buy" => [],
                "flip" => [Dict("id" => "w1")]
            )
        ))

        @test result.success == true
        results = result.results
        @test results.flipped == 1 || get(results, "flipped", 0) == 1
    end

    @testset "POST /api/trades - Buy (Adjust)" begin
        # Reset first
        post_json("$(BASE_URL)/api/reset", Dict())

        # Execute a buy action (which records an adjust)
        result = post_json("$(BASE_URL)/api/trades", Dict(
            "actions" => Dict(
                "sell" => [],
                "buy" => [Dict("id" => "c1")],
                "flip" => []
            )
        ))

        @test result.success == true
        results = result.results
        @test results.bought == 1 || get(results, "bought", 0) == 1
    end

    @testset "Chain Integrity After Operations" begin
        # Reset and verify chain integrity
        post_json("$(BASE_URL)/api/reset", Dict())

        for portfolio_id in ["daily", "weekly", "contrarian"]
            audit = get_json("$(BASE_URL)/api/audit/$(portfolio_id)")
            @test audit.success == true

            chain_integrity = audit.data.chainIntegrity
            valid = get(chain_integrity, :valid, get(chain_integrity, "valid", false))
            @test valid == true
        end
    end

    @testset "CORS Headers" begin
        response = HTTP.request("OPTIONS", "$(BASE_URL)/api/portfolios")
        @test response.status == 200

        # Check CORS headers
        headers = Dict(response.headers)
        @test haskey(headers, "Access-Control-Allow-Origin")
        @test haskey(headers, "Access-Control-Allow-Methods")
    end

    @testset "Error Handling - Invalid Endpoint" begin
        response = HTTP.get("$(BASE_URL)/api/nonexistent"; status_exception=false)
        @test response.status == 404
    end

    # Clean up - reset to defaults
    @testset "Cleanup" begin
        result = post_json("$(BASE_URL)/api/reset", Dict())
        @test result.success == true
    end

    # Stop the test server
    stop_test_server()
end

println("\nAll server tests completed!")

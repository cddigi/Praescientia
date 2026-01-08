"""
    Praescientia Test Suite Runner

Run all tests with: julia --project=. test/runtests.jl
"""

using Test

@testset "Praescientia Test Suite" begin
    @testset "TxLog Module" begin
        include("test_txlog.jl")
    end

    @testset "HTTP Server" begin
        include("test_server.jl")
    end
end

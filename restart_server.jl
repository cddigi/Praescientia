#!/usr/bin/env julia
"""
    restart_server.jl

Kill any running Praescientia server and restart it.

Usage:
  julia restart_server.jl              # Default port 3000
  julia restart_server.jl --port=8080  # Custom port
"""

# Parse port from arguments
port = 3000
for arg in ARGS
    if startswith(arg, "--port=")
        port = parse(Int, split(arg, "=")[2])
    end
end

println("Restarting Praescientia server on port $port...")

# Kill any process using the port
println("Killing processes on port $port...")
run(ignorestatus(`sh -c "lsof -ti:$port | xargs kill -9 2>/dev/null"`))
sleep(1)

# Also kill any julia server.jl processes
println("Killing any julia server.jl processes...")
run(ignorestatus(`pkill -f "julia.*server.jl"`))
sleep(1)

# Start the server
println("Starting server...")
server_path = joinpath(@__DIR__, "server.jl")

# Run server in foreground (Ctrl+C to stop)
run(`julia --project=$(@__DIR__) $server_path --port=$port`)

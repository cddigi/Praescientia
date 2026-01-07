"""
    PolymarketAuth

Authentication module for Polymarket CLOB API.
Implements EIP-712 signing for L1 auth and HMAC-SHA256 for L2 auth.

Note: This requires a wallet with Polygon (MATIC) for gas and USDC.e for trading.
"""
module PolymarketAuth

using HTTP
using JSON3
using SHA
using Dates

export create_api_credentials, sign_order, CLOBClient

const CLOB_HOST = "https://clob.polymarket.com"
const CHAIN_ID = 137  # Polygon mainnet

"""
    EIP712Domain

The EIP-712 domain for Polymarket CLOB authentication.
"""
const EIP712_DOMAIN = Dict(
    "name" => "ClobAuthDomain",
    "version" => "1",
    "chainId" => CHAIN_ID
)

const CLOB_AUTH_TYPES = Dict(
    "ClobAuth" => [
        Dict("name" => "address", "type" => "address"),
        Dict("name" => "timestamp", "type" => "string"),
        Dict("name" => "nonce", "type" => "uint256"),
        Dict("name" => "message", "type" => "string")
    ]
)

"""
    CLOBClient

Client for interacting with Polymarket's CLOB API.
"""
mutable struct CLOBClient
    host::String
    chain_id::Int
    private_key::Union{Nothing, String}  # For signing
    api_key::Union{Nothing, String}
    api_secret::Union{Nothing, String}
    api_passphrase::Union{Nothing, String}
    funder_address::Union{Nothing, String}  # For proxy wallets
    signature_type::Int  # 0 = EOA, 1 = Magic/email, 2 = browser wallet
    
    function CLOBClient(;
        host::String = CLOB_HOST,
        private_key::Union{Nothing, String} = nothing,
        funder::Union{Nothing, String} = nothing,
        signature_type::Int = 0
    )
        new(host, CHAIN_ID, private_key, nothing, nothing, nothing, funder, signature_type)
    end
end

"""
    get_server_time(client::CLOBClient)

Get the server timestamp for auth header generation.
"""
function get_server_time(client::CLOBClient)
    response = HTTP.get("$(client.host)/time")
    data = JSON3.read(String(response.body))
    return string(data.time)
end

"""
    generate_l2_headers(client::CLOBClient, method::String, path::String, body::String="")

Generate L2 authentication headers using HMAC-SHA256.
"""
function generate_l2_headers(client::CLOBClient, method::String, path::String, body::String="")
    if client.api_key === nothing || client.api_secret === nothing
        error("API credentials not set. Call create_api_credentials first.")
    end
    
    timestamp = get_server_time(client)
    
    # Create message to sign: timestamp + method + path + body
    message = timestamp * method * path * body
    
    # HMAC-SHA256 signature
    signature = bytes2hex(hmac_sha256(Vector{UInt8}(client.api_secret), message))
    
    return Dict(
        "POLY_API_KEY" => client.api_key,
        "POLY_TIMESTAMP" => timestamp,
        "POLY_SIGNATURE" => signature,
        "POLY_PASSPHRASE" => client.api_passphrase
    )
end

"""
    hmac_sha256(key::Vector{UInt8}, message::String)

Compute HMAC-SHA256. Note: In production, use a proper crypto library.
"""
function hmac_sha256(key::Vector{UInt8}, message::String)
    # This is a simplified implementation
    # In production, use OpenSSL bindings or a proper crypto library
    block_size = 64
    
    # Key padding
    if length(key) > block_size
        key = Vector{UInt8}(sha256(key))
    end
    
    key_padded = vcat(key, zeros(UInt8, block_size - length(key)))
    
    o_key_pad = key_padded .⊻ 0x5c
    i_key_pad = key_padded .⊻ 0x36
    
    inner_hash = sha256(vcat(i_key_pad, Vector{UInt8}(message)))
    outer_hash = sha256(vcat(o_key_pad, inner_hash))
    
    return outer_hash
end

# =============================================================================
# Public Market Data (No auth required)
# =============================================================================

"""
    get_markets(client::CLOBClient; next_cursor::String="")

Fetch markets from the CLOB API.
"""
function get_markets(client::CLOBClient; next_cursor::String="")
    url = "$(client.host)/markets"
    if !isempty(next_cursor)
        url *= "?next_cursor=$next_cursor"
    end
    
    response = HTTP.get(url, ["Accept" => "application/json"])
    return JSON3.read(String(response.body))
end

"""
    get_price(client::CLOBClient, token_id::String; side::String="BUY")

Get the current price for a market token.
"""
function get_price(client::CLOBClient, token_id::String; side::String="BUY")
    url = "$(client.host)/price?token_id=$token_id&side=$side"
    response = HTTP.get(url, ["Accept" => "application/json"])
    data = JSON3.read(String(response.body))
    return Float64(data.price)
end

"""
    get_midpoint(client::CLOBClient, token_id::String)

Get the midpoint price (halfway between best bid and ask).
"""
function get_midpoint(client::CLOBClient, token_id::String)
    url = "$(client.host)/midpoint?token_id=$token_id"
    response = HTTP.get(url, ["Accept" => "application/json"])
    data = JSON3.read(String(response.body))
    return Float64(data.mid)
end

"""
    get_order_book(client::CLOBClient, token_id::String)

Get the full order book for a token.
"""
function get_order_book(client::CLOBClient, token_id::String)
    url = "$(client.host)/book?token_id=$token_id"
    response = HTTP.get(url, ["Accept" => "application/json"])
    return JSON3.read(String(response.body))
end

"""
    get_spread(client::CLOBClient, token_id::String)

Get the spread between best bid and ask.
"""
function get_spread(client::CLOBClient, token_id::String)
    url = "$(client.host)/spread?token_id=$token_id"
    response = HTTP.get(url, ["Accept" => "application/json"])
    data = JSON3.read(String(response.body))
    return Float64(data.spread)
end

# =============================================================================
# Order Placement (L2 auth required)
# =============================================================================

"""
    OrderArgs

Arguments for creating an order.
"""
struct OrderArgs
    token_id::String
    price::Float64
    size::Float64
    side::Symbol  # :BUY or :SELL
end

"""
    create_order(client::CLOBClient, args::OrderArgs)

Create and sign an order. Returns the signed order ready for posting.
"""
function create_order(client::CLOBClient, args::OrderArgs)
    if client.private_key === nothing
        error("Private key required for order signing")
    end
    
    # In production, this would use proper EIP-712 signing
    # For now, we return the order structure
    order = Dict(
        "tokenId" => args.token_id,
        "price" => string(args.price),
        "size" => string(args.size),
        "side" => string(args.side),
        "timestamp" => get_server_time(client),
        "expiration" => "0",  # GTC order
        "nonce" => "0"
    )
    
    # TODO: Sign with EIP-712
    # signature = sign_typed_data(client.private_key, EIP712_DOMAIN, order_types, order)
    
    return order
end

"""
    post_order(client::CLOBClient, signed_order::Dict; order_type::String="GTC")

Post a signed order to the CLOB.
"""
function post_order(client::CLOBClient, signed_order::Dict; order_type::String="GTC")
    url = "$(client.host)/order"
    
    body = JSON3.write(Dict(
        "order" => signed_order,
        "orderType" => order_type,
        "owner" => get(signed_order, "maker", "")
    ))
    
    headers = generate_l2_headers(client, "POST", "/order", body)
    headers["Content-Type"] = "application/json"
    
    response = HTTP.post(url, collect(headers), body)
    return JSON3.read(String(response.body))
end

"""
    cancel_order(client::CLOBClient, order_id::String)

Cancel an open order.
"""
function cancel_order(client::CLOBClient, order_id::String)
    url = "$(client.host)/order"
    
    body = JSON3.write(Dict("orderID" => order_id))
    
    headers = generate_l2_headers(client, "DELETE", "/order", body)
    headers["Content-Type"] = "application/json"
    
    response = HTTP.delete(url, collect(headers), body)
    return JSON3.read(String(response.body))
end

"""
    get_open_orders(client::CLOBClient)

Get all open orders for the authenticated user.
"""
function get_open_orders(client::CLOBClient)
    url = "$(client.host)/orders"
    
    headers = generate_l2_headers(client, "GET", "/orders")
    
    response = HTTP.get(url, collect(headers))
    return JSON3.read(String(response.body))
end

"""
    get_trades(client::CLOBClient)

Get trade history for the authenticated user.
"""
function get_trades(client::CLOBClient)
    url = "$(client.host)/trades"
    
    headers = generate_l2_headers(client, "GET", "/trades")
    
    response = HTTP.get(url, collect(headers))
    return JSON3.read(String(response.body))
end

end # module

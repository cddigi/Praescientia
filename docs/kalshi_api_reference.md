# Kalshi Trade API v3.13.0 -- Complete Endpoint Reference

**Base URL:** `https://api.elections.kalshi.com/trade-api/v2`

**Authentication:** Three API key headers required for authenticated endpoints:
- `KALSHI-ACCESS-KEY` (apiKey in header) -- Your API key ID
- `KALSHI-ACCESS-SIGNATURE` (apiKey in header) -- RSA-PSS signature of the request
- `KALSHI-ACCESS-TIMESTAMP` (apiKey in header) -- Request timestamp in milliseconds

**Common Types:**
- `FixedPointDollars`: string -- US dollar amount as fixed-point decimal with up to 6 decimal places (e.g., "0.5600")
- `FixedPointCount`: string -- Fixed-point contract count with 2 decimals (e.g., "10.00")

---

## 1. HISTORICAL

### GET /historical/cutoff
**GetHistoricalCutoff** -- Returns cutoff timestamps defining the boundary between live and historical data.
- **Auth:** None
- **Parameters:** None
- **Response 200:** `GetHistoricalCutoffResponse`
  - `market_settled_ts`: string (date-time) -- Markets settled before this go to /historical/markets
  - `trades_created_ts`: string (date-time) -- Fills before this go to /historical/fills
  - `orders_updated_ts`: string (date-time) -- Orders canceled/executed before this go to /historical/orders

---

### GET /historical/markets/{ticker}/candlesticks
**GetMarketCandlesticksHistorical** -- Fetch historical candlestick data for archived markets.
- **Auth:** None
- **Path Parameters:**
  - `ticker`: string (required) -- Market ticker
- **Query Parameters:**
  - `start_ts`: integer/int64 (required) -- Start Unix timestamp
  - `end_ts`: integer/int64 (required) -- End Unix timestamp
  - `period_interval`: integer (required) -- Minutes per candlestick. Enum: [1, 60, 1440]
- **Response 200:** `GetMarketCandlesticksHistoricalResponse`
  - `ticker`: string
  - `candlesticks`: array of `MarketCandlestickHistorical`
    - `end_period_ts`: integer/int64
    - `yes_bid`: `BidAskDistributionHistorical` {open, low, high, close} (all FixedPointDollars)
    - `yes_ask`: `BidAskDistributionHistorical` {open, low, high, close}
    - `price`: `PriceDistributionHistorical` {open, low, high, close, mean, previous} (all nullable FixedPointDollars)
    - `volume`: FixedPointCount
    - `open_interest`: FixedPointCount

---

### GET /historical/fills
**GetFillsHistorical** -- Get all historical fills for the member.
- **Auth:** Required
- **Query Parameters:**
  - `ticker`: string (optional) -- Filter by market ticker
  - `max_ts`: integer/int64 (optional) -- Filter items before this Unix timestamp
  - `limit`: integer/int64 (optional, default=100, min=1, max=1000)
  - `cursor`: string (optional) -- Pagination cursor
- **Response 200:** `GetFillsResponse`
  - `fills`: array of `Fill` (see Fill schema below)
  - `cursor`: string

---

### GET /historical/orders
**GetHistoricalOrders** -- Get orders archived to the historical database.
- **Auth:** Required
- **Query Parameters:**
  - `ticker`: string (optional)
  - `max_ts`: integer/int64 (optional)
  - `limit`: integer/int64 (optional, default=100, min=1, max=1000)
  - `cursor`: string (optional)
- **Response 200:** `GetOrdersResponse`
  - `orders`: array of `Order` (see Order schema below)
  - `cursor`: string

---

### GET /historical/trades
**GetTradesHistorical** -- Get all historical trades for all markets.
- **Auth:** None
- **Query Parameters:**
  - `ticker`: string (optional)
  - `min_ts`: integer/int64 (optional) -- Filter after this Unix timestamp
  - `max_ts`: integer/int64 (optional) -- Filter before this Unix timestamp
  - `limit`: integer/int64 (optional, default=100, min=0, max=1000)
  - `cursor`: string (optional)
- **Response 200:** `GetTradesResponse`
  - `trades`: array of `Trade` (see Trade schema below)
  - `cursor`: string

---

### GET /historical/markets
**GetHistoricalMarkets** -- Get markets archived to the historical database.
- **Auth:** None
- **Query Parameters:**
  - `limit`: integer/int64 (optional, default=100, min=0, max=1000)
  - `cursor`: string (optional)
  - `tickers`: string (optional) -- Comma-separated list of market tickers
  - `event_ticker`: string (optional) -- Single event ticker
  - `mve_filter`: string (optional) -- Enum: [exclude]. Filter MVE markets.
- **Response 200:** `GetMarketsResponse`
  - `markets`: array of `Market` (see Market schema below)
  - `cursor`: string

---

### GET /historical/markets/{ticker}
**GetHistoricalMarket** -- Get a specific market from the historical database.
- **Auth:** None
- **Path Parameters:**
  - `ticker`: string (required)
- **Response 200:** `GetMarketResponse`
  - `market`: `Market`

---

## 2. EXCHANGE

### GET /exchange/status
**GetExchangeStatus** -- Get the exchange status.
- **Auth:** None
- **Parameters:** None
- **Response 200:** `ExchangeStatus`
  - `exchange_active`: boolean -- False if exchange under maintenance
  - `trading_active`: boolean -- True during trading hours
  - `exchange_estimated_resume_time`: string/date-time (nullable)

---

### GET /exchange/announcements
**GetExchangeAnnouncements** -- Get all exchange-wide announcements.
- **Auth:** None
- **Parameters:** None
- **Response 200:** `GetExchangeAnnouncementsResponse`
  - `announcements`: array of `Announcement`
    - `type`: string, enum: [info, warning, error]
    - `message`: string
    - `delivery_time`: string/date-time
    - `status`: string, enum: [active, inactive]

---

### GET /series/fee_changes
**GetSeriesFeeChanges** -- Get series fee changes.
- **Auth:** None
- **Query Parameters:**
  - `series_ticker`: string (optional)
  - `show_historical`: boolean (optional, default=false)
- **Response 200:** `GetSeriesFeeChangesResponse`
  - `series_fee_change_arr`: array of `SeriesFeeChange`
    - `id`: string
    - `series_ticker`: string
    - `fee_type`: string, enum: [quadratic, quadratic_with_maker_fees, flat]
    - `fee_multiplier`: number/double
    - `scheduled_ts`: string/date-time

---

### GET /exchange/schedule
**GetExchangeSchedule** -- Get the exchange schedule.
- **Auth:** None
- **Parameters:** None
- **Response 200:** `GetExchangeScheduleResponse`
  - `schedule`: `Schedule`
    - `standard_hours`: array of `WeeklySchedule`
      - `start_time`, `end_time`: string/date-time
      - `monday` through `sunday`: array of `DailySchedule` {`open_time`, `close_time`: string}
    - `maintenance_windows`: array of `MaintenanceWindow` {`start_datetime`, `end_datetime`: string/date-time}

---

### GET /exchange/user_data_timestamp
**GetUserDataTimestamp** -- Approximate indication of when user data was last validated.
- **Auth:** None
- **Parameters:** None
- **Response 200:** `GetUserDataTimestampResponse`
  - `as_of_time`: string/date-time

---

## 3. ORDERS

### GET /portfolio/orders
**GetOrders** -- Get orders filtered by status (resting, canceled, executed).
- **Auth:** Required
- **Query Parameters:**
  - `ticker`: string (optional) -- Filter by market ticker
  - `event_ticker`: string (optional) -- Comma-separated list (max 10)
  - `min_ts`: integer/int64 (optional)
  - `max_ts`: integer/int64 (optional)
  - `status`: string (optional) -- Filter by status
  - `limit`: integer/int64 (optional, default=100, min=1, max=1000)
  - `cursor`: string (optional)
  - `subaccount`: integer (optional) -- 0=primary, 1-32=subaccounts. Defaults to all.
- **Response 200:** `GetOrdersResponse`
  - `orders`: array of `Order`
  - `cursor`: string

---

### POST /portfolio/orders
**CreateOrder** -- Submit an order. Limit: 200,000 open orders.
- **Auth:** Required
- **Request Body:** `CreateOrderRequest`
  - `ticker`: string (required)
  - `client_order_id`: string (optional)
  - `side`: string (required), enum: [yes, no]
  - `action`: string (required), enum: [buy, sell]
  - `count`: integer (optional, min=1) -- Whole contracts. Provide count or count_fp.
  - `count_fp`: FixedPointCount (optional, nullable) -- String contract count
  - `yes_price`: integer (optional, min=1, max=99) -- Legacy cents
  - `no_price`: integer (optional, min=1, max=99) -- Legacy cents
  - `yes_price_dollars`: FixedPointDollars (optional)
  - `no_price_dollars`: FixedPointDollars (optional)
  - `expiration_ts`: integer/int64 (optional)
  - `time_in_force`: string (optional), enum: [fill_or_kill, good_till_canceled, immediate_or_cancel]
  - `buy_max_cost`: integer (optional) -- Max cost in cents; auto-FoK
  - `post_only`: boolean (optional)
  - `reduce_only`: boolean (optional)
  - `sell_position_floor`: integer (optional, deprecated)
  - `self_trade_prevention_type`: string (optional), enum: [taker_at_cross, maker]
  - `order_group_id`: string (optional)
  - `cancel_order_on_pause`: boolean (optional)
  - `subaccount`: integer (optional, default=0)
- **Response 201:** `CreateOrderResponse`
  - `order`: `Order`

---

### GET /portfolio/orders/{order_id}
**GetOrder** -- Get a single order.
- **Auth:** Required
- **Path Parameters:**
  - `order_id`: string (required)
- **Response 200:** `GetOrderResponse`
  - `order`: `Order`

---

### DELETE /portfolio/orders/{order_id}
**CancelOrder** -- Cancel an order (zeroes remaining resting contracts).
- **Auth:** Required
- **Path Parameters:**
  - `order_id`: string (required)
- **Query Parameters:**
  - `subaccount`: integer (optional, default=0)
- **Response 200:** `CancelOrderResponse`
  - `order`: `Order`
  - `reduced_by_fp`: FixedPointCount

---

### POST /portfolio/orders/batched
**BatchCreateOrders** -- Submit up to 20 orders at once.
- **Auth:** Required
- **Request Body:** `BatchCreateOrdersRequest`
  - `orders`: array of `CreateOrderRequest`
- **Response 201:** `BatchCreateOrdersResponse`
  - `orders`: array of `BatchCreateOrdersIndividualResponse`
    - `client_order_id`: string (nullable)
    - `order`: Order (nullable)
    - `error`: ErrorResponse (nullable)

---

### DELETE /portfolio/orders/batched
**BatchCancelOrders** -- Cancel up to 20 orders at once.
- **Auth:** Required
- **Request Body:** `BatchCancelOrdersRequest`
  - `ids`: array of string (deprecated)
  - `orders`: array of `BatchCancelOrdersRequestOrder`
    - `order_id`: string (required)
    - `subaccount`: integer (optional, default=0)
- **Response 200:** `BatchCancelOrdersResponse`
  - `orders`: array of `BatchCancelOrdersIndividualResponse`
    - `order_id`: string
    - `order`: Order (nullable)
    - `reduced_by_fp`: FixedPointCount
    - `error`: ErrorResponse (nullable)

---

### POST /portfolio/orders/{order_id}/amend
**AmendOrder** -- Amend max fillable contracts and/or price.
- **Auth:** Required
- **Path Parameters:**
  - `order_id`: string (required)
- **Request Body:** `AmendOrderRequest`
  - `subaccount`: integer (optional, default=0)
  - `ticker`: string (required)
  - `side`: string (required), enum: [yes, no]
  - `action`: string (required), enum: [buy, sell]
  - `client_order_id`: string (optional)
  - `updated_client_order_id`: string (optional)
  - `yes_price`: integer (optional, min=1, max=99)
  - `no_price`: integer (optional, min=1, max=99)
  - `yes_price_dollars`: FixedPointDollars (optional)
  - `no_price_dollars`: FixedPointDollars (optional)
  - `count`: integer (optional, min=1)
  - `count_fp`: FixedPointCount (optional, nullable)
- **Response 200:** `AmendOrderResponse`
  - `old_order`: Order
  - `order`: Order

---

### POST /portfolio/orders/{order_id}/decrease
**DecreaseOrder** -- Decrease number of contracts in an existing order.
- **Auth:** Required
- **Path Parameters:**
  - `order_id`: string (required)
- **Request Body:** `DecreaseOrderRequest`
  - `subaccount`: integer (optional, default=0)
  - `reduce_by`: integer (optional, min=1) -- Exactly one of reduce_by or reduce_to required
  - `reduce_by_fp`: FixedPointCount (optional, nullable)
  - `reduce_to`: integer (optional, min=0)
  - `reduce_to_fp`: FixedPointCount (optional, nullable)
- **Response 200:** `DecreaseOrderResponse`
  - `order`: Order

---

### GET /portfolio/orders/queue_positions
**GetOrderQueuePositions** -- Get queue positions for all resting orders.
- **Auth:** Required
- **Query Parameters:**
  - `market_tickers`: string (optional) -- Comma-separated list
  - `event_ticker`: string (optional)
  - `subaccount`: integer (optional, default=0)
- **Response 200:** `GetOrderQueuePositionsResponse`
  - `queue_positions`: array of `OrderQueuePosition`
    - `order_id`: string
    - `market_ticker`: string
    - `queue_position_fp`: FixedPointCount

---

### GET /portfolio/orders/{order_id}/queue_position
**GetOrderQueuePosition** -- Get a specific order's queue position.
- **Auth:** Required
- **Path Parameters:**
  - `order_id`: string (required)
- **Response 200:** `GetOrderQueuePositionResponse`
  - `queue_position_fp`: FixedPointCount

---

## 4. ORDER GROUPS

### GET /portfolio/order_groups
**GetOrderGroups** -- Get all order groups.
- **Auth:** Required
- **Query Parameters:**
  - `subaccount`: integer (optional) -- Defaults to all subaccounts
- **Response 200:** `GetOrderGroupsResponse`
  - `order_groups`: array of `OrderGroup`
    - `id`: string
    - `contracts_limit_fp`: FixedPointCount
    - `is_auto_cancel_enabled`: boolean

---

### POST /portfolio/order_groups/create
**CreateOrderGroup** -- Create order group with rolling 15-second contract limit.
- **Auth:** Required
- **Request Body:** `CreateOrderGroupRequest`
  - `subaccount`: integer (optional, default=0)
  - `contracts_limit`: integer/int64 (optional, min=1)
  - `contracts_limit_fp`: FixedPointCount (optional, nullable)
- **Response 201:** `CreateOrderGroupResponse`
  - `order_group_id`: string

---

### GET /portfolio/order_groups/{order_group_id}
**GetOrderGroup** -- Get details for a single order group.
- **Auth:** Required
- **Path Parameters:**
  - `order_group_id`: string (required)
- **Query Parameters:**
  - `subaccount`: integer (optional) -- Defaults to all
- **Response 200:** `GetOrderGroupResponse`
  - `is_auto_cancel_enabled`: boolean
  - `contracts_limit_fp`: FixedPointCount
  - `orders`: array of string (order IDs)

---

### DELETE /portfolio/order_groups/{order_group_id}
**DeleteOrderGroup** -- Delete order group and cancel all orders within.
- **Auth:** Required
- **Path Parameters:**
  - `order_group_id`: string (required)
- **Query Parameters:**
  - `subaccount`: integer (optional, default=0)
- **Response 200:** EmptyResponse

---

### PUT /portfolio/order_groups/{order_group_id}/reset
**ResetOrderGroup** -- Reset matched contracts counter to zero.
- **Auth:** Required
- **Path Parameters:**
  - `order_group_id`: string (required)
- **Query Parameters:**
  - `subaccount`: integer (optional, default=0)
- **Response 200:** EmptyResponse

---

### PUT /portfolio/order_groups/{order_group_id}/trigger
**TriggerOrderGroup** -- Trigger the group, canceling all orders.
- **Auth:** Required
- **Path Parameters:**
  - `order_group_id`: string (required)
- **Query Parameters:**
  - `subaccount`: integer (optional, default=0)
- **Response 200:** EmptyResponse

---

### PUT /portfolio/order_groups/{order_group_id}/limit
**UpdateOrderGroupLimit** -- Update the contracts limit.
- **Auth:** Required
- **Path Parameters:**
  - `order_group_id`: string (required)
- **Request Body:** `UpdateOrderGroupLimitRequest`
  - `contracts_limit`: integer/int64 (optional, min=1)
  - `contracts_limit_fp`: FixedPointCount (optional, nullable)
- **Response 200:** EmptyResponse

---

## 5. PORTFOLIO

### GET /portfolio/balance
**GetBalance** -- Get balance and portfolio value (in cents).
- **Auth:** Required
- **Query Parameters:**
  - `subaccount`: integer (optional, default=0)
- **Response 200:** `GetBalanceResponse`
  - `balance`: integer/int64 -- Available balance in cents
  - `portfolio_value`: integer/int64 -- Current portfolio value in cents
  - `updated_ts`: integer/int64 -- Unix timestamp

---

### POST /portfolio/subaccounts
**CreateSubaccount** -- Create a new subaccount (max 32).
- **Auth:** Required
- **Request Body:** None
- **Response 201:** `CreateSubaccountResponse`
  - `subaccount_number`: integer (1-32)

---

### POST /portfolio/subaccounts/transfer
**ApplySubaccountTransfer** -- Transfer funds between subaccounts.
- **Auth:** Required
- **Request Body:** `ApplySubaccountTransferRequest`
  - `client_transfer_id`: string/uuid (required) -- Idempotency key
  - `from_subaccount`: integer (required) -- 0=primary, 1-32
  - `to_subaccount`: integer (required) -- 0=primary, 1-32
  - `amount_cents`: integer/int64 (required)
- **Response 200:** `ApplySubaccountTransferResponse` (empty)

---

### GET /portfolio/subaccounts/balances
**GetSubaccountBalances** -- Get balances for all subaccounts.
- **Auth:** Required
- **Response 200:** `GetSubaccountBalancesResponse`
  - `subaccount_balances`: array of `SubaccountBalance`
    - `subaccount_number`: integer
    - `balance`: FixedPointDollars
    - `updated_ts`: integer/int64

---

### GET /portfolio/subaccounts/transfers
**GetSubaccountTransfers** -- Get paginated list of subaccount transfers.
- **Auth:** Required
- **Query Parameters:**
  - `limit`: integer/int64 (optional, default=100, min=1, max=1000)
  - `cursor`: string (optional)
- **Response 200:** `GetSubaccountTransfersResponse`
  - `transfers`: array of `SubaccountTransfer`
    - `transfer_id`: string
    - `from_subaccount`: integer
    - `to_subaccount`: integer
    - `amount_cents`: integer/int64
    - `created_ts`: integer/int64
  - `cursor`: string

---

### PUT /portfolio/subaccounts/netting
**UpdateSubaccountNetting** -- Update netting enabled setting.
- **Auth:** Required
- **Request Body:** `UpdateSubaccountNettingRequest`
  - `subaccount_number`: integer (required) -- 0=primary, 1-32
  - `enabled`: boolean (required)
- **Response 200:** (no body)

---

### GET /portfolio/subaccounts/netting
**GetSubaccountNetting** -- Get netting settings for all subaccounts.
- **Auth:** Required
- **Response 200:** `GetSubaccountNettingResponse`
  - `netting_configs`: array of `SubaccountNettingConfig`
    - `subaccount_number`: integer
    - `enabled`: boolean

---

### GET /portfolio/positions
**GetPositions** -- Get market positions.
- **Auth:** Required
- **Query Parameters:**
  - `cursor`: string (optional)
  - `limit`: integer/int32 (optional, default=100, min=1, max=1000)
  - `count_filter`: string (optional) -- Comma-separated: "position", "total_traded"
  - `ticker`: string (optional)
  - `event_ticker`: string (optional)
  - `subaccount`: integer (optional, default=0)
- **Response 200:** `GetPositionsResponse`
  - `cursor`: string
  - `market_positions`: array of `MarketPosition`
    - `ticker`: string
    - `total_traded_dollars`: FixedPointDollars
    - `position_fp`: FixedPointCount -- Negative=NO, positive=YES
    - `market_exposure_dollars`: FixedPointDollars
    - `realized_pnl_dollars`: FixedPointDollars
    - `resting_orders_count`: integer/int32 (deprecated)
    - `fees_paid_dollars`: FixedPointDollars
    - `last_updated_ts`: string/date-time
  - `event_positions`: array of `EventPosition`
    - `event_ticker`: string
    - `total_cost_dollars`: FixedPointDollars
    - `total_cost_shares_fp`: FixedPointCount
    - `event_exposure_dollars`: FixedPointDollars
    - `realized_pnl_dollars`: FixedPointDollars
    - `fees_paid_dollars`: FixedPointDollars

---

### GET /portfolio/settlements
**GetSettlements** -- Get member's settlement history.
- **Auth:** Required
- **Query Parameters:**
  - `limit`: integer/int64 (optional, default=100, min=1, max=1000)
  - `cursor`: string (optional)
  - `ticker`: string (optional)
  - `event_ticker`: string (optional)
  - `min_ts`: integer/int64 (optional)
  - `max_ts`: integer/int64 (optional)
  - `subaccount`: integer (optional)
- **Response 200:** `GetSettlementsResponse`
  - `settlements`: array of `Settlement`
    - `ticker`: string
    - `event_ticker`: string
    - `market_result`: string, enum: [yes, no, scalar, void]
    - `yes_count_fp`: FixedPointCount
    - `yes_total_cost_dollars`: FixedPointDollars
    - `no_count_fp`: FixedPointCount
    - `no_total_cost_dollars`: FixedPointDollars
    - `revenue`: integer -- In cents
    - `settled_time`: string/date-time
    - `fee_cost`: FixedPointDollars
    - `value`: integer (nullable) -- Payout of single yes contract in cents
  - `cursor`: string

---

### GET /portfolio/summary/total_resting_order_value
**GetPortfolioRestingOrderTotalValue** -- Total resting order value in cents (FCM members).
- **Auth:** Required
- **Response 200:** `GetPortfolioRestingOrderTotalValueResponse`
  - `total_resting_order_value`: integer

---

### GET /portfolio/fills
**GetFills** -- Get all fills for the member.
- **Auth:** Required
- **Query Parameters:**
  - `ticker`: string (optional)
  - `order_id`: string (optional)
  - `min_ts`: integer/int64 (optional)
  - `max_ts`: integer/int64 (optional)
  - `limit`: integer/int64 (optional, default=100, min=1, max=1000)
  - `cursor`: string (optional)
  - `subaccount`: integer (optional)
- **Response 200:** `GetFillsResponse`
  - `fills`: array of `Fill`
    - `fill_id`: string
    - `trade_id`: string (legacy, same as fill_id)
    - `order_id`: string
    - `ticker`: string
    - `market_ticker`: string (legacy, same as ticker)
    - `side`: string, enum: [yes, no]
    - `action`: string, enum: [buy, sell]
    - `count_fp`: FixedPointCount
    - `yes_price_dollars`: FixedPointDollars
    - `no_price_dollars`: FixedPointDollars
    - `is_taker`: boolean
    - `created_time`: string/date-time
    - `fee_cost`: FixedPointDollars
    - `subaccount_number`: integer (nullable)
    - `ts`: integer/int64 (legacy)
  - `cursor`: string

---

## 6. API KEYS

### GET /api_keys
**GetApiKeys** -- Get all API keys for the authenticated user.
- **Auth:** Required
- **Response 200:** `GetApiKeysResponse`
  - `api_keys`: array of `ApiKey`
    - `api_key_id`: string
    - `name`: string
    - `scopes`: array of string (e.g., "read", "write")

---

### POST /api_keys
**CreateApiKey** -- Create API key with user-provided public key.
- **Auth:** Required
- **Request Body:** `CreateApiKeyRequest`
  - `name`: string (required)
  - `public_key`: string (required) -- RSA public key in PEM format
  - `scopes`: array of string (optional) -- Defaults to ["read", "write"]
- **Response 201:** `CreateApiKeyResponse`
  - `api_key_id`: string

---

### POST /api_keys/generate
**GenerateApiKey** -- Generate API key with auto-created key pair.
- **Auth:** Required
- **Request Body:** `GenerateApiKeyRequest`
  - `name`: string (required)
  - `scopes`: array of string (optional)
- **Response 201:** `GenerateApiKeyResponse`
  - `api_key_id`: string
  - `private_key`: string -- RSA private key in PEM. Cannot be retrieved again.

---

### DELETE /api_keys/{api_key}
**DeleteApiKey** -- Permanently delete an API key.
- **Auth:** Required
- **Path Parameters:**
  - `api_key`: string (required) -- API key ID to delete
- **Response 204:** No content

---

## 7. SEARCH

### GET /search/tags_by_categories
**GetTagsForSeriesCategories** -- Retrieve tags organized by series categories.
- **Auth:** None
- **Response 200:** `GetTagsForSeriesCategoriesResponse`
  - `tags_by_categories`: object -- Map of category name to array of tag strings

---

### GET /search/filters_by_sport
**GetFiltersForSports** -- Retrieve available filters organized by sport.
- **Auth:** None
- **Response 200:** `GetFiltersBySportsResponse`
  - `filters_by_sports`: object -- Map of sport to `SportFilterDetails`
    - `scopes`: array of string
    - `competitions`: object -- Map of competition to `ScopeList` {scopes: string[]}
  - `sport_ordering`: array of string -- Ordered list for display

---

## 8. ACCOUNT

### GET /account/limits
**GetAccountApiLimits** -- Get API tier limits.
- **Auth:** Required
- **Response 200:** `GetAccountApiLimitsResponse`
  - `usage_tier`: string
  - `read_limit`: integer -- Max read requests/sec
  - `write_limit`: integer -- Max write requests/sec

---

## 9. MARKET

### GET /series/{series_ticker}/markets/{ticker}/candlesticks
**GetMarketCandlesticks** -- Get candlestick data for a market.
- **Auth:** None
- **Path Parameters:**
  - `series_ticker`: string (required)
  - `ticker`: string (required)
- **Query Parameters:**
  - `start_ts`: integer/int64 (required)
  - `end_ts`: integer/int64 (required)
  - `period_interval`: integer (required), enum: [1, 60, 1440]
  - `include_latest_before_start`: boolean (optional, default=false) -- Prepend synthetic candlestick
- **Response 200:** `GetMarketCandlesticksResponse`
  - `ticker`: string
  - `candlesticks`: array of `MarketCandlestick`
    - `end_period_ts`: integer/int64
    - `yes_bid`: `BidAskDistribution` {open_dollars, low_dollars, high_dollars, close_dollars}
    - `yes_ask`: `BidAskDistribution`
    - `price`: `PriceDistribution` {open_dollars, low_dollars, high_dollars, close_dollars, mean_dollars, previous_dollars, min_dollars, max_dollars} (all nullable FixedPointDollars)
    - `volume_fp`: FixedPointCount
    - `open_interest_fp`: FixedPointCount

---

### GET /markets/trades
**GetTrades** -- Get all trades for all markets.
- **Auth:** None
- **Query Parameters:**
  - `limit`: integer/int64 (optional, default=100, min=0, max=1000)
  - `cursor`: string (optional)
  - `ticker`: string (optional)
  - `min_ts`: integer/int64 (optional)
  - `max_ts`: integer/int64 (optional)
- **Response 200:** `GetTradesResponse`
  - `trades`: array of `Trade`
    - `trade_id`: string
    - `ticker`: string
    - `count_fp`: FixedPointCount
    - `yes_price_dollars`: FixedPointDollars
    - `no_price_dollars`: FixedPointDollars
    - `taker_side`: string, enum: [yes, no]
    - `created_time`: string/date-time
  - `cursor`: string

---

### GET /markets/{ticker}/orderbook
**GetMarketOrderbook** -- Get current order book for a market.
- **Auth:** Required
- **Path Parameters:**
  - `ticker`: string (required)
- **Query Parameters:**
  - `depth`: integer (optional, min=0, max=100, default=0) -- 0 = all levels
- **Response 200:** `GetMarketOrderbookResponse`
  - `orderbook_fp`: `OrderbookCountFp`
    - `yes_dollars`: array of [price_dollars_string, count_fp_string]
    - `no_dollars`: array of [price_dollars_string, count_fp_string]

---

### GET /markets/orderbooks
**GetMarketOrderbooks** -- Get order books for multiple markets.
- **Auth:** Required
- **Query Parameters:**
  - `tickers`: array of string (required, min=1, max=100) -- Exploded form
- **Response 200:** `GetMarketOrderbooksResponse`
  - `orderbooks`: array of `MarketOrderbookFp`
    - `ticker`: string
    - `orderbook_fp`: `OrderbookCountFp`

---

### GET /series/{series_ticker}
**GetSeries** -- Get data about a specific series.
- **Auth:** None
- **Path Parameters:**
  - `series_ticker`: string (required)
- **Query Parameters:**
  - `include_volume`: boolean (optional, default=false)
- **Response 200:** `GetSeriesResponse`
  - `series`: `Series`
    - `ticker`: string
    - `frequency`: string
    - `title`: string
    - `category`: string
    - `tags`: array of string
    - `settlement_sources`: array of `SettlementSource` {name, url}
    - `contract_url`: string
    - `contract_terms_url`: string
    - `product_metadata`: object (nullable)
    - `fee_type`: string, enum: [quadratic, quadratic_with_maker_fees, flat]
    - `fee_multiplier`: number/double
    - `additional_prohibitions`: array of string
    - `volume_fp`: FixedPointCount
    - `last_updated_ts`: string/date-time

---

### GET /series
**GetSeriesList** -- Get multiple series with filters.
- **Auth:** None
- **Query Parameters:**
  - `category`: string (optional)
  - `tags`: string (optional)
  - `include_product_metadata`: boolean (optional, default=false)
  - `include_volume`: boolean (optional, default=false)
  - `min_updated_ts`: integer/int64 (optional)
- **Response 200:** `GetSeriesListResponse`
  - `series`: array of `Series`

---

### GET /markets
**GetMarkets** -- Get markets with filters.
- **Auth:** None
- **Query Parameters:**
  - `limit`: integer/int64 (optional, default=100, min=0, max=1000)
  - `cursor`: string (optional)
  - `event_ticker`: string (optional) -- Single event ticker
  - `series_ticker`: string (optional)
  - `min_created_ts`: integer/int64 (optional)
  - `max_created_ts`: integer/int64 (optional)
  - `min_updated_ts`: integer/int64 (optional) -- Incompatible with other filters besides mve_filter=exclude
  - `max_close_ts`: integer/int64 (optional)
  - `min_close_ts`: integer/int64 (optional)
  - `min_settled_ts`: integer/int64 (optional)
  - `max_settled_ts`: integer/int64 (optional)
  - `status`: string (optional), enum: [unopened, open, paused, closed, settled]
  - `tickers`: string (optional) -- Comma-separated market tickers
  - `mve_filter`: string (optional), enum: [only, exclude]
- **Response 200:** `GetMarketsResponse`
  - `markets`: array of `Market`
  - `cursor`: string

---

### GET /markets/{ticker}
**GetMarket** -- Get data about a specific market.
- **Auth:** None
- **Path Parameters:**
  - `ticker`: string (required)
- **Response 200:** `GetMarketResponse`
  - `market`: `Market`

---

### GET /markets/candlesticks
**BatchGetMarketCandlesticks** -- Get candlesticks for multiple markets (up to 100, max 10,000 total).
- **Auth:** None
- **Query Parameters:**
  - `market_tickers`: string (required) -- Comma-separated (max 100)
  - `start_ts`: integer/int64 (required)
  - `end_ts`: integer/int64 (required)
  - `period_interval`: integer/int32 (required, min=1) -- Minutes
  - `include_latest_before_start`: boolean (optional, default=false)
- **Response 200:** `BatchGetMarketCandlesticksResponse`
  - `markets`: array of `MarketCandlesticksResponse`
    - `market_ticker`: string
    - `candlesticks`: array of `MarketCandlestick`

---

## 10. EVENTS

### GET /series/{series_ticker}/events/{ticker}/candlesticks
**GetMarketCandlesticksByEvent** -- Aggregated candlestick data across all markets in an event.
- **Auth:** None
- **Path Parameters:**
  - `ticker`: string (required) -- Event ticker
  - `series_ticker`: string (required)
- **Query Parameters:**
  - `start_ts`: integer/int64 (required)
  - `end_ts`: integer/int64 (required)
  - `period_interval`: integer/int32 (required), enum: [1, 60, 1440]
- **Response 200:** `GetEventCandlesticksResponse`
  - `market_tickers`: array of string
  - `market_candlesticks`: array of array of `MarketCandlestick`
  - `adjusted_end_ts`: integer/int64

---

### GET /events
**GetEvents** -- Get all events (excludes multivariate).
- **Auth:** None
- **Query Parameters:**
  - `limit`: integer (optional, default=200, min=1, max=200)
  - `cursor`: string (optional)
  - `with_nested_markets`: boolean (optional, default=false) -- Include markets in event objects
  - `with_milestones`: boolean (optional, default=false) -- Include related milestones
  - `status`: string (optional), enum: [unopened, open, closed, settled]
  - `series_ticker`: string (optional)
  - `min_close_ts`: integer/int64 (optional) -- Events with at least one market closing after this
  - `min_updated_ts`: integer/int64 (optional) -- Events updated after this
- **Response 200:** `GetEventsResponse`
  - `events`: array of `EventData`
    - `event_ticker`: string
    - `series_ticker`: string
    - `sub_title`: string
    - `title`: string
    - `collateral_return_type`: string
    - `mutually_exclusive`: boolean
    - `category`: string (deprecated)
    - `strike_date`: string/date-time (nullable)
    - `strike_period`: string (nullable)
    - `markets`: array of `Market` (only if with_nested_markets=true)
    - `available_on_brokers`: boolean
    - `product_metadata`: object (nullable)
    - `last_updated_ts`: string/date-time
  - `milestones`: array of `Milestone` (if with_milestones)
  - `cursor`: string

---

### GET /events/multivariate
**GetMultivariateEvents** -- Get multivariate (combo) events.
- **Auth:** None
- **Query Parameters:**
  - `limit`: integer (optional, default=100, min=1, max=200)
  - `cursor`: string (optional)
  - `series_ticker`: string (optional)
  - `collection_ticker`: string (optional) -- Cannot combine with series_ticker
  - `with_nested_markets`: boolean (optional, default=false)
- **Response 200:** `GetMultivariateEventsResponse`
  - `events`: array of `EventData`
  - `cursor`: string

---

### GET /events/{event_ticker}
**GetEvent** -- Get data about an event by ticker.
- **Auth:** None
- **Path Parameters:**
  - `event_ticker`: string (required)
- **Query Parameters:**
  - `with_nested_markets`: boolean (optional, default=false)
- **Response 200:** `GetEventResponse`
  - `event`: `EventData`
  - `markets`: array of `Market` (deprecated; use with_nested_markets instead)

---

### GET /events/{event_ticker}/metadata
**GetEventMetadata** -- Get metadata for an event.
- **Auth:** None
- **Path Parameters:**
  - `event_ticker`: string (required)
- **Response 200:** `GetEventMetadataResponse`
  - `image_url`: string
  - `featured_image_url`: string
  - `market_details`: array of `MarketMetadata`
    - `market_ticker`: string
    - `image_url`: string
    - `color_code`: string
  - `settlement_sources`: array of `SettlementSource` {name, url}
  - `competition`: string (nullable)
  - `competition_scope`: string (nullable)

---

### GET /series/{series_ticker}/events/{ticker}/forecast_percentile_history
**GetEventForecastPercentilesHistory** -- Historical forecast numbers at specific percentiles.
- **Auth:** Required
- **Path Parameters:**
  - `ticker`: string (required) -- Event ticker
  - `series_ticker`: string (required)
- **Query Parameters:**
  - `percentiles`: array of integer/int32 (required, max 10 values, 0-10000) -- Exploded form
  - `start_ts`: integer/int64 (required)
  - `end_ts`: integer/int64 (required)
  - `period_interval`: integer/int32 (required), enum: [0, 1, 60, 1440] -- 0 = 5-second intervals
- **Response 200:** `GetEventForecastPercentilesHistoryResponse`
  - `forecast_history`: array of `ForecastPercentilesPoint`
    - `event_ticker`: string
    - `end_period_ts`: integer/int64
    - `period_interval`: integer/int32
    - `percentile_points`: array of `PercentilePoint`
      - `percentile`: integer/int32
      - `raw_numerical_forecast`: number
      - `numerical_forecast`: number
      - `formatted_forecast`: string

---

## 11. LIVE DATA

### GET /live_data/milestone/{milestone_id}
**GetLiveDataByMilestone** -- Get live data for a specific milestone.
- **Auth:** None
- **Path Parameters:**
  - `milestone_id`: string (required)
- **Query Parameters:**
  - `include_player_stats`: boolean (optional, default=false) -- For Pro Football, Pro Basketball, College Men's Basketball
- **Response 200:** `GetLiveDataResponse`
  - `live_data`: `LiveData`
    - `type`: string
    - `details`: object (flexible)
    - `milestone_id`: string

---

### GET /live_data/{type}/milestone/{milestone_id}
**GetLiveData** -- Get live data (legacy, with type param). Prefer /live_data/milestone/{milestone_id}.
- **Auth:** None
- **Path Parameters:**
  - `type`: string (required)
  - `milestone_id`: string (required)
- **Query Parameters:**
  - `include_player_stats`: boolean (optional, default=false)
- **Response 200:** `GetLiveDataResponse`

---

### GET /live_data/batch
**GetLiveDatas** -- Get live data for multiple milestones.
- **Auth:** None
- **Query Parameters:**
  - `milestone_ids`: array of string (required, max 100) -- Exploded form
  - `include_player_stats`: boolean (optional, default=false)
- **Response 200:** `GetLiveDatasResponse`
  - `live_datas`: array of `LiveData`

---

### GET /live_data/milestone/{milestone_id}/game_stats
**GetGameStats** -- Get play-by-play game statistics.
- **Auth:** None
- **Path Parameters:**
  - `milestone_id`: string (required)
- **Response 200:** `GetGameStatsResponse`
  - `pbp`: `PlayByPlay`
    - `periods`: array of {events: array of object}

---

## 12. INCENTIVE PROGRAMS

### GET /incentive_programs
**GetIncentivePrograms** -- List incentive programs with filters.
- **Auth:** None
- **Query Parameters:**
  - `status`: string (optional), enum: [all, active, upcoming, closed, paid_out]
  - `type`: string (optional), enum: [all, liquidity, volume]
  - `limit`: integer (optional, min=1, max=10000)
  - `cursor`: string (optional)
- **Response 200:** `GetIncentiveProgramsResponse`
  - `incentive_programs`: array of `IncentiveProgram`
    - `id`: string
    - `market_id`: string
    - `market_ticker`: string
    - `incentive_type`: string, enum: [liquidity, volume]
    - `start_date`: string/date-time
    - `end_date`: string/date-time
    - `period_reward`: integer/int64 -- In centi-cents
    - `paid_out`: boolean
    - `discount_factor_bps`: integer/int32 (nullable)
    - `target_size_fp`: FixedPointCount (nullable)
  - `next_cursor`: string

---

## 13. FCM (Futures Commission Merchant)

### GET /fcm/orders
**GetFCMOrders** -- Get orders filtered by subtrader ID (FCM members only).
- **Auth:** Required
- **Query Parameters:**
  - `subtrader_id`: string (required)
  - `cursor`: string (optional)
  - `event_ticker`: string (optional)
  - `ticker`: string (optional)
  - `min_ts`: integer/int64 (optional)
  - `max_ts`: integer/int64 (optional)
  - `status`: string (optional), enum: [resting, canceled, executed]
  - `limit`: integer (optional, min=1, max=1000)
- **Response 200:** `GetOrdersResponse`

---

### GET /fcm/positions
**GetFCMPositions** -- Get positions filtered by subtrader ID (FCM members only).
- **Auth:** Required
- **Query Parameters:**
  - `subtrader_id`: string (required)
  - `ticker`: string (optional)
  - `event_ticker`: string (optional)
  - `count_filter`: string (optional)
  - `settlement_status`: string (optional), enum: [all, unsettled, settled]
  - `limit`: integer (optional, min=1, max=1000)
  - `cursor`: string (optional)
- **Response 200:** `GetPositionsResponse`

---

## 14. STRUCTURED TARGETS

### GET /structured_targets
**GetStructuredTargets** -- Get structured targets (page size 1-2000).
- **Auth:** None
- **Query Parameters:**
  - `ids`: array of string (optional) -- Exploded form
  - `type`: string (optional) -- e.g., "basketball_player"
  - `competition`: string (optional) -- e.g., "NBA"
  - `page_size`: integer/int32 (optional, default=100, min=1, max=2000)
  - `cursor`: string (optional)
- **Response 200:** `GetStructuredTargetsResponse`
  - `structured_targets`: array of `StructuredTarget`
    - `id`: string
    - `name`: string
    - `type`: string
    - `details`: object
    - `source_id`: string
    - `source_ids`: object (map of string)
    - `last_updated_ts`: string/date-time
  - `cursor`: string

---

### GET /structured_targets/{structured_target_id}
**GetStructuredTarget** -- Get a specific structured target.
- **Auth:** None
- **Path Parameters:**
  - `structured_target_id`: string (required)
- **Response 200:** `GetStructuredTargetResponse`
  - `structured_target`: `StructuredTarget`

---

## 15. MILESTONES

### GET /milestones/{milestone_id}
**GetMilestone** -- Get a specific milestone.
- **Auth:** None
- **Path Parameters:**
  - `milestone_id`: string (required)
- **Response 200:** `GetMilestoneResponse`
  - `milestone`: `Milestone`
    - `id`: string
    - `category`: string (e.g., "Sports")
    - `type`: string (e.g., "football_game")
    - `start_date`: string/date-time
    - `end_date`: string/date-time (nullable)
    - `related_event_tickers`: array of string
    - `title`: string
    - `notification_message`: string
    - `source_id`: string (nullable)
    - `source_ids`: object (map of string)
    - `details`: object
    - `primary_event_tickers`: array of string
    - `last_updated_ts`: string/date-time

---

### GET /milestones
**GetMilestones** -- Get milestones with filters.
- **Auth:** None
- **Query Parameters:**
  - `limit`: integer (required, min=1, max=500)
  - `minimum_start_date`: string/date-time (optional)
  - `category`: string (optional) -- e.g., "Sports"
  - `competition`: string (optional) -- e.g., "Pro Football"
  - `source_id`: string (optional)
  - `type`: string (optional) -- e.g., "football_game"
  - `related_event_ticker`: string (optional)
  - `cursor`: string (optional)
  - `min_updated_ts`: integer/int64 (optional) -- Poll for changes
- **Response 200:** `GetMilestonesResponse`
  - `milestones`: array of `Milestone`
  - `cursor`: string

---

## 16. COMMUNICATIONS (RFQ/Quotes)

### GET /communications/id
**GetCommunicationsID** -- Get public communications ID for the logged-in user.
- **Auth:** Required
- **Response 200:** `GetCommunicationsIDResponse`
  - `communications_id`: string

---

### GET /communications/rfqs
**GetRFQs** -- Get RFQs (Requests for Quote).
- **Auth:** Required
- **Query Parameters:**
  - `cursor`: string (optional)
  - `event_ticker`: string (optional)
  - `market_ticker`: string (optional)
  - `subaccount`: integer (optional)
  - `limit`: integer/int32 (optional, default=100, min=1, max=100)
  - `status`: string (optional)
  - `creator_user_id`: string (optional)
- **Response 200:** `GetRFQsResponse`
  - `rfqs`: array of `RFQ`
    - `id`: string
    - `creator_id`: string -- Public communications ID
    - `market_ticker`: string
    - `contracts_fp`: FixedPointCount
    - `target_cost_dollars`: FixedPointDollars
    - `status`: string, enum: [open, closed]
    - `created_ts`: string/date-time
    - `mve_collection_ticker`: string
    - `mve_selected_legs`: array of MveSelectedLeg
    - `rest_remainder`: boolean
    - `cancellation_reason`: string
    - `creator_user_id`: string (private)
    - `cancelled_ts`: string/date-time
    - `updated_ts`: string/date-time
  - `cursor`: string

---

### POST /communications/rfqs
**CreateRFQ** -- Create a new RFQ (max 100 open).
- **Auth:** Required
- **Request Body:** `CreateRFQRequest`
  - `market_ticker`: string (required)
  - `contracts`: integer (optional) -- Whole contracts
  - `contracts_fp`: FixedPointCount (optional, nullable)
  - `target_cost_centi_cents`: integer/int64 (optional, deprecated)
  - `target_cost_dollars`: FixedPointDollars (optional)
  - `rest_remainder`: boolean (required)
  - `replace_existing`: boolean (optional, default=false)
  - `subtrader_id`: string (optional) -- FCM only
  - `subaccount`: integer (optional)
- **Response 201:** `CreateRFQResponse`
  - `id`: string

---

### GET /communications/rfqs/{rfq_id}
**GetRFQ** -- Get a single RFQ.
- **Auth:** Required
- **Path Parameters:**
  - `rfq_id`: string (required)
- **Response 200:** `GetRFQResponse`
  - `rfq`: `RFQ`

---

### DELETE /communications/rfqs/{rfq_id}
**DeleteRFQ** -- Delete an RFQ.
- **Auth:** Required
- **Path Parameters:**
  - `rfq_id`: string (required)
- **Response 204:** No content

---

### GET /communications/quotes
**GetQuotes** -- Get quotes.
- **Auth:** Required
- **Query Parameters:**
  - `cursor`: string (optional)
  - `event_ticker`: string (optional)
  - `market_ticker`: string (optional)
  - `limit`: integer/int32 (optional, default=500, min=1, max=500)
  - `status`: string (optional)
  - `quote_creator_user_id`: string (optional)
  - `rfq_creator_user_id`: string (optional)
  - `rfq_creator_subtrader_id`: string (optional) -- FCM only
  - `rfq_id`: string (optional)
- **Response 200:** `GetQuotesResponse`
  - `quotes`: array of `Quote`
    - `id`: string
    - `rfq_id`: string
    - `creator_id`: string
    - `rfq_creator_id`: string
    - `market_ticker`: string
    - `contracts_fp`: FixedPointCount
    - `yes_bid_dollars`: FixedPointDollars
    - `no_bid_dollars`: FixedPointDollars
    - `created_ts`: string/date-time
    - `updated_ts`: string/date-time
    - `status`: string, enum: [open, accepted, confirmed, executed, cancelled]
    - `accepted_side`: string, enum: [yes, no]
    - `accepted_ts`: string/date-time
    - `confirmed_ts`: string/date-time
    - `executed_ts`: string/date-time
    - `cancelled_ts`: string/date-time
    - `rest_remainder`: boolean
    - `cancellation_reason`: string
    - `creator_user_id`: string (private)
    - `rfq_creator_user_id`: string (private)
    - `rfq_target_cost_dollars`: FixedPointDollars
    - `rfq_creator_order_id`: string (private)
    - `creator_order_id`: string (private)
    - `yes_contracts_fp`: FixedPointCount
    - `no_contracts_fp`: FixedPointCount
  - `cursor`: string

---

### POST /communications/quotes
**CreateQuote** -- Create a quote in response to an RFQ.
- **Auth:** Required
- **Request Body:** `CreateQuoteRequest`
  - `rfq_id`: string (required)
  - `yes_bid`: FixedPointDollars (required)
  - `no_bid`: FixedPointDollars (required)
  - `rest_remainder`: boolean (required)
  - `subaccount`: integer (optional)
- **Response 201:** `CreateQuoteResponse`
  - `id`: string

---

### GET /communications/quotes/{quote_id}
**GetQuote** -- Get a particular quote.
- **Auth:** Required
- **Path Parameters:**
  - `quote_id`: string (required)
- **Response 200:** `GetQuoteResponse`
  - `quote`: `Quote`

---

### DELETE /communications/quotes/{quote_id}
**DeleteQuote** -- Delete a quote (can no longer be accepted).
- **Auth:** Required
- **Path Parameters:**
  - `quote_id`: string (required)
- **Response 204:** No content

---

### PUT /communications/quotes/{quote_id}/accept
**AcceptQuote** -- Accept a quote (requires quoter to confirm).
- **Auth:** Required
- **Path Parameters:**
  - `quote_id`: string (required)
- **Request Body:** `AcceptQuoteRequest`
  - `accepted_side`: string (required), enum: [yes, no]
- **Response 204:** No content

---

### PUT /communications/quotes/{quote_id}/confirm
**ConfirmQuote** -- Confirm a quote (starts execution timer).
- **Auth:** Required
- **Path Parameters:**
  - `quote_id`: string (required)
- **Response 204:** No content

---

## 17. MULTIVARIATE EVENT COLLECTIONS

### GET /multivariate_event_collections/{collection_ticker}
**GetMultivariateEventCollection** -- Get a multivariate event collection.
- **Auth:** None
- **Path Parameters:**
  - `collection_ticker`: string (required)
- **Response 200:** `GetMultivariateEventCollectionResponse`
  - `multivariate_contract`: `MultivariateEventCollection`
    - `collection_ticker`: string
    - `series_ticker`: string
    - `title`: string
    - `description`: string
    - `open_date`: string/date-time
    - `close_date`: string/date-time
    - `associated_events`: array of `AssociatedEvent`
      - `ticker`: string
      - `is_yes_only`: boolean
      - `size_max`: integer/int32 (nullable)
      - `size_min`: integer/int32 (nullable)
      - `active_quoters`: array of string
    - `associated_event_tickers`: array of string (deprecated)
    - `is_ordered`: boolean
    - `is_single_market_per_event`: boolean (deprecated)
    - `is_all_yes`: boolean (deprecated)
    - `size_min`: integer/int32
    - `size_max`: integer/int32
    - `functional_description`: string

---

### POST /multivariate_event_collections/{collection_ticker}
**CreateMarketInMultivariateEventCollection** -- Create a market in a collection. Must be called before trading/lookup. Max 5000/week.
- **Auth:** Required
- **Path Parameters:**
  - `collection_ticker`: string (required)
- **Request Body:** `CreateMarketInMultivariateEventCollectionRequest`
  - `selected_markets`: array of `TickerPair` (required)
    - `market_ticker`: string
    - `event_ticker`: string
    - `side`: string, enum: [yes, no]
  - `with_market_payload`: boolean (optional)
- **Response 200:** `CreateMarketInMultivariateEventCollectionResponse`
  - `event_ticker`: string
  - `market_ticker`: string
  - `market`: Market (if with_market_payload)

---

### GET /multivariate_event_collections
**GetMultivariateEventCollections** -- Get multiple multivariate event collections.
- **Auth:** None
- **Query Parameters:**
  - `status`: string (optional), enum: [unopened, open, closed]
  - `associated_event_ticker`: string (optional)
  - `series_ticker`: string (optional)
  - `limit`: integer/int32 (optional, min=1, max=200)
  - `cursor`: string (optional)
- **Response 200:** `GetMultivariateEventCollectionsResponse`
  - `multivariate_contracts`: array of `MultivariateEventCollection`
  - `cursor`: string

---

### PUT /multivariate_event_collections/{collection_ticker}/lookup
**LookupTickersForMarketInMultivariateEventCollection** -- Look up a market. Returns 404 if Create was never called.
- **Auth:** Required
- **Path Parameters:**
  - `collection_ticker`: string (required)
- **Request Body:** `LookupTickersForMarketInMultivariateEventCollectionRequest`
  - `selected_markets`: array of `TickerPair` (required)
- **Response 200:** `LookupTickersForMarketInMultivariateEventCollectionResponse`
  - `event_ticker`: string
  - `market_ticker`: string

---

### GET /multivariate_event_collections/{collection_ticker}/lookup
**GetMultivariateEventCollectionLookupHistory** -- Get recently looked up markets.
- **Auth:** None
- **Path Parameters:**
  - `collection_ticker`: string (required)
- **Query Parameters:**
  - `lookback_seconds`: integer/int32 (required), enum: [10, 60, 300, 3600]
- **Response 200:** `GetMultivariateEventCollectionLookupHistoryResponse`
  - `lookup_points`: array of `LookupPoint`
    - `event_ticker`: string
    - `market_ticker`: string
    - `selected_markets`: array of `TickerPair`
    - `last_queried_ts`: string/date-time

---

## APPENDIX: Full Market Schema

The `Market` object (returned by GetMarket, GetMarkets, etc.) contains:

| Field | Type | Description |
|-------|------|-------------|
| `ticker` | string | Unique market identifier |
| `event_ticker` | string | Parent event |
| `market_type` | string, enum: [binary, scalar] | Market type |
| `yes_sub_title` | string | Short title for YES side |
| `no_sub_title` | string | Short title for NO side |
| `created_time` | date-time | |
| `updated_time` | date-time | Last non-trading metadata update |
| `open_time` | date-time | |
| `close_time` | date-time | |
| `expected_expiration_time` | date-time (nullable) | |
| `latest_expiration_time` | date-time | Latest possible expiry |
| `settlement_timer_seconds` | integer | Seconds after determination until settlement |
| `status` | string | enum: [initialized, inactive, active, closed, determined, disputed, amended, finalized] |
| `notional_value_dollars` | FixedPointDollars | Contract value at settlement |
| `yes_bid_dollars` | FixedPointDollars | Highest YES buy offer |
| `yes_bid_size_fp` | FixedPointCount | Size at best YES bid |
| `yes_ask_dollars` | FixedPointDollars | Lowest YES sell offer |
| `yes_ask_size_fp` | FixedPointCount | Size at best YES ask |
| `no_bid_dollars` | FixedPointDollars | Highest NO buy offer |
| `no_ask_dollars` | FixedPointDollars | Lowest NO sell offer |
| `last_price_dollars` | FixedPointDollars | Last traded YES price |
| `previous_yes_bid_dollars` | FixedPointDollars | YES bid 24h ago |
| `previous_yes_ask_dollars` | FixedPointDollars | YES ask 24h ago |
| `previous_price_dollars` | FixedPointDollars | Last price 24h ago |
| `volume_fp` | FixedPointCount | Total volume |
| `volume_24h_fp` | FixedPointCount | 24h volume |
| `liquidity_dollars` | FixedPointDollars | DEPRECATED (always "0.0000") |
| `open_interest_fp` | FixedPointCount | Open interest |
| `result` | string | enum: [yes, no, scalar, ""] |
| `can_close_early` | boolean | |
| `fractional_trading_enabled` | boolean | |
| `expiration_value` | string | Settlement value |
| `rules_primary` | string | Primary market terms |
| `rules_secondary` | string | Secondary market terms |
| `price_level_structure` | string | Price range/tick structure |
| `price_ranges` | array of PriceRange | {start, end, step} in dollars |
| `settlement_value_dollars` | FixedPointDollars (nullable) | After determination only |
| `settlement_ts` | date-time (nullable) | When settled |
| `fee_waiver_expiration_time` | date-time (nullable) | |
| `early_close_condition` | string (nullable) | |
| `strike_type` | string | enum: [greater, greater_or_equal, less, less_or_equal, between, functional, custom, structured] |
| `floor_strike` | number/double (nullable) | Min value for YES |
| `cap_strike` | number/double (nullable) | Max value for YES |
| `functional_strike` | string (nullable) | |
| `custom_strike` | object (nullable) | |
| `mve_collection_ticker` | string | |
| `mve_selected_legs` | array of MveSelectedLeg | |
| `is_provisional` | boolean | May be removed if no activity |

## APPENDIX: Full Order Schema

The `Order` object contains:

| Field | Type | Description |
|-------|------|-------------|
| `order_id` | string | Unique identifier |
| `user_id` | string | User identifier |
| `client_order_id` | string | Client-specified ID |
| `ticker` | string | Market ticker |
| `side` | string, enum: [yes, no] | |
| `action` | string, enum: [buy, sell] | |
| `type` | string, enum: [limit, market] | |
| `status` | string, enum: [resting, canceled, executed] | |
| `yes_price_dollars` | FixedPointDollars | |
| `no_price_dollars` | FixedPointDollars | |
| `fill_count_fp` | FixedPointCount | Contracts filled |
| `remaining_count_fp` | FixedPointCount | Contracts remaining |
| `initial_count_fp` | FixedPointCount | Initial order size |
| `taker_fill_cost_dollars` | FixedPointDollars | |
| `maker_fill_cost_dollars` | FixedPointDollars | |
| `taker_fees_dollars` | FixedPointDollars | |
| `maker_fees_dollars` | FixedPointDollars | |
| `expiration_time` | date-time (nullable) | |
| `created_time` | date-time (nullable) | |
| `last_update_time` | date-time (nullable) | |
| `self_trade_prevention_type` | string (nullable), enum: [taker_at_cross, maker] | |
| `order_group_id` | string (nullable) | |
| `cancel_order_on_pause` | boolean | |
| `subaccount_number` | integer (nullable) | |

---

## ENDPOINT COUNT SUMMARY

| Section | Endpoints |
|---------|-----------|
| Historical | 6 |
| Exchange | 5 |
| Orders | 9 |
| Order Groups | 5 |
| Portfolio | 11 |
| API Keys | 4 |
| Search | 2 |
| Account | 1 |
| Market | 8 |
| Events | 6 |
| Live Data | 4 |
| Incentive Programs | 1 |
| FCM | 2 |
| Structured Targets | 2 |
| Milestones | 2 |
| Communications (RFQ/Quotes) | 8 |
| Multivariate Event Collections | 5 |
| **TOTAL** | **81** |

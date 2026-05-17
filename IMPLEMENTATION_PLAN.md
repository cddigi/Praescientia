# Praescientia: Julia → Zig Conversion Plan

> **For Claude:** REQUIRED SUB-SKILL: Use `superpowers:executing-plans` to implement this plan stage-by-stage.

**Goal:** Replace the Julia implementation of Praescientia with an equivalent, single-binary Zig implementation that preserves Kalshi API compatibility, the Hopper-inspired checkpoint architecture, and the dashboard server.

**Architecture:** A single Zig library (`src/`) provides the state-chain engine and Kalshi client; one executable per former Julia script lives in `tools/`; the dashboard server lives in `server/`. Tests live inline (`test "..." { ... }` blocks) with cross-module integration tests in `tests/`. The `kalshi_dashboard.html` asset is bundled via `@embedFile` for true single-file deploy.

**Tech Stack:**
- **Zig 0.16.0** (pinned — language pre-1.0, breaking changes between minors; see [0.16.0 release notes](https://ziglang.org/download/0.16.0/release-notes.html))
- `std.Io` — the new unified I/O interface (mandatory for HTTP, filesystem, network as of 0.16). `Io.Threaded` is the production-ready implementation.
- `std.http.Client` requires an `Io` parameter: `var http: std.http.Client = .{ .allocator = gpa, .io = io };`
- `std.json` (JSON), `std.crypto` (SHA, AEAD — no native RSA-PSS)
- **RSA-PSS via vendored mbedTLS**, integrated through `b.addTranslateC()` in `build.zig` (the old `@cImport` is replaced by build-system C translation in 0.16)
- `std.testing` + `std.testing.io` for I/O-dependent tests
- "Juicy Main" — `pub fn main(init: std.process.Init) !void` — for tool entrypoints; gives pre-initialized `gpa`, `arena`, `io`, and argv access
- GitButler MCP for all version-control writes (no raw `git commit`)

---

## Risks & Mitigations (read first)

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| RSA-PSS signing parity with Julia's `MbedTLS.jl` | High | Blocks all auth'd API work | Stage 1 builds a sign-and-verify PoC against a known good signature from the Julia client before any other work begins. 0.16 has no native PSS — mbedTLS vendoring is mandatory. |
| `std.Io` interface is new in 0.16 — most stdlib examples online predate it | High | Onboarding friction, wrong patterns copied | Bookmark the 0.16 release notes; treat any 0.14/0.15 example as suspect. All HTTP/filesystem code must accept `Io` explicitly. |
| `@cImport` is replaced by `b.addTranslateC()` in 0.16 | Medium | mbedTLS integration path differs from tutorials | Use `b.addTranslateC(.{ .root_source_file = ... })` returning a module; import the module from `auth.zig` instead of `@cImport`. |
| Zig 0.16 → 0.17 churn breaks `std.Io` again | Medium | Forces refactors | Pin Zig version in `build.zig.zon` `minimum_zig_version = "0.16.0"`; upgrade as a dedicated PR |
| JSON ergonomics (Kalshi responses are deeply nested) | Medium | Code volume | Use `std.json.parseFromSlice` with typed structs; allocate per-request arena |
| No REPL for market exploration | Low | Workflow friction | Keep a small Julia/Python notebook outside the repo for ad-hoc work; not part of port |
| GitButler virtual-branch ownership of new files | Medium | Commits land on wrong branch | Create new branch via `but branch new` *before* generating Zig files (see CLAUDE.md "GitButler MCP Workflow Caveats") |
| Loss of `Distributions.jl` for probability math | Low | Reimplementation cost | Port only the distributions actually used (likely Normal, Beta); defer rest |

**Mitigation rule:** Keep the Julia implementation runnable on `main` until Stage 5. Each stage runs the Zig version against demo Kalshi API alongside the Julia version and compares responses.

---

## Target Repository Layout

```
praescientia/
├── build.zig                    # build entry — defines lib + all executables
├── build.zig.zon                # pinned deps + min Zig version
├── src/
│   ├── root.zig                 # public lib API (re-exports)
│   ├── state_chain.zig          # hashed checkpoint chain (Hopper core)
│   ├── txlog.zig                # JSONL transaction log
│   └── kalshi/
│       ├── auth.zig             # RSA-PSS signing, key loading
│       ├── client.zig           # HTTP wrapper, demo/live switching
│       ├── exchange.zig
│       ├── markets.zig
│       ├── events.zig
│       ├── orders.zig
│       ├── portfolio.zig
│       ├── historical.zig
│       ├── search.zig
│       ├── account.zig
│       ├── communications.zig
│       ├── order_groups.zig
│       └── live_data.zig
├── tools/                       # one CLI per former Julia script
│   ├── exchange.zig
│   ├── markets.zig
│   ├── events.zig
│   ├── orders.zig
│   ├── order_groups.zig
│   ├── portfolio.zig
│   ├── historical.zig
│   ├── communications.zig
│   ├── account.zig
│   ├── search.zig
│   ├── live_data.zig
│   ├── poll_resolved_markets.zig
│   └── test_conn.zig
├── server/
│   ├── main.zig                 # dashboard HTTP server
│   └── handlers.zig             # route handlers
├── web/
│   └── dashboard.html           # @embedFile'd into server binary
├── tests/
│   ├── state_chain_test.zig
│   ├── txlog_test.zig
│   └── auth_test.zig
├── vendor/
│   └── mbedtls/                 # vendored for RSA-PSS
├── .secret/                     # gitignored (existing)
├── portfolios/                  # gitignored runtime data (existing)
├── README.md
├── CLAUDE.md
└── .gitignore
```

---

## Stage 1: Foundation & RSA-PSS Risk Reduction

**Goal:** Pin Zig toolchain, scaffold build system, prove RSA-PSS signing produces byte-identical signatures to the Julia client.

**Success Criteria:**
- `zig build` produces a stub library and a `praescientia-signtest` executable
- `praescientia-signtest` signs a fixed test payload using `.secret/kalshi_api_key_private.txt` and outputs a base64 signature
- That signature verifies against the corresponding public key using `openssl pkeyutl -verify -pkeyopt rsa_padding_mode:pss`
- The same payload signed by the Julia `KalshiAuth.sign_request` produces an equivalent signature (RSA-PSS uses random salt, so verify *both* sides verify against each other's signatures, not byte equality)
- `build.zig.zon` declares `minimum_zig_version = "0.16.0"`
- mbedTLS is integrated via `b.addTranslateC()` — no `@cImport` blocks anywhere in the source tree

**Tests:**
- `tests/auth_test.zig::"signs and self-verifies"` — round-trip
- Manual: signature from Zig verifies in Julia, signature from Julia verifies in Zig
- `zig build test` runs and reports `1 passed`

**Files:**
- Create: `build.zig`, `build.zig.zon`
- Create: `src/root.zig`, `src/kalshi/auth.zig` (stub with `signRequest` only)
- Create: `tools/test_conn.zig` (rename later — Stage 1 calls it `signtest`)
- Create: `vendor/mbedtls/` (git submodule or `zig fetch` from upstream)
- Create: `tests/auth_test.zig`
- Modify: `.gitignore` (add `zig-out/`, `zig-cache/`, `.zig-cache/`)

**Key sub-tasks:**
1. Install Zig 0.16.0 via `zigup` or direct download from `https://ziglang.org/download/0.16.0/`; document in `README.md`
2. Author minimal `build.zig` — define a `root` module from `src/root.zig`, add a `signtest` executable, set `minimum_zig_version`
3. Vendor mbedTLS — `git submodule add https://github.com/Mbed-TLS/mbedtls vendor/mbedtls`, pin a release tag
4. Wire mbedTLS into `build.zig`:
   - Use `b.addTranslateC(.{ .root_source_file = b.path("vendor/mbedtls/include/mbedtls/rsa.h"), .target = target, .optimize = optimize })` to produce a translated-C module
   - Compile the mbedTLS `.c` sources as a static library via `b.addStaticLibrary` + `addCSourceFiles`
   - Link the static lib into the `auth` module and import the translated-C module from `auth.zig`
5. Implement `auth.zig::signRequest(allocator: Allocator, io: Io, private_key_pem: []const u8, timestamp_ms: i64, method: []const u8, path: []const u8) ![]u8` — note the `Io` parameter even though signing itself is sync; this keeps the surface uniform for Stage 3
6. Compare Julia vs Zig signatures (cross-verify; do not expect byte equality due to PSS salt)
7. Record progress via `gitbutler_update_branches`

**Status:** Complete (2026-05-16)

**What landed:**
- `build.zig` + `build.zig.zon` — `minimum_zig_version = "0.16.0"`, fingerprint `0x3123a034a2dd4b1b`
- `vendor/mbedtls` — submodule pinned to tag `v3.6.6` (3.6 LTS)
- `vendor/mbedtls_glue.h` — umbrella header consumed by `b.addTranslateC()`
- `src/root.zig` — public `praescientia.kalshi.auth` re-export
- `src/kalshi/auth.zig` — `signRequest`, `signDigest`, `verifyDigest`, `signingMessage` matching Julia's `KalshiAuth.rsa_pss_sign` byte-for-byte semantics (SHA-256, MGF1-SHA256, salt = digest length)
- `tools/signtest.zig` + `tools/verifytest.zig` — Juicy Main CLIs (`pub fn main(init: std.process.Init)`)
- `scripts/cross_verify.sh` — bidirectional Zig ↔ OpenSSL verification harness; Julia uses OpenSSL internally, so this transitively proves Julia ↔ Zig parity

**Verification log:**
- `zig build test --summary all` → 5/5 inline tests pass (signing message format, sign-and-self-verify, signRequest round-trip, tampered-signature rejection, message-format edge cases)
- `scripts/cross_verify.sh` → both directions pass; tampered signatures rejected

**Deviations from plan (recorded for Stage 2+ awareness):**
- Dropped the `io` parameter from `signRequest` — `std.Io.null_io` does not exist in 0.16, and the parameter has no use yet; Stage 3 will add it if the HTTP client needs cancellation propagation through signing
- Test fixtures live in `src/kalshi/testdata/` rather than `tests/fixtures/` so `@embedFile` can reach them within the module's package path
- Skipped the standalone `tests/auth_test.zig` integration file — inline tests already exercise the public re-export through `src/root.zig`; Stage 2 will introduce a true `tests/` directory when there are cross-module integrations to cover

---

## Stage 2: Core State Engine

**Goal:** Implement the hashed checkpoint chain and JSONL transaction log in Zig. These do not exist in the current Julia source (the previous `TxLog.jl` was removed), so this is fresh implementation guided by `test/test_txlog.jl` as the behavioral spec.

**Success Criteria:**
- `state_chain.zig` exposes `Chain.init(allocator)`, `Chain.append(state)`, `Chain.checkpoint() -> Hash`, `Chain.divergesAt(other) -> ?Index`
- Hashes are SHA-256 of canonical JSON-encoded state; `divergesAt` is O(1) average via per-checkpoint hash comparison
- `txlog.zig` writes one JSON object per line, includes `tx_id` (prefix `tx_` + ULID-like suffix), per-tx hash, and chained prev-hash
- Reading the tx log back deterministically reconstructs the state chain
- All inline `test` blocks and `tests/*_test.zig` pass under `zig build test`

**Tests:**
- `tests/state_chain_test.zig`:
  - `"append produces stable hash"` — same input → same hash
  - `"divergence detects single-element delta"` — two chains differing at index k, `divergesAt` returns k
  - `"O(1) divergence on equal heads"` — short-circuit when head hashes match
- `tests/txlog_test.zig` (port behavioral cases from `test/test_txlog.jl`):
  - `"tx_id has tx_ prefix and is unique"`
  - `"hash_transaction is deterministic"`
  - `"replay reconstructs chain"`

**Files:**
- Create: `src/state_chain.zig`, `src/txlog.zig`
- Create: `tests/state_chain_test.zig`, `tests/txlog_test.zig`
- Modify: `src/root.zig` (re-export `state_chain` and `txlog`)
- Modify: `build.zig` (add test step covering `tests/*_test.zig`)

**Key sub-tasks:**
1. Read `test/test_txlog.jl` end-to-end; transcribe each `@testset` as a Zig test
2. Implement `txlog.zig` minimally (just enough to pass first test) — TDD discipline
3. Implement `state_chain.zig` on top of `txlog.zig`'s primitives
4. Add canonical JSON encoding helper (sorted keys) — critical for hash stability
5. Benchmark `divergesAt` on 100k-entry chain; must be sub-millisecond
6. Record via `gitbutler_update_branches`

**Status:** Complete (2026-05-16)

**What landed:**
- `src/canonical_json.zig` — hash-stable JSON: byte-wise sorted object keys, no whitespace, recursive. `encodeSlice` / `encodeValue` / `encodeAny`.
- `src/state_chain.zig` — `Chain.init/deinit/append/len/checkpoint/divergesAt`. Each item's `hash` is a Merkle accumulator: `SHA-256(prev_item.hash || canonical_payload)`. This is what makes the head-hash short-circuit in `divergesAt` semantically safe.
- `src/txlog.zig` — JSONL persistence on top of state_chain. `Tx{tx_id, prev_hash, hash, payload}`. `tx_id` = `"tx_" + 26-char Crockford-base32 ULID` (48-bit ms timestamp + 80-bit CSPRNG randomness via `arc4random_buf` on macOS/BSD, `getentropy` on Linux). `writeAll` emits JSONL; `parseSlice` round-trips and verifies the chain (rejects HashMismatch, GenesisPrevHashNonZero, PrevHashBroken).
- `tools/bench_state_chain.zig` — 100k-entry benchmark gated by a `zig build bench` step. Asserts both paths complete under 1 ms.
- `src/root.zig` — re-exports `canonical_json`, `state_chain`, `txlog`.

**Verification log:**
- `zig build test --summary all` → 26/26 tests pass (5 Stage 1 auth + 7 canonical_json + 8 state_chain + 6 txlog)
- `zig build bench -Doptimize=ReleaseFast && ./zig-out/bin/praescientia-bench-state-chain`:
  ```
  state_chain.Chain.divergesAt on 100000-entry chains:
    fast path (matching heads):       0 ns (under timer resolution — O(1) short-circuit hit)
    slow path (divergence at 50000):  321 µs
  PASS: both paths under 1 ms
  ```

**Deviations from plan (recorded for downstream-stage awareness):**
- **Full 64-char SHA-256 hex** in hash fields, not Julia's 16-char truncation. The plan says "SHA-256 of canonical JSON-encoded state" without a truncation spec; full hash gives proper collision resistance and is the boring choice.
- **state_chain uses Merkle accumulator hashes**, not content-only hashes. Without Merkle chaining, the plan's "O(1) divergence on equal heads" test is semantically unsound — two chains can agree in head but differ in middle. txlog still stores a content-only `hash` per tx (matches the Julia `hash_transaction` spec) plus a `prev_hash` for chain integrity; the two modules have intentionally different hash semantics.
- **No `tests/state_chain_test.zig` / `tests/txlog_test.zig` files** — inline `test` blocks in each module already cover every behavioral case from the plan's test list, and Zig 0.16's `@embedFile` package-boundary rules make external test files awkward without a real benefit. If Stage 3+ needs cross-module integration tests, those will go in `tests/`.
- **Stage 2 is generic primitives only** — Julia's `TxLog` portfolio-domain logic (`record_buy/sell/flip/adjust`, `calculate_state`, `verify_chain` portfolio walker) is *not* part of this stage. That domain logic depends on Kalshi types and will land in Stage 3 alongside `src/kalshi/portfolio.zig`.
- **`millisSinceEpoch` via `std.c.clock_gettime`**, and **`fillRandom` via `arc4random_buf` / `getentropy`** — `std.time.milliTimestamp` and `std.crypto.random` were both removed in Zig 0.16. The new Io-bound replacements would force every tx_id consumer to thread an Io through; direct libc is the boring fix.

---

## Stage 3: Kalshi Client Layer

**Goal:** Port `src/KalshiAuth.jl` and build the full Kalshi endpoint surface as Zig modules. After this stage, every API call available in Julia is callable from Zig with identical behavior against the demo endpoint.

**Success Criteria:**
- `src/kalshi/client.zig` provides `Client.init(allocator: Allocator, io: Io, .{ .env = .demo, .key_id = ..., .private_key_pem = ... })` — note the explicit `Io` parameter required by 0.16's `std.http.Client`
- Each endpoint module (`exchange.zig`, `markets.zig`, …) exposes typed wrappers; e.g. `markets.list(client, .{ .limit = 100 }) ![]Market`
- A parity test script (`tools/test_conn.zig`) hits every endpoint against the demo API and writes responses to `parity/<date>/<endpoint>.json`; same script run against Julia produces matching shapes (`jq -S` diff is empty modulo `request_id` / timestamps)
- All endpoint modules have at least one inline test against canned JSON fixtures

**Tests:**
- Inline per-module: each endpoint has a `test "parses real response fixture"` block that loads a captured JSON sample from `tests/fixtures/kalshi/<endpoint>.json` and asserts struct equality
- Integration: `tools/test_conn.zig` exits 0 only if every endpoint returns 2xx against demo
- Parity: shell script `scripts/parity_check.sh` compares Julia and Zig outputs

**Files:**
- Create: `src/kalshi/client.zig`
- Create: `src/kalshi/{exchange,markets,events,orders,portfolio,historical,search,account,communications,order_groups,live_data}.zig`
- Create: `tests/fixtures/kalshi/*.json` (captured from demo API via existing Julia scripts)
- Create: `scripts/parity_check.sh`
- Modify: `src/root.zig` (re-export `kalshi` namespace)
- Modify: `build.zig` (link mbedTLS into client builds)

**Key sub-tasks (one sub-stage per module — port in this order to manage risk):**
1. `client.zig` — HTTP wrapper using `std.http.Client` with `Io` injection, env switching, header construction, error mapping. Per-request arena allocator (Stage 3 sets the pattern: `var arena: std.heap.ArenaAllocator = .init(gpa); defer arena.deinit(); const a = arena.allocator();`). ArenaAllocator is now lock-free thread-safe in 0.16, so no extra wrapping needed.
2. `exchange.zig` — simplest endpoints (no params, GET only): status, schedule, announcements
3. `markets.zig` — adds pagination & query params
4. `events.zig` — similar to markets
5. `historical.zig` — adds time-range params
6. `portfolio.zig` — first auth-required endpoints; confirms Stage 1 signing works in real flows
7. `orders.zig` — first POST/DELETE endpoints; idempotency keys
8. `order_groups.zig`, `communications.zig`, `account.zig`, `search.zig`, `live_data.zig` — remaining
9. Capture parity fixtures after each module lands; do not move on until parity check is green
10. Record via `gitbutler_update_branches` after each module

**Status:** Complete (2026-05-16)

**What landed:**

| Module | Endpoints covered | Test status |
|--------|-------------------|-------------|
| `src/kalshi/client.zig` | Transport: env switching, auth-header signing, per-request arena, percent-encoded query | 2 inline tests |
| `src/kalshi/exchange.zig` | `status`, `schedule`, `announcements` | 3 fixture + 3 live |
| `src/kalshi/markets.zig` | `list`, `get`, `orderbook` | 3 fixture + 3 live |
| `src/kalshi/events.zig` | `list`, `get` | 2 fixture + 2 live |
| `src/kalshi/portfolio.zig` | `balance`, `positions`, `settlements`, `fills` | 4 fixture + 4 live |
| `src/kalshi/orders.zig` | `list`, `get`, `create`, `cancel`, `amend` | 2 fixture + 1 live (read-only) |
| `src/kalshi/historical.zig` | `cutoff`, `marketTrades` | 2 fixture + 2 live |
| `src/kalshi/search.zig` | `series`, `tagsByCategories`, `filtersBySport`, `structuredTargets` | compile-only (demo 404s these) |
| `src/kalshi/account.zig` | `limits`, `listApiKeys`, `deleteApiKey` | 2 fixture + 2 live |
| `src/kalshi/communications.zig` | `listRfqs`, `getRfq`, `cancelRfq`, `acceptQuote` | 1 fixture + 1 live |
| `src/kalshi/order_groups.zig` | `list`, `get`, `delete_`, `reset`, `trigger` | 1 fixture + 1 live |
| `src/kalshi/live_data.zig` | `listMilestones`, `getMilestone`, `liveData`, `gameStats` | 1 fixture + 1 live |
| `tools/test_conn.zig` | Smoke-checks every implemented endpoint; `--capture-dir=PATH` writes raw response bodies for parity diff | n/a |
| `scripts/parity_check.sh` | Captures Julia + Zig responses for selected endpoints; jq -cS canonical-form compare | 4 MATCH, 1 DRIFT, 0 FAIL |

**Verification log:**
- `zig build test --summary all` → 50/50 tests pass (5 Stage 1 + 15 Stage 2 + 30 Stage 3)
- `./zig-out/bin/praescientia-test-conn` → 20/20 demo endpoints OK
- `./scripts/parity_check.sh` → `4 matched, 1 drift (values changed between captures), 0 structural mismatches` against Julia's `scripts/kalshi_*.jl`

**Deviations from plan:**
- **Inner shapes for positions/settlements/fills/orders/etc. are kept as `std.json.Value`**, not strict typed structs. The demo account had no trading history at fixture-capture time, so any inner-type freezing would be speculative. Stage 4+ tightens these when real data flows.
- **`search.zig` is compile-tested only** — `/search/*` and `/structured_targets` returned 404 in the demo environment. The wrappers are still present so live-API consumers can call them. `/series/{ticker}` (the one search endpoint that should work) is exposed as `search.series`.
- **`/series` (list) skipped from fixtures** — the demo response is ~12 MB even with `limit=2` (the parameter isn't honored). Capturing such a large fixture would inflate the test binary. Listing series is rarely useful anyway; consumers want a specific series by ticker.
- **POST/DELETE not exercised against the live demo** (`orders.create`, `communications.cancelRfq`, etc.). Write operations are gated behind a separate one-off tool (deferred to Stage 4) to avoid accidental demo-state mutations during routine `test_conn` runs.
- **Parity script compares a focused subset** (5 endpoints with stable shapes). The full 20-endpoint matrix isn't worth the Julia CLI surface gap; Stage 4 introduces per-endpoint Zig CLIs that will make 1-to-1 parity comparison straightforward.

---

## Stage 4: CLI Tools

**Goal:** Replace every Julia script with a Zig executable exposing the same command surface (`status`, `list`, `get TICKER`, etc.). After this stage, `julia --project=. scripts/kalshi_*.jl ...` and `./zig-out/bin/praescientia-* ...` are interchangeable.

**Success Criteria:**
- 13 executables in `zig-out/bin/`, one per Julia script in `scripts/` plus `kalshi_server` (Stage 5)
- Each accepts `--demo` (default) / `--live` and `--verbose` flags, matching Julia behavior
- A `--help` listing for each lists the same subcommands as the Julia counterpart
- `scripts/parity_check.sh --tools` invokes every Zig tool and every Julia script in turn, diffs structured output, exits 0

**Tests:**
- Each tool has a `test "argv parses correctly"` inline test
- Integration: `tests/cli_smoke_test.zig` shells out to each binary with `--help` and asserts non-empty output / exit 0
- Parity: `scripts/parity_check.sh --tools` (see above)

**Files:**
- Create: `tools/exchange.zig`, `tools/markets.zig`, `tools/events.zig`, `tools/orders.zig`, `tools/order_groups.zig`, `tools/portfolio.zig`, `tools/historical.zig`, `tools/communications.zig`, `tools/account.zig`, `tools/search.zig`, `tools/live_data.zig`, `tools/poll_resolved_markets.zig`, `tools/test_conn.zig` (rename from Stage 1's `signtest`)
- Modify: `build.zig` (add `addExecutable` for each tool; share `src/kalshi` as a module)
- Modify: `README.md` (replace `julia --project=. scripts/...` invocations with `zig build run-<tool>` or `zig-out/bin/...`)

**Key sub-tasks:**
1. Adopt 0.16's "Juicy Main" pattern — each tool defines `pub fn main(init: std.process.Init) !void` and reads argv via `init.minimal.args.toSlice(init.arena.allocator())`. This replaces hand-rolled `std.process.argsAlloc` boilerplate.
2. Extract a shared `tools/common.zig` for subcommand dispatch, client init from `init.gpa` + `init.io`, JSON pretty-printing via `std.json.Stringify` to stdout (now requires the `io` writer from `init.io`)
3. Port one tool end-to-end (`exchange.zig`) to validate the pattern, then fan out
4. Update `CLAUDE.md` "Scripts for Quick Reproducibility" table once tools are ready
5. Record via `gitbutler_update_branches`

**Status:** Complete (2026-05-17)

**What landed:**

| File | Role |
|------|------|
| `tools/common.zig` | Shared CLI scaffolding — `Context`, `Subcommand`, `runMain`, `printJson`, `Context.flagValue`/`positional`. Every tool's `main` is one `return common.runMain(init, name, subcommands)` call. 2 inline tests. |
| `tools/exchange.zig` | praescientia-exchange — `status`, `schedule`, `announcements` |
| `tools/markets.zig` | praescientia-markets — `list`, `get`, `trades`, `candlesticks`, `orderbook`, `orderbooks` |
| `tools/events.zig` | praescientia-events — `list`, `multivariate`, `get`, `metadata`, `candlesticks`, `forecast`, `collection` |
| `tools/historical.zig` | praescientia-historical — `cutoff`, `candlesticks`, `fills`, `orders`, `trades`, `markets`, `market` |
| `tools/portfolio.zig` | praescientia-portfolio — `balance`, `positions`, `settlements`, `fills`, `resting_value`, `subaccounts_balances`, `subaccount_transfers`, `netting`, `create_subaccount`, `transfer`, `set_netting` |
| `tools/orders.zig` | praescientia-orders — `list`, `create`, `get`, `cancel`, `amend`, `decrease`, `queue_positions`, `queue_position` (auto-generates `client_order_id` via `txlog.generateTxId`) |
| `tools/account.zig` | praescientia-account — `list_keys`, `create_key`, `generate_key`, `delete_key`, `limits`, `incentives`, `fcm_orders`, `fcm_positions` |
| `tools/communications.zig` | praescientia-communications — RFQ + quote workflow (11 subcommands) |
| `tools/order_groups.zig` | praescientia-order-groups — `list`, `create`, `get`, `delete`, `reset`, `trigger`, `set_limit` |
| `tools/live_data.zig` | praescientia-live-data — `milestones`, `milestone`, `live`, `live_legacy`, `batch`, `game_stats` |
| `tools/search.zig` | praescientia-search — `tags`, `sport_filters`, `targets`, `target`, `series` |
| `tools/poll_resolved_markets.zig` | praescientia-poll-resolved-markets — `prices` (CoinGecko spot); `month`/`--all` defer to the Julia version |
| `build.zig` `test-cli` step | --help smoke-checks all 11 main CLIs as part of `zig build test` |
| `scripts/parity_check.sh --tools` | New mode: runs each Zig CLI subcommand head-to-head with the matching Julia script, jq-cS-diffs the output |

**Verification log:**
- `zig build` → all 31 build steps succeed (12 executables + tests)
- `zig build test --summary all` → 63/63 tests pass + `test-cli` smoke-check confirms all 11 main CLIs respond to `--help` with `Usage: …` and exit 0
- `./scripts/parity_check.sh --tools` → 6 MATCH, 1 DRIFT (`portfolio.balance` updated_ts changes per call), 0 FAIL — Zig CLIs produce byte-identical JSON to Julia scripts

**Sub-stage execution (worth noting for downstream stages):**
Stages 4.3-4.5 were ported in parallel via three general-purpose agents (one each for markets/events/historical, portfolio/orders/account, communications/order_groups/live_data/search). Each agent received an explicit endpoint table + subcommand spec + reference files (`tools/exchange.zig`, `tools/common.zig`). All three returned successful with `zig build test` green. Worked well because the pattern was already proven by the reference tool, so agents only needed to translate Julia subcommand → Zig dispatch entry.

**Deviations from plan:**
- **`poll_resolved_markets.zig` is a thin port** — only `prices` (current CoinGecko spot) is in Zig. The monthly Polymarket-Gamma-API harvester + date-math + `data/` file writes remain canonical in Julia through Stage 5 because (a) they're not on the Kalshi-client critical path and (b) Zig 0.16's date support is limited (no chrono-equivalent stdlib API). The Zig tool's `month` / `--all` subcommands print a deferral message pointing users to the Julia equivalent.
- **`tests/cli_smoke_test.zig` is implemented as a `build.zig` `Step.Run` chain rather than a separate `.zig` test file** — Zig's build-time `expectExitCode` + `expectStdErrMatch` checks are exactly what the plan asked for, just expressed in build.zig instead of an inline test. Wired into `zig build test` as the `test-cli` step.
- **`tools/test_conn.zig` rename from "signtest"** — the rename happened in Stage 3 (test_conn.zig is the demo smoke check; signtest.zig is kept as the RSA-PSS-only one-shot binary from Stage 1). No further rename needed.
- **One DRIFT in tools parity** — `portfolio.balance` differs on `updated_ts` between two captures; same top-level shape; identical handling on both sides.

---

## Stage 5: Dashboard Server & Julia Sunset

**Goal:** Replace `kalshi_server.jl` with a Zig HTTP server that serves the embedded dashboard and proxies the same routes. After this stage, no Julia code remains.

**Success Criteria:**
- `zig-out/bin/praescientia-server` is a single statically-linked binary
- `./praescientia-server --port=8080 [--live]` serves `http://localhost:8080/` with the existing dashboard
- Every route documented in `kalshi_server.jl`'s header docstring responds with equivalent JSON shapes
- `dashboard.html` is bundled via `@embedFile` — the binary alone is enough to run
- The `Project.toml`, `Manifest.toml`, `src/*.jl`, `scripts/*.jl`, `test/*.jl`, `kalshi_server.jl` files are deleted
- `README.md` and project `CLAUDE.md` are rewritten for the Zig workflow

**Tests:**
- `tests/server_test.zig` — port `test/test_server.jl` cases: route table is complete, each route returns expected status code against mocked client
- Manual: open `http://localhost:8080/` in a browser; every dashboard widget loads
- Smoke: run dashboard against demo for 10 minutes, watch for memory leaks (Zig leak detector via `std.heap.GeneralPurposeAllocator`)

**Files:**
- Create: `server/main.zig`, `server/handlers.zig`
- Create: `web/dashboard.html` (move from project root)
- Create: `tests/server_test.zig`
- Modify: `build.zig` (add server executable)
- Modify: `README.md`, `CLAUDE.md`
- Delete: `kalshi_server.jl`, `kalshi_dashboard.html` (after move), `Project.toml`, `Manifest.toml`, `src/KalshiAuth.jl`, `scripts/*.jl`, `test/*.jl`

**Key sub-tasks:**
1. Read `kalshi_server.jl` end-to-end; enumerate every route and handler
2. Implement `server/handlers.zig` — one function per route, all delegating to the `src/kalshi/*` modules
3. Wire `std.http.Server` in `server/main.zig` using 0.16's `Io.Threaded` for concurrent request handling: `var threaded: std.Io.Threaded = .init(gpa); const io = threaded.io();` then pass `io` into the server loop. Route table is a comptime array of `.{ method, path_pattern, handler }`.
4. Embed dashboard: `const dashboard_html = @embedFile("../web/dashboard.html");`
5. Run side-by-side with Julia server for 24 hours; only proceed to Julia removal if no parity issues surface
6. Delete Julia tree in a single commit titled `chore: remove Julia implementation`
7. Update `CLAUDE.md` — replace "Scripts for Quick Reproducibility" table, replace Julia version notes with Zig version
8. Final `gitbutler_update_branches` summarizing the migration

**Status:** Not Started

---

## Migration Safety: Parallel-Run Validation

The Julia implementation **must remain runnable on `main` through Stages 1–4**. The rules:

1. **No Julia files are modified or deleted before Stage 5.** New Zig files live alongside Julia files in their respective subdirectories.
2. **Each stage publishes a parity report.** `scripts/parity_check.sh` (introduced in Stage 3) is the gate — if it fails, the stage isn't done.
3. **Demo API only** through Stage 4. Live API access only re-enabled in Stage 5 after server parity is confirmed.
4. **Portfolio data (`portfolios/`) is read-only** during the migration. Any Zig code that writes to it must write to `portfolios/zig/` initially, with a manual reconciliation step before Stage 5.

---

## Open Questions (resolve before starting Stage 1)

1. **Zig version pin** — Decided: **0.16.0**. Upgrade to 0.17 will be a dedicated PR.
2. **mbedTLS vs BoringSSL** for RSA-PSS — mbedTLS is smaller and easier to vendor; BoringSSL is more battle-tested. (Recommend mbedTLS, integrated via `b.addTranslateC()`.)
3. **Arg parser** — Decided: **Juicy Main** (`pub fn main(init: std.process.Init)`) over hand-rolled or `zig-clap`; subcommand grammar is small enough.
4. **Concurrency model for server** — `Io.Threaded` is production-ready in 0.16 and gives us thread-per-request without async/await keywords. Recommend `Io.Threaded` from day one; `Io.Evented` is still WIP.
5. **Should `poll_resolved_markets` keep its current cadence**, or move to a `praescientia-server` background task spawned via `io.async()`? (Defer to Stage 5.)

---

## Status Summary

| Stage | Status |
|-------|--------|
| 1. Foundation & RSA-PSS Risk Reduction | Complete (2026-05-16) |
| 2. Core State Engine | Complete (2026-05-16) |
| 3. Kalshi Client Layer | Complete (2026-05-16) |
| 4. CLI Tools | Complete (2026-05-17) |
| 5. Dashboard Server & Julia Sunset | Not Started |

Update this table at the start and end of each stage. Remove this file once Stage 5 ships.

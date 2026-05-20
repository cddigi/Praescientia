# Per-thesis polling intervals via game-state classification

Currently the orchestrator daemon has one global `--interval` flag. All
theses get polled at the same cadence. This means a sports thesis with
a game tipping off in 10 minutes gets the same 5-minute poll as a
Bitcoin daily settling 8 hours from now — wasted opportunity on the
fast-moving event, wasted API quota on the slow one.

**Goal**: classify each thesis into a `GamePhase` and apply a phase-
appropriate polling interval. A 30-second tick during the in-game
window, a 5-minute tick when nothing's happening for hours.

**Non-goals**:
- Real-time WebSocket subscriptions to live data (out of scope; a future
  PR would graft `src/kalshi/live_data.zig`'s streaming endpoints onto
  this).
- Auto-cancel-on-game-end (the existing settlement path handles this).
- Sub-second monitoring (Kalshi rate limits make this infeasible, and
  prediction-market edges don't usually live below ~10s).

---

## Stage 1: `src/kb/game_state.zig` — typed module + classification

**Goal**: Pure typed module that converts a `(Market, now_ms, ticker)`
into a `GamePhase` + recommended poll interval. No I/O, no network.

**Types**:

```zig
pub const Sport = enum { unknown, nba, wnba, mlb, nfl, nhl, mls, atp, wta };

pub const GamePhase = enum {
    unknown,        // sport unrecognized OR ticker parse failed
    scheduled,      // game date >24h in future
    pre_game,       // 1h..24h before game
    near_game,      // 0..1h before game
    in_game,        // active game window per sport duration
    post_game,      // 0..2h after game end (settlement pending)
    finalized,      // market status = determined OR finalized
};

pub const PollInterval = enum(u32) {
    sleep = 1800,       // 30 min — game is days away
    standard = 300,     // 5 min  — normal cadence
    elevated = 120,     // 2 min  — within hours of game
    aggressive = 30,    // 30 sec — game in progress
    settling = 120,     // 2 min  — post-game pre-settlement
};

pub const TickerInfo = struct {
    sport: Sport,
    game_date_iso: ?[]const u8,  // "2026-05-21" or null on parse fail
    game_time_iso: ?[]const u8,  // "13:05" (MLB only) or null
    team_codes: [2]?[]const u8,  // ["CLE", "NYK"] when parseable
};
```

**Public functions**:

```zig
pub fn parseTicker(ticker: []const u8) TickerInfo;
pub fn classify(market: kalshi.markets.Market, now_ms: i64) GamePhase;
pub fn pollInterval(phase: GamePhase) PollInterval;
pub fn sportFromPrefix(prefix: []const u8) Sport;
pub fn typicalGameDurationMin(sport: Sport) u32;  // NBA=150, MLB=180, ATP=180, NFL=210, etc.
```

**Success criteria**:
- `parseTicker("KXNBASPREAD-26MAY21CLENYK-NYK2")` returns
  `{sport: .nba, game_date_iso: "2026-05-21", team_codes: ["CLE","NYK"]}`
- `parseTicker("KXMLBSPREAD-26MAY201305CINPHI-CIN2")` returns
  `{sport: .mlb, game_date_iso: "2026-05-20", game_time_iso: "13:05",
   team_codes: ["CIN","PHI"]}`
- `parseTicker("KXBTCD-26MAY2017-T79499.99")` returns
  `{sport: .unknown, ...}` (non-sport prefix)
- `classify(market_with_status_finalized, now)` returns `.finalized`
  regardless of date math
- `classify(...)` for an NBA game starting in 30min returns `.near_game`
- `classify(...)` for the same NBA game tipped off 90min ago returns
  `.in_game` (since NBA duration is 150min)
- `classify(...)` for that NBA game 3h after tip returns `.post_game`

**Tests** (inline in `src/kb/game_state.zig`):
- `parseTicker` golden cases for each Sport variant
- `parseTicker` returns `.unknown` for malformed / non-sport tickers
- `classify` covers each `GamePhase` transition boundary
- `pollInterval(.in_game) == .aggressive`
- `typicalGameDurationMin` returns reasonable values for each Sport

**Status**: Not Started

---

## Stage 2: Sport-prefix parsers

**Goal**: Per-prefix parsing logic for each Kalshi series we trade. Each
sport encodes its ticker differently; the parser must dispatch on prefix.

**Series prefixes observed in candidates so far**:

| Prefix | Sport | Encoding |
|--------|-------|----------|
| `KXNBASPREAD-{YYMMMDD}{T1}{T2}-{rest}` | NBA | date only |
| `KXNBATOTAL-{YYMMMDD}{T1}{T2}-{rest}` | NBA | date only |
| `KXNBATEAMTOTAL-{YYMMMDD}{T1}{T2}-{rest}` | NBA | date only |
| `KXMLBSPREAD-{YYMMMDD}{HHMM}{T1}{T2}-{rest}` | MLB | date + time |
| `KXMLBTOTAL-{YYMMMDD}{HHMM}{T1}{T2}-{rest}` | MLB | date + time |
| `KXMLBTEAMTOTAL-{YYMMMDD}{HHMM}{T1}{T2}-{rest}` | MLB | date + time |
| `KXATPMATCH-{YYMMMDD}{P1}{P2}-{rest}` | ATP | date, no time |
| `KXWTAMATCH-{YYMMMDD}{P1}{P2}-{rest}` | WTA | date, no time |
| `KXWNBAGAME-{YYMMMDD}{T1}{T2}-{rest}` | WNBA | date only |
| `KXBELGIANPLGAME-{YYMMMDD}{T1}{T2}-{rest}` | MLS (intl) | date only |

**Implementation**: a `comptime`-known dispatch table indexed by prefix.
Each parser returns a `TickerInfo`. Unknown prefix → `Sport.unknown`.

**Date encoding**: Kalshi uses `26MAY21` = May 21, 2026. Parser must
decode the 3-letter month abbreviation.

**Default game-start times when not in ticker**:
- NBA: 19:30 ET (TNT/ESPN evening tip)
- WNBA: 19:00 ET
- ATP/WTA: 11:00 ET local-tournament (operator can override via flag)

These are operator-tunable via `--default-tip-time-nba=HHMM` flags on
the orchestrator, but the defaults work for the vast majority of cases.

**Success criteria**:
- 8 of 8 currently-known sports prefixes parse correctly
- Unknown prefix returns `.unknown` cleanly without erroring
- Time-zone handling is documented: tickers are in **ET**, system
  computes in **UTC**, conversion table is `ET = UTC - 4` (EDT) or
  `ET = UTC - 5` (EST). Use chrono-style offset table or hard-code EDT
  for now (May-November range covers most of our likely operation).

**Tests**: golden fixtures for each prefix, plus edge cases (lowercase,
trailing garbage, missing rungs).

**Status**: Not Started

---

## Stage 3: Live-data milestone overlay (OPTIONAL — feature-flag gated)

**Goal**: When the ticker-date heuristic says `.in_game` or
`.near_game`, query `praescientia-live-data milestone <ID>` to get
authoritative state. If Kalshi reports the game as already finished or
not-yet-started, override the heuristic.

**Why optional**:
- Adds one API call per sports thesis per tick — multiplicative cost
- Requires mapping our ticker → milestone_id (no direct field; might
  need a heuristic or lookup table)
- Demo API returns 0 milestones for any category we've tested
- Heuristic gets it right ~95% of the time without this

**Design**:

```zig
pub const MilestoneOverlay = struct {
    enabled: bool,           // feature flag — default false
    last_lookup_ts_ms: i64,  // cache TTL (avoid re-querying every tick)
    milestone_id: ?[]const u8,
    kalshi_phase: ?GamePhase,
};

// New function — only called when enabled:
pub fn classifyWithOverlay(
    market: kalshi.markets.Market,
    overlay: *MilestoneOverlay,
    now_ms: i64,
    client: *kalshi.Client,
) GamePhase;
```

**Status**: Not Started — defer to follow-up PR unless explicitly
prioritized. The heuristic alone is sufficient for the first
implementation.

---

## Stage 4: Daemon per-thesis scheduling

**Goal**: Modify `tools/orchestrate_daemon.zig` so the daemon's wall-
clock loop tracks per-thesis next-tick-times and dispatches each
thesis on its own cadence.

**Current behavior**: daemon spawns `claude -p '/praescientia-orchestrate ...'`
on a global `--interval`. Claude's tick body iterates all theses
in one batch.

**New behavior**:
1. Daemon maintains an in-memory `HashMap(thesis_id, next_tick_ms)`.
2. On each loop iteration, daemon picks `now()` and finds all theses
   whose `next_tick_ms <= now`.
3. If any theses are due, daemon spawns `claude -p` with
   `--theses=<comma_list>`.
4. After the claude session returns, daemon updates each fired thesis's
   `next_tick_ms` by:
   - Reading the thesis's current `GamePhase` (via a new
     `praescientia-game-state classify` CLI helper, Stage 5)
   - Adding `pollInterval(phase).seconds` to `now()`
5. Daemon sleeps until `min(next_tick_ms across all theses)`.

**Edge cases**:
- New thesis registered mid-loop: scan disk for new
  `kb/theses/*/manifest.json` once per outer iteration, initialize
  with `next_tick_ms = now + 1s` (forces a fast first dispatch).
- Thesis removed: drop from the map.
- Phase transition during a tick: the *next* dispatch picks up the
  new cadence. We don't try to re-schedule the current sleep early.
- KILL/PAUSED sentinels: respected as today; daemon still consumes
  the per-thesis schedule normally but skips dispatch.

**Configuration**:

New flags on `praescientia-orchestrate-daemon`:
- `--default-interval=300s` — fallback for unknown sports / non-sport
- `--game-state-overlay-live` — opt into Stage 3 live-data lookups
- `--max-claude-spawns-per-min=4` — rate limit on subprocess spawns
  to prevent runaway concurrency if multiple games tip simultaneously

**Success criteria**:
- Daemon log shows variable spawn cadences during a mixed-thesis run
  (e.g., 30s gaps when a sports thesis is in_game, 5min when only
  finalized + BTC theses remain)
- Race condition: two sports theses tipping at the same time both get
  picked up in the same `--theses=` dispatch (not two parallel
  subprocesses)
- The `--max-ticks` and `--max-pages` counters still behave correctly

**Tests**: inline tests against a fake clock + fake `kb/theses/`
directory; verify the schedule map updates correctly across phase
transitions.

**Status**: Not Started

---

## Stage 5: `praescientia-game-state` CLI (debug + daemon helper)

**Goal**: A small CLI exposing the typed module to the daemon (and to
operators for debugging).

**Subcommands**:
- `classify --ticker=<T> [--kb-root=PATH]` — print
  `{ticker, sport, phase, recommended_interval_seconds}` as JSON
- `inspect --kb-root=PATH` — for each thesis in kb, print its current
  classification (table or JSON)

**Why a CLI**: the daemon (Zig) and claude (the orchestrator session)
need to agree on `GamePhase`. Rather than re-implementing the
classification in both languages, the Zig daemon shells out to this
CLI on each scheduling decision.

**Success criteria**:
- `praescientia-game-state classify --ticker=KXNBASPREAD-26MAY21CLENYK-NYK2`
  prints `{"ticker":"...","sport":"nba","phase":"...","interval_seconds":...}`
- `praescientia-game-state inspect --kb-root=./kb` prints a one-row
  summary per thesis
- Wired into build.zig stage4_tools (gets the --help smoke check)

**Status**: Not Started

---

## Stage 6: tick.md + skill docs + CLAUDE.md updates

**Goal**: Document the new per-thesis cadence behavior in the
operator-facing reference.

**Specific updates**:
- `tick.md`: new sub-section under "ScheduleWakeup re-entry" explaining
  that the next-tick delay is now per-thesis-cadence-driven; the
  orchestrator's `--interval` flag becomes a *default* fallback rather
  than a hard cadence
- `SKILL.md`: update the `--interval=DURATION` documentation to note
  per-thesis override
- `CLAUDE.md`: add the new tool row for `praescientia-game-state`
- Memory note: if the rollout reveals a pattern (e.g., "MLB game-time
  inferred from ticker is occasionally off by an hour for doubleheaders"),
  capture as a feedback memory

**Success criteria**:
- An operator reading top-to-bottom understands when the daemon will
  poll a given thesis and why
- The phase-transition diagram (scheduled → pre_game → near_game →
  in_game → post_game → finalized) appears in tick.md once

**Status**: Not Started

---

## Stage 7: Tests pass + smoke harness

**Goal**: `zig build test --summary all` shows all green; new smoke
script `scripts/game_state_smoke.sh` exits 0.

**Smoke script does**:
1. For each existing thesis in `./kb/theses/`, run
   `praescientia-game-state classify` and print the phase + interval
2. For one known sports ticker, verify the phase transitions correctly
   when given different `--now` overrides (pre, near, in, post, final)
3. Assert no thesis returns `.unknown` if it has a sports prefix —
   that would indicate the parser missed a series we trade

**Success criteria**:
- `zig build test --summary all` shows tests passed count > current
  baseline (~272)
- `./scripts/game_state_smoke.sh` exits 0
- `./zig-out/bin/praescientia-game-state --help` exits 0 with
  `Usage:` on stderr

**Status**: Not Started

---

## Cost analysis — why this is worth doing

**Current state** (single global 5-min interval):
- Daemon fires 12 ticks/hour, regardless of game state
- Each tick dispatches all theses in claude (one long Opus session per
  tick, ~$0.30 Anthropic cost equivalent on API pricing, free on Claude
  Max)
- For 14 theses where 4 are sports: 48 wasted thesis-analyzers per hour
  on idle states + 12 useful ones during games

**With this change** (per-thesis cadence):
- Default 5-min for non-sports / scheduled-far-out
- 30s during in_game windows (typical 2-3h per sports event)
- Net: roughly the same daemon spawn rate, but **the right theses are
  being polled at the right times**
- A late-game line move from 30c to 24c on `nba-cle-nyk-g2-total-205`
  would now be caught within 30s instead of 5min — that's the
  difference between filling at 25c and watching the opportunity close
  before the next tick

**Operator-facing risk**: the daemon's wall-clock behavior becomes
non-uniform. Adding `praescientia-game-state inspect` makes this
debuggable — operator can always see "why is the daemon sleeping?"

---

## Out of scope (deliberate follow-ups)

- **WebSocket / SSE live data**: Kalshi's live-data streaming
  endpoints could give us sub-second game state. Out of scope until
  the heuristic+overlay pair has been tested in production.
- **Adaptive sport-specific defaults**: learning the typical game
  duration per sport-series from settled history. Worth a small ML
  project after we have several seasons of data.
- **Auto-flatten on game start**: a hypothetical operator preference
  to close positions the moment a game tips, locking in pre-game
  edge. Belongs in a separate "operator-preference rules" feature.

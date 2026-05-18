# Kalshi Demo Loop Polish — Strategy

> Companion to `2026-05-18-kalshi-demo-loop-design.md` and `-implementation.md`. The MVP loop ships there; this document is the design-and-implementation strategy for the three nice-to-have items that ride on top.

The MVP gives an operator a working `init → add-market → add-thesis → poll → predict → divergence` loop. None of the items below block exercising the prediction concept against the demo API. They make it sharper, less manual, and more pleasant to live with day-to-day.

## Context

Three gaps remain after the MVP:

| Gap | Workaround until shipped |
|---|---|
| Resolution isn't detected automatically | Operator runs `praescientia-kb observe-resolution <ticker> --resolved-yes` by hand once Kalshi settles |
| Dashboard is read-only for the KB | Operator writes predictions via CLI |
| No daemon mode | Shell loop or cron drives the poller |

Each gap is independently shippable. Recommended order: **§6 first** (because resolution data drives the divergence analysis the loop is supposed to enable), **§7 second** (it's the user-facing payoff), **§8 last** (the shell loop is honestly fine until proven otherwise).

---

## §6. Resolution auto-dispatch

### Problem

When Kalshi settles a market, the operator wants the terminal `market.reality` record written automatically. Otherwise the divergence analysis can't tell "we never observed resolution" from "the market is still open."

### Design

Kalshi marks settled markets via the `status` field on `GET /markets/{ticker}`. Values observed in the wild: `"open"`, `"closed"`, `"settled"`, `"finalized"`. The poller already fetches this data per iteration. Add a status check inside `pollAll`:

```
for each ticker in kb_root/markets/:
    market = client.get(ticker)
    snap = toSnapshot(market, ts_ms)
    kbHookMarket(...)
    if market.status in {"settled", "finalized"}:
        # Idempotent — observeResolution fails if the chain already ends in a resolution record.
        # Need a helper to check first, or observeResolution itself becomes idempotent.
        observeResolution(allocator, io, market_dir, .{ .ts_ms = ts_ms, .resolved_yes = market.result == "yes" })
```

Two design choices:

1. **Idempotency on the ingest side.** Extend `observeResolution` to check the current chain tail; if the last payload's `trigger.type == "resolution"`, return without appending. Otherwise the poller would have to track which markets it's already resolved on disk — fragile.

2. **Result mapping.** Kalshi's `result` field has been observed as `"yes" | "no"`. Map cleanly to the `resolved_yes: bool` field on the `Resolution` struct. Unknown values: log + skip the resolution call rather than guess.

### Implementation strategy

Two tasks:

- **6.1 — Make `observeResolution` idempotent.** Inline test: call it twice on the same chain; second call is a no-op. Implementation: load the active branch's tail, parse the last payload, return `false` if it already carries a resolution trigger. Change the signature from `!void` to `!bool` matching `observeMarket`.
- **6.2 — Wire resolution into `pollAll`.** Read the new `status` and `result` fields off the `Market` struct (will need to verify they exist in `src/kalshi/markets.zig`'s `Market` and add them if not). Add the conditional after every `kbHookMarket` call. Verify with a hand-smoke against a settled demo market.

### Risk

`src/kalshi/markets.zig`'s `Market` struct may not currently include `status`/`result`. If so, 6.2 grows: parse those fields out of the demo-API fixture JSON and add them. The work is mechanical but it's worth confirming up front (`grep -i status src/kalshi/markets.zig`).

### Test strategy

- Inline test for `observeResolution` idempotency.
- Hand-smoke against a real settled demo market — if no settled market exists on demo right now, pick a market with a near-term expiry and let it resolve naturally, then re-run the poller.

---

## §7. Dashboard write UI

### Problem

The MVP CLI is the only path to write predictions. The operator's most natural moment to record a belief is *while looking at the chain in the dashboard* — switching to a terminal breaks the flow.

### Design

One new POST route, one new form on the KB Theses page.

**Route:** `POST /api/kb/theses/{id}/predict`

Request body (JSON):
```json
{"confidence_bp": 7200, "rationale": "expecting hold after CPI print"}
```

Response: the standard `{success, data, timestamp}` envelope, where `data` is the new chain entry (tx_id, hash, payload).

The handler builds the canonical-JSON payload with the same key ordering as `praescientia-kb predict`, then calls `kb.predict.writePrediction` (the library helper that ships in the MVP plan). No new ingest path.

**UI:** extend the existing KB Theses page (built in the KB follow-ups plan). Add a row:

- "Confidence (bp)" number input, range `[1, 10000]`
- "Rationale" text input, optional
- "Predict" button → POST to `/api/kb/theses/{id}/predict`
- Response is appended below the existing output `<pre>` to keep a session-local history of what was just written

### Auth posture

Per the decision in the prior turn: localhost-only, no auth. Concretely:

- Default bind address changes from `0.0.0.0` to `127.0.0.1` *when* `--kb-root` is set (the only way to enable write routes). `--bind=0.0.0.0` opt-out for the operator who actually wants network access — at which point they accept the consequences and presumably wrap with their own auth layer.
- No `X-Write-Token` header logic. If we ever need it, this is the seam to add it on.

### Implementation strategy

Two tasks:

- **7.1 — `POST /api/kb/theses/{id}/predict` route + handler.** Body parsing reuses the pattern from `ordersCreate` in `server/handlers.zig`. Validate `confidence_bp ∈ [1, 10000]` server-side; return 400 with `{success:false, error:...}` on bad input. Idempotency-key support is YAGNI for v1; if the operator double-clicks, they get two prediction entries with different `tx_id`s. Acceptable.
- **7.2 — Predict form on the dashboard KB Theses page.** Inline JS, no new files. Style with existing CSS tokens (`bg-input`, `text-primary`, `btn-primary`). Embed-test in `handlers.zig` asserts the form markers (`id="kb-thesis-predict"`, `/api/kb/theses/`, `predict`) appear.

Bind-address change is a third small task:

- **7.3 — Default-localhost when `--kb-root` is set.** One-line change in `server/main.zig`'s argv parser. Banner already prints the bind address; just make the default conditional.

### Risk

The bind-address change is the only thing here that affects existing deployments. Document it in the PR description and the README's server section.

### Test strategy

- Inline test for the body parser (malformed JSON → 400; out-of-range confidence_bp → 400; happy path → 200 + chain length grew).
- Embed-test for the form markers.
- Hand-smoke: open the dashboard, click Predict, verify the chain via CLI.

---

## §8. Daemon mode

### Problem

The MVP poller is a one-shot. Operators wrap it in a shell loop. That's fine; it's also a perpetual minor annoyance because shell loops swallow errors, can't be hot-reloaded, and don't give you a clean signal handling story.

### Design

Add `--loop=<duration>` to `praescientia-poll-markets`. Duration is a Go-style suffixed string: `30s`, `5m`, `1h`. With the flag set, the binary becomes a `while (true) { pollAll(); sleep(duration); }` loop. Without it, behavior is unchanged.

Signal handling: SIGINT exits cleanly at the top of the next iteration (no abrupt cancellation mid-poll). SIGTERM is the same. Use `std.os.linux.sigaction` (or whatever's portable in 0.16) to wire a flag the loop checks.

Logging: the existing summary line per iteration becomes the heartbeat. Add an ISO-8601 timestamp prefix. No log rotation — that's the operator's problem; they can `>> /var/log/...` and use logrotate.

### Implementation strategy

Three small tasks:

- **8.1 — Parse `--loop=<duration>` into a nanosecond `u64`.** Inline test for `30s`, `5m`, `1h`, and the error cases (`30x`, `-1s`, empty). Library function in `src/duration.zig` (or attached to `tools/common.zig` — TBD; the function is small enough that placement doesn't matter much).
- **8.2 — Sleep + signal handling in `pollAll`'s caller.** A `runLoop(ctx, kb_root, interval_ns) !void` wrapper that calls `pollAll`, sleeps via `std.Io.sleepUntil` or equivalent, checks the signal flag, repeats.
- **8.3 — Documentation.** README gets a "Running as a service" subsection with a sample systemd unit and a sample launchd plist. No production hardening (no privilege drop, no resource limits) — operators tune for their environment.

### Risk

The shell-loop workaround is genuinely fine. The risk is shipping this prematurely — `--loop` adds a code path that has to be tested against `kill -INT` and `kill -TERM`, and most operators in the demo phase are going to drive the poller from cron or `tmux`. Recommended to defer until §6 and §7 are in production and the operator says *"OK now this shell-loop pattern is annoying."*

### Test strategy

- Inline test for the duration parser.
- Hand-smoke: `--loop=2s` for 10 seconds, verify ~5 iterations, SIGINT during sleep exits in <2s.

---

## Recommended sequencing

1. Ship the MVP (`2026-05-18-kalshi-demo-loop-implementation.md`).
2. Live with it for a day or two against the demo API. Note which gaps actually bite.
3. **§6 next** if any of your tracked markets are about to resolve. Otherwise it can wait until one does.
4. **§7 second.** Pure operator-experience win.
5. **§8 last.** Or never, if the shell loop holds up.

Each is a single virtual branch / single PR. Total scope is maybe 10–15 commits if all three ship.

# Talmud Commentary — Design

> Layered AI commentary on the KB, structured like the Talmud. The reality chain is the inner text; commentary surrounds it. A LanceDB vector index serves cross-context retrieval — the AI's "other factors influencing current events" lens. The chain is canonical; the index is disposable and regeneratable.

## Context

The KB substrate already supports per-market and per-thesis chains for reality (Kalshi observations) and prediction (author beliefs). What's missing is a place for *commentary* — the agent's freeform prose about why a market is moving, what macro signals it's reading, how today's reading relates to last week's. A vector index over commentary lets the agent ask "what *else* in this knowledge base bears on this situation?" — lateral recall, not vertical evidence about the current thesis.

The substrate decision is the chain. Vector search is an access pattern, not the source of truth. Embeddings can be regenerated from the chain at any time; the chain cannot be regenerated from embeddings.

## Goals

- **Commentary is a first-class chain type** alongside reality and prediction. Same `txlog` integrity, same branch model, same `kb init` admission flow.
- **Lateral retrieval, not vertical.** Vector search returns commentary *outside* the active thesis — cross-thesis pattern recognition, prior macro observations, structurally similar resolved markets. Within the active thesis, the agent reads the chain directly.
- **Index is disposable.** `rm -rf .commentary_index && restart indexer` rebuilds from chain bodies. Embedding model swaps are a re-index, not a data migration.

## Decision summary

| Area | Choice |
|---|---|
| Storage | New chain type at three scopes: `theses/<id>/commentary/`, `markets/<TICKER>/commentary/`, `commentary/global/` |
| Vector store | LanceDB, file-based at `<kb_root>/.commentary_index/lance/` |
| Embedding model | BGE-M3 (1024-dim dense), quantized GGUF |
| Embedding service | `llama-server --embeddings` daemon, long-lived |
| Indexer | Python script at `tools/index_commentary.py`, batch-mode, default 60s interval |
| Retrieval shape | Hash-anchor only for v1 (`POST /api/kb/commentary/similar` with `anchor_hash`) |
| Auth | Localhost-only for write routes, matching the prediction-write convention |
| `portfolios/` migration | N/A — out of scope, same as the original KB plan |

---

## §1. Storage layout & commentary chain shape

Commentary lives as a new chain type alongside `reality/` and `prediction/`. Three scopes:

- `theses/<id>/commentary/main.jsonl` — observations tied to a specific thesis (most common)
- `markets/<TICKER>/commentary/main.jsonl` — observations about a specific market
- `commentary/global/main.jsonl` — macro observations not tied to any one market or thesis

Each scope uses the existing `txlog` machinery: append-only, hash-chained, branchable, recoverable from torn writes. Same `branches.json` + `<branch>.jsonl` shape as the other chain types. `kb init` materializes the thesis and market commentary subdirectories at admission time alongside `reality/` and `prediction/`; the global path is created on first use.

Commentary payload schema (canonical-JSON, alphabetical keys):

```json
{
  "agent":       {"model": "claude-opus-4-7", "version": "...", "run_id": "..."},
  "body":        "Free-form prose. Capped at 16 KB; longer commentary chains via parent_hash.",
  "inputs":      {"market_set_heads": ["hash", "..."], "prediction_head": "hash"},
  "kind":        "commentary",
  "parent_hash": "hash-of-prior-commentary-or-null",
  "references":  ["hash1", "hash2", "..."],
  "tags":        ["macro", "fed-policy"],
  "ts":          1779148461139
}
```

Three fields earn their inclusion:

- **`references`** — chain hashes (reality, prediction, or prior commentary) this entry is *about*. Makes the Talmud structure addressable: each commentary points at the text it interprets.
- **`parent_hash`** — threading dimension. A reply-to commentary. Lets you walk a discussion chain backwards.
- **`inputs`** — broader set of chain hashes the agent looked at while reasoning, even if not formally commenting on them. Lets future readers replay the agent's view.

`tags` is freeform short strings (≤8 per entry, ≤32 chars each) for grep-friendly retrieval before the vector index catches up.

---

## §2. Embedding service & indexer

`llama-server` runs as a long-lived daemon:

```
llama-server --embeddings -m bge-m3-Q4_K_M.gguf --port 8001 --ctx-size 8192
```

Quantized to Q4_K_M (~600 MB on disk, ~700 MB RAM). 1024-dim output. Started via a systemd unit (Linux) or launchd plist (macOS); the operator manages it like any daemon. Praescientia binaries don't bring it up — it's expected to be running. If it isn't, the indexer logs and retries; commentary lands in the chain regardless.

**Indexer**: a small Python script at `tools/index_commentary.py`. (Python because LanceDB's idiomatic surface is Python; idiomatic Zig FFI into LanceDB is not a fight worth picking.) Lifecycle:

```
loop forever:
  for each scope in (theses/*/commentary, markets/*/commentary, commentary/global):
    head = last_indexed_hash_for(scope)
    new_entries = chain.entries_since(head)
    if new_entries:
      bodies  = [e.payload.body for e in new_entries]
      vectors = POST /embedding with {"input": bodies}    # one call, batch of N
      lance.add([(e.hash, v, e.scope_path, e.agent.run_id, e.tags, e.ts)
                 for e, v in zip(new_entries, vectors)])
      cursor.write(scope, new_entries[-1].hash)
  sleep(interval_seconds)
```

Cursor state — `last indexed hash per scope` — lives at `<kb_root>/.commentary_index/cursors.json`, owned by the indexer. Hash chains are append-only so the cursor is enough; on restart the indexer resumes from the recorded hash.

**Failure semantics**: if `llama-server` is down, the indexer's HTTP call fails, the cursor doesn't advance, the loop sleeps and retries. Entries pile up in the chain but stay unvectored until the service comes back. Vector search returns whatever's indexed; querying for a still-unindexed entry by hash returns no neighbors — not an error, just an honest "I don't have an embedding for that yet."

**Reindex** is `rm -rf <kb_root>/.commentary_index && restart indexer`. The chain is the source of truth; the index is disposable.

Default interval: **60 seconds**. Commentary is human/AI-paced, not real-time, so a one-minute lag from "written" to "queryable" is fine. Operator can knock it down to 10s for development.

---

## §3. LanceDB schema & retrieval API

Lance table at `<kb_root>/.commentary_index/lance/commentary.lance`. One row per commentary entry:

| column         | type                              | source                                              |
|----------------|-----------------------------------|-----------------------------------------------------|
| `hash`         | `string` (de facto primary key)   | chain entry hash                                    |
| `vector`       | `fixed_size_list<float32, 1024>`  | BGE-M3 output                                       |
| `scope_path`   | `string`                          | e.g. `theses/fed-jun`, `markets/KXBTC-26`, `global` |
| `agent_run_id` | `string`                          | from payload `agent.run_id`                         |
| `tags`         | `list<string>`                    | from payload `tags`                                 |
| `ts`           | `int64`                           | from payload `ts`                                   |

LanceDB doesn't enforce primary-key uniqueness, so the indexer must not double-insert (cursor logic handles this). An IVF-PQ index on `vector` is built once the table exceeds ~10K rows; below that, brute-force scan is fast enough that the index overhead is wasted. Indexer triggers `lance.create_index()` when the row count crosses the threshold.

**Retrieval route** on the dashboard server: `POST /api/kb/commentary/similar`

Request:
```json
{
  "anchor_hash":    "d6737617...",
  "limit":          10,
  "exclude_scopes": ["theses/fed-jun"],
  "min_ts":         1779000000000
}
```

Response: the standard `{success, data, timestamp}` envelope where `data` is a ranked list of `{hash, scope_path, score, ts, tags}`. The client looks up canonical text from the chain by hash — server doesn't bundle bodies (keeps the route cheap and gives the agent control over how much text to actually load).

**Hash-anchor only for v1.** The agent's loop is: "I'm reasoning about thesis X, I just wrote commentary entry H. Show me cross-context recall — what other entries in the kb are similar to H, excluding entries within thesis X?" The server SELECTs H's vector from Lance and runs a k-NN query. No model invocation at query time.

Text-anchor — "embed this query string and find similar" — is a v2 feature. When added, the same `llama-server` answers; the route gains an `anchor_text` field; everything else stays the same.

`min_ts` is the cheap freshness filter — operator says "only commentary newer than X." `exclude_scopes` is the lateral-recall enforcer; without it the route would happily return commentary on the active thesis, defeating the point.

---

## §4. CLI + HTTP write surface

### CLI

Three new `praescientia-kb` subcommands:

```
praescientia-kb commentary write \
    (--thesis=ID | --market=TICKER | --global) \
    --agent-model=NAME [--agent-run-id=...] \
    [--body="..." | --body-file=PATH | stdin] \
    [--references=hash1,hash2,...] \
    [--parent-hash=...] \
    [--inputs-prediction-head=...] \
    [--inputs-market-set-heads=hash,hash,...] \
    [--tags=tag1,tag2,...] \
    [--kb-root=./kb]

praescientia-kb commentary list (--thesis=ID | --market=TICKER | --global) [--limit=N]
praescientia-kb commentary show <hash>
```

Exactly one of `--thesis|--market|--global` is required. Body source is one of three: inline flag, file, or stdin (in that priority order). References and `parent_hash` validated as 64-char hex; tags against the ≤8 entries / ≤32 chars/each rule.

`--agent-model` is **required**. An operator writing commentary by hand passes `--agent-model=human` (or whatever — the field is freeform). The point is to refuse to silently default. Human-vs-AI attribution is what makes calibration metrics possible later.

On success, `write` prints minimal JSON to stdout — `{"hash":"...","scope":"theses/fed-jun"}` — so an agent driver can parse and chain.

### HTTP

Three scope-specific write routes on the dashboard server, available when `--kb-root` is set (same gate as the existing KB routes):

```
POST /api/kb/theses/{id}/commentary
POST /api/kb/markets/{ticker}/commentary
POST /api/kb/commentary/global
```

Request body is JSON, same shape as the CLI flags translated into fields (`agent`, `body`, `references`, `parent_hash`, `inputs`, `tags`). Server fills in `kind: "commentary"` and `ts`, validates, writes to the chain, returns the standard `{success, data:{hash, scope_path}, timestamp}` envelope. Body length cap (16 KB) enforced server-side too — 413 on oversize.

Auth posture matches the prediction-write route designed in `2026-05-18-kalshi-demo-loop-polish-strategy.md` §7: localhost-only by default. The same `127.0.0.1`-when-`--kb-root`-set policy applies.

CLI and HTTP both write to the same chain primitives. CLI is the natural surface for shell scripts and operator typing; HTTP is the natural surface for AI drivers that maintain a session against the dashboard.

---

## §5. Test strategy

- **Schema + validation** — inline Zig tests in `src/kb/commentary.zig` (or whichever file owns the payload builder). Reject: missing required fields, oversize body, tags exceeding count/length caps, references that don't parse as hex, `parent_hash` referencing a non-existent entry on the same chain.
- **Three-scope path resolution** — given `--thesis=ID` vs `--market=TICKER` vs `--global`, the right chain dir is opened/created. Existing `kb init` tests gain a small extension asserting commentary subdirs land alongside `reality/`/`prediction/`.
- **CLI** — `write` happy path plus each rejection rule; `list` returns entries in chain order; `show <hash>` finds entries by hash anywhere across the three scopes.
- **HTTP** — route-match tests for the three write routes and the `/similar` retrieval route, mirroring `server/handlers.zig`. Body-parser tests (malformed JSON → 400; oversize body → 413; happy path → 200 + chain grew).
- **End-to-end smoke** — `scripts/commentary_smoke.sh` writes a few entries, invokes the Python indexer in one-shot mode (`--once`), queries `/similar`, asserts the response is well-formed. Companion to `scripts/demo_loop_smoke.sh`.

Indexer Python tests live at `tools/indexer/test_indexer.py` (pytest), run in CI but not part of `zig build test`.

---

## Deferred (out of scope for v1)

- **Text-anchor retrieval** — `/similar` accepts only `anchor_hash` in v1. Embedding query text at retrieval time needs the same `llama-server`, just a different request shape. Add an `anchor_text` field when needed.
- **Tag-based retrieval as a dedicated index** — grep the chain files for v1. A real tag index is a v2 feature once tag patterns emerge.
- **Multi-vector / colbert mode** — pure dense for v1. BGE-M3 supports more but the simpler shape is honest about what we'd test.
- **Supersede / deprecate relationships** — "this commentary corrects that older commentary." `parent_hash` already carries the thread; a dedicated flag is YAGNI until a concrete need arises.
- **Per-agent quotas** — v1 trusts the agent. Rate limiting / cost caps are a v2 concern once a runaway loop has a shape.
- **`portfolios/` migration** — same disposition as the original KB plan: dropped from scope, no producers exist.

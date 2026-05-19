# Talmud Commentary Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Ship the commentary chain type, CLI + HTTP write surfaces, Python indexer + query service, and the dashboard retrieval proxy. Companion design at `docs/plans/2026-05-18-talmud-commentary-design.md`.

**Architecture:** New Zig module `src/kb/commentary.zig` for schema and chain dispatch. CLI grows three subcommands on `tools/kb.zig`. Server grows three write routes plus a proxying retrieval route. A new Python service at `tools/indexer/` handles embedding (via `llama-server`), LanceDB indexing, and retrieval queries — single process, two roles. End-to-end smoke at `scripts/commentary_smoke.sh`.

**Tech Stack:** Zig 0.16.0 (existing). Python 3.11+ with `lancedb`, `httpx`, and `fastapi` (new). `llama-server` from `llama.cpp` with BGE-M3 GGUF (operator-managed). GitButler MCP for all commits.

---

## Conventions

### Zig 0.16 reminders (carried from prior plans)

- `Dir.createDir` takes a `Permissions` enum — use `.default_dir`, not `.{}`.
- `Dir.createDirPath` is the recursive variant.
- `chain.openRead` / `openForWrite` are 4-arg: `(allocator, io, dir, branch)`.
- `std.array_list.Managed(u8).writer()` does not compose with `*std.Io.Writer`; use `std.Io.Writer.Allocating` and pass `aw.written()` as bytes.
- For enum cardinality, use `@typeInfo(E).@"enum".fields.len`.
- Module-level `StringHashMapUnmanaged` must be reset to `.empty` at the start of every test that touches it; `deinit` leaves it `undefined`.

### Test command

`zig build test --summary all`. Should be 151/151 at plan start. Python tests live at `tools/indexer/test_indexer.py` and run via `pytest`; not part of `zig build test`.

### TDD cycle per Zig task

1. Write the failing test.
2. Run; expect compile error or runtime fail.
3. Implement minimal code.
4. Re-run; expect green.
5. Commit via GitButler.

### Python TDD cycle

`pytest tools/indexer/` per task. Same red-green-commit shape.

### Commit via GitButler — never `git commit`

```
Call mcp__gitbutler__gitbutler_update_branches with:
  fullPrompt:             <copy of the task title>
  changesSummary:         <2-4 bullets: what changed and why>
  currentWorkingDirectory: /Users/lawls/Development/TuesdayCrowd/Praescientia
```

After the first commit on a fresh branch, **run `but branch new <name> && but mark <name>` in one Bash call** so the post-tool hook can't spawn a parallel `cd-branch-N` stub.

### Editing rules

- Inline Zig tests only; reuse `std.testing.allocator`.
- Canonical-JSON payloads have alphabetically-sorted keys.
- No floats in hashed payload fields.
- Python files use `ruff format` defaults; tests use plain `pytest`, no fixtures library beyond stdlib + `tmp_path`.

---

## Stage 1 — Commentary chain primitives

**Deliverable:** `src/kb/commentary.zig` exports `CommentaryPayload`, `writeCommentary(allocator, io, kb_root, scope, payload)`, and validation helpers. Three-scope path resolution (thesis/market/global) lands. `kb init` materializes commentary subdirs.

### Task 1.1 — `CommentaryPayload` schema + canonical encoder

**Files:**
- Create: `src/kb/commentary.zig`
- Modify: `src/root.zig` (add `pub const commentary = @import("kb/commentary.zig");` + `_ = kb.commentary;` in root test block)

**Step 1: Failing test** in `src/kb/commentary.zig`:

```zig
test "encodePayload produces canonical alphabetically-sorted JSON" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try encodePayload(&aw.writer, .{
        .agent = .{ .model = "claude-opus-4-7", .run_id = "abc" },
        .body = "test body",
        .references = &.{},
        .parent_hash = null,
        .inputs = .{},
        .tags = &.{},
        .ts_ms = 1779000000000,
    });
    const out = aw.written();
    // Keys: agent, body, inputs, kind, parent_hash, references, tags, ts
    try std.testing.expect(std.mem.indexOf(u8, out, "\"agent\":{\"model\":\"claude-opus-4-7\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"kind\":\"commentary\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"parent_hash\":null") != null);
}
```

**Step 2: Run.** Expected: `encodePayload` undeclared → compile error.

**Step 3: Implement** the `CommentaryPayload` struct and `encodePayload(writer, payload) !void` function. Keys alphabetical: `agent`, `body`, `inputs`, `kind`, `parent_hash`, `references`, `tags`, `ts`. `parent_hash` and `inputs` fields are nullable; encoder emits `null` when absent.

**Step 4: Run.** Expected: green.

**Step 5: Commit.** `fullPrompt`: "Stage 1 Task 1.1 — CommentaryPayload schema + encoder".

### Task 1.2 — Validation: body cap, tag cap, hash format, parent_hash existence

**Files:**
- Modify: `src/kb/commentary.zig`

**Step 1: Failing tests** for each rule:

```zig
test "validatePayload rejects body over 16 KB" { ... }
test "validatePayload rejects more than 8 tags" { ... }
test "validatePayload rejects tag longer than 32 chars" { ... }
test "validatePayload rejects references that aren't 64-char hex" { ... }
test "validatePayload rejects empty agent.model" { ... }
```

**Step 2: Run.** Expected: `validatePayload` undeclared.

**Step 3: Implement** `validatePayload(*const CommentaryPayload) !void` with distinct error names per rule (`error.BodyTooLong`, `error.TooManyTags`, `error.TagTooLong`, `error.InvalidHashFormat`, `error.MissingAgentModel`).

`parent_hash` existence is *not* validated here — that's a chain-level check done in `writeCommentary` (Task 1.4), since validating it requires opening the chain.

**Step 4: Run.** Expected: green.

**Step 5: Commit.** `fullPrompt`: "Stage 1 Task 1.2 — Commentary payload validation".

### Task 1.3 — Scope path resolution

**Files:**
- Modify: `src/kb/commentary.zig`

**Step 1: Failing test:**

```zig
test "scopeRelativePath maps each scope to the right chain dir" {
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings(
        "theses/fed-jun/commentary",
        try scopeRelativePath(&buf, .{ .thesis = "fed-jun" }),
    );
    try std.testing.expectEqualStrings(
        "markets/KXBTC-26/commentary",
        try scopeRelativePath(&buf, .{ .market = "KXBTC-26" }),
    );
    try std.testing.expectEqualStrings(
        "commentary/global",
        try scopeRelativePath(&buf, .global),
    );
}
```

**Step 2: Run.** Compile error.

**Step 3: Implement** the `Scope` tagged union (`thesis: []const u8`, `market: []const u8`, `global`) and `scopeRelativePath(buf, scope) ![]const u8`. Reuses `validateMarket`/`validateThesis`-style charset rules for the ID/ticker components.

**Step 4: Run.** Green.

**Step 5: Commit.** `fullPrompt`: "Stage 1 Task 1.3 — Commentary scope path resolution".

### Task 1.4 — `writeCommentary(allocator, io, kb_root, scope, payload)`

**Files:**
- Modify: `src/kb/commentary.zig`

**Step 1: Failing test:**

```zig
test "writeCommentary appends to the right chain and returns the hash" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try @import("init.zig").initTree(io, tmp.dir, true); // creates SAMPLE market + sample thesis

    const result = try writeCommentary(std.testing.allocator, io, tmp.dir, .{ .thesis = "sample" }, .{
        .agent = .{ .model = "claude-opus-4-7", .run_id = "test" },
        .body = "first observation",
        .references = &.{},
        .parent_hash = null,
        .inputs = .{},
        .tags = &.{ "macro" },
        .ts_ms = 1779000000000,
    });

    var chain = try @import("chain.zig").openRead(
        std.testing.allocator, io,
        try tmp.dir.openDir(io, "theses/sample/commentary", .{ .iterate = false }),
        "main",
    );
    defer chain.deinit();
    try std.testing.expectEqual(@as(usize, 1), chain.len());
    try std.testing.expectEqualSlices(u8, &chain.head().?, &result.hash);
}
```

**Step 2: Run.** Compile error.

**Step 3: Implement** `writeCommentary` that:
- Validates the payload via `validatePayload`.
- Resolves the scope to a path; opens the chain dir.
- If `parent_hash` is non-null, loads the chain and verifies the hash exists on the active branch — `error.ParentHashNotFound` otherwise.
- Builds the canonical-JSON payload via `encodePayload`.
- Appends to the chain via the existing `chain.WriteHandle.append`.
- Returns `{ hash: Hash, scope_path: []const u8 }`.

**Step 4: Run.** Green.

**Step 5: Commit.** `fullPrompt`: "Stage 1 Task 1.4 — writeCommentary".

### Task 1.5 — Materialize commentary subdirs in `addMarket` and `addThesis`

**Files:**
- Modify: `src/kb/init.zig`

**Step 1: Failing test** in `init.zig`:

```zig
test "addMarket creates a commentary subdir" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try initTree(io, tmp.dir, false);
    try addMarket(io, tmp.dir, "KXBTC", 1);
    try tmp.dir.access(io, "markets/KXBTC/commentary/main.jsonl", .{});
    try tmp.dir.access(io, "markets/KXBTC/commentary/branches.json", .{});
}
test "addThesis creates a commentary subdir" { /* analogous */ }
```

**Step 2: Run.** Failure: `error.FileNotFound`.

**Step 3: Implement.** In `addMarket`, after creating `reality/`, also create `commentary/` with the same empty-jsonl + genesis-branches.json shape. Same in `addThesis` after `reality/` and `prediction/`.

**Step 4: Run.** Green.

**Step 5: Commit.** `fullPrompt`: "Stage 1 Task 1.5 — Materialize commentary subdirs on admission".

**Stage 1 exit gate:** `zig build test --summary all` green. Commentary chain type is a first-class peer of reality and prediction.

---

## Stage 2 — `kb commentary` CLI subcommands

### Task 2.1 — `praescientia-kb commentary write`

**Files:**
- Modify: `tools/kb.zig`

**Step 1:** Add the subcommand to the dispatch list. Handler reads:
- One of `--thesis=ID | --market=TICKER | --global` (exactly one)
- `--agent-model=NAME` (required), optional `--agent-run-id=...`
- Body from `--body=...` flag, `--body-file=PATH`, or stdin (priority order)
- Optional `--references=hash,hash`, `--parent-hash=...`, `--inputs-prediction-head=...`, `--inputs-market-set-heads=hash,hash`, `--tags=tag,tag`
- `--kb-root=./kb` (default)

Calls `commentary.writeCommentary`. On success prints `{"hash":"...","scope":"..."}` to stdout.

**Step 2: Hand-smoke** with `praescientia-kb init`, then write a commentary, then `cat` the chain file.

**Step 3: Commit.** `fullPrompt`: "Stage 2 Task 2.1 — kb commentary write CLI".

### Task 2.2 — `praescientia-kb commentary list` + `show`

**Files:**
- Modify: `tools/kb.zig`

**Step 1:** Add `list` and `show` subcommands.

- `list` takes the same scope flag as `write`, plus `--limit=N` (default 10). Iterates the chain tail and prints one row per entry: hash[0..12], ts, agent.model, body[0..80] (truncated).
- `show <hash>` searches all commentary chains under `kb_root` (theses, markets, global) for the given hash and prints the full canonical payload pretty-printed.

**Step 2: Hand-smoke** by writing two entries on a scope and running `list` + `show <hash>`.

**Step 3: Commit.** `fullPrompt`: "Stage 2 Task 2.2 — kb commentary list + show CLI".

**Stage 2 exit gate:** Operators can write/list/show commentary entries without hand-editing JSON.

---

## Stage 3 — HTTP write routes

### Task 3.1 — Three scope-specific POST routes + handler

**Files:**
- Modify: `server/handlers.zig`

**Step 1: Failing test:**

```zig
test "match: commentary write routes are wired up" {
    var params: [max_path_params][]const u8 = undefined;
    const thesis = match(.POST, "/api/kb/theses/fed-jun/commentary", &params).?;
    try std.testing.expectEqualStrings("/api/kb/theses/{id}/commentary", thesis.route.pattern);
    const market = match(.POST, "/api/kb/markets/KXBTC/commentary", &params).?;
    try std.testing.expectEqualStrings("/api/kb/markets/{ticker}/commentary", market.route.pattern);
    const global = match(.POST, "/api/kb/commentary/global", &params).?;
    try std.testing.expectEqualStrings("/api/kb/commentary/global", global.route.pattern);
}
```

**Step 2: Run.** Expected: `.?` panic — no such routes yet.

**Step 3: Implement** three new route entries + three handlers. Each handler:
- Reads the request body (size-capped at 16 KB on the wire; 413 if over).
- Parses JSON into a `CommentaryPayload`-shaped intermediate.
- Calls `commentary.writeCommentary` with the right `Scope`.
- Returns `{success:true, data:{hash:"...", scope_path:"..."}, timestamp:...}` on success, or `{success:false, error:"..."}` with a sensible HTTP status on validation failure.

Auth: gate on `kb_root_path != null` (same gate as the existing KB read routes). Return 503 with the standard "kb_root is not configured" message otherwise.

**Step 4: Run** — green.

**Step 5: Commit.** `fullPrompt`: "Stage 3 Task 3.1 — Commentary HTTP write routes".

**Stage 3 exit gate:** `curl -X POST http://localhost:8080/api/kb/theses/sample/commentary` against a running server with `--kb-root=PATH` writes to the chain and returns the new hash.

---

## Stage 4 — Python indexer + query service

### Task 4.1 — Scaffolding + chain tail reader

**Files:**
- Create: `tools/indexer/index_commentary.py`
- Create: `tools/indexer/pyproject.toml` (uv/pip-compat)
- Create: `tools/indexer/test_indexer.py`

**Step 1: Failing test** in `test_indexer.py`:

```python
def test_tail_returns_entries_after_cursor(tmp_path):
    # Write a fake JSONL chain with three entries.
    chain_dir = tmp_path / "theses" / "sample" / "commentary"
    chain_dir.mkdir(parents=True)
    (chain_dir / "main.jsonl").write_text("\n".join([
        json.dumps({"tx_id": "tx_a", "prev_hash": "0" * 64, "hash": "a" * 64, "payload": {"body": "1"}}),
        json.dumps({"tx_id": "tx_b", "prev_hash": "a" * 64, "hash": "b" * 64, "payload": {"body": "2"}}),
        json.dumps({"tx_id": "tx_c", "prev_hash": "b" * 64, "hash": "c" * 64, "payload": {"body": "3"}}),
    ]) + "\n")
    entries = list(tail(chain_dir / "main.jsonl", after_hash="a" * 64))
    assert [e["hash"] for e in entries] == ["b" * 64, "c" * 64]
```

**Step 2: Implement** `tail(jsonl_path, after_hash) -> Iterator[dict]` and supporting line parser. Treat truncated final lines (no trailing newline) as torn writes — skip them (the Zig side handles recovery; the indexer just observes the safe prefix).

**Step 3:** Commit. `fullPrompt`: "Stage 4 Task 4.1 — Indexer chain tail reader".

### Task 4.2 — Cursor file management

**Files:**
- Modify: `tools/indexer/index_commentary.py`
- Modify: `tools/indexer/test_indexer.py`

**Step 1: Failing tests** for `Cursors.read` (missing file → empty), `Cursors.write` (write + reread), and the per-scope key shape (`"theses/sample/commentary"`).

**Step 2: Implement** a small `Cursors` class backed by `<kb_root>/.commentary_index/cursors.json`. Atomic write via temp-file-rename.

**Step 3:** Commit. `fullPrompt`: "Stage 4 Task 4.2 — Indexer cursor persistence".

### Task 4.3 — llama-server embedding client + batch

**Files:**
- Modify: `tools/indexer/index_commentary.py`
- Modify: `tools/indexer/test_indexer.py`

**Step 1: Failing test** with a mocked `httpx` POST that returns `[[0.0]*1024, [1.0]*1024]` for a two-item batch input.

**Step 2: Implement** `embed_batch(texts: list[str]) -> list[list[float]]` that POSTs to `http://localhost:8001/embedding` with `{"input": texts}` and parses the response shape. Tolerates connection errors by raising `EmbedderUnavailable`; caller decides whether to back off.

**Step 3:** Commit. `fullPrompt`: "Stage 4 Task 4.3 — Indexer llama-server client".

### Task 4.4 — LanceDB writes

**Files:**
- Modify: `tools/indexer/index_commentary.py`
- Modify: `tools/indexer/test_indexer.py`

**Step 1: Failing test** that creates a `lance` table in `tmp_path`, calls `insert_rows(table, rows)`, then queries the table back and asserts row count + first vector.

**Step 2: Implement** the LanceDB schema declaration and `insert_rows`. Schema columns per the design doc (`hash`, `vector`, `scope_path`, `agent_run_id`, `tags`, `ts`). Use `pyarrow` for the schema definition; LanceDB accepts pyarrow tables directly.

**Step 3:** Commit. `fullPrompt`: "Stage 4 Task 4.4 — Indexer LanceDB writes".

### Task 4.5 — Wire the loop: scan → embed → insert → advance cursor

**Files:**
- Modify: `tools/indexer/index_commentary.py`
- Modify: `tools/indexer/test_indexer.py`

**Step 1: Failing test** (integration-style, in-process): seed `kb_root`, monkey-patch `embed_batch` to return deterministic vectors, run `run_once(kb_root)`, assert (a) Lance table has the expected rows, (b) cursor file advanced to the chain head.

**Step 2: Implement** `run_once(kb_root, lance_uri, embedder)` and `run_loop(kb_root, lance_uri, embedder, interval_seconds)`. CLI entry takes `--kb-root`, `--llama-url` (default `http://localhost:8001`), `--lance-dir` (default `<kb_root>/.commentary_index/lance`), `--once` (single iteration then exit), `--interval=60`.

**Step 3:** Commit. `fullPrompt`: "Stage 4 Task 4.5 — Indexer main loop".

### Task 4.6 — Query service: `POST /similar`

**Files:**
- Modify: `tools/indexer/index_commentary.py`
- Modify: `tools/indexer/test_indexer.py`

**Step 1: Failing test:** seed a Lance table with three rows in different scopes, start the FastAPI app via `TestClient`, POST `{"anchor_hash": "...", "limit": 2, "exclude_scopes": ["theses/sample"]}`, assert response shape + scope filter applied.

**Step 2: Implement** a minimal FastAPI app inside the same process. Routes:
- `POST /similar` with `{anchor_hash, limit, exclude_scopes, min_ts}` — looks up the anchor's vector in Lance, runs k-NN, applies filters, returns ranked list of `{hash, scope_path, score, ts, tags}`.
- `GET /health` returns `{"status": "ok", "indexed_rows": N}`.

The indexer's main loop and the FastAPI app share the same Lance handle. Default port 8002; configurable via `--query-port`.

**Step 3:** Commit. `fullPrompt`: "Stage 4 Task 4.6 — Indexer query service".

**Stage 4 exit gate:** `pytest tools/indexer/` green. `python tools/indexer/index_commentary.py --kb-root=./kb --once` indexes any pending commentary and exits. `curl http://localhost:8002/health` returns the indexed row count.

---

## Stage 5 — Dashboard proxy for `/api/kb/commentary/similar`

### Task 5.1 — Proxy route

**Files:**
- Modify: `server/handlers.zig`
- Modify: `server/main.zig` (new flag `--commentary-query-url=`)

**Step 1: Failing route-match test** for `POST /api/kb/commentary/similar`.

**Step 2: Implement** a handler that:
- Returns 503 if `ctx.commentary_query_url` is null.
- Otherwise reads the request body, POSTs it verbatim to `<commentary_query_url>/similar`, copies the response body and status back to the dashboard client.

This is a thin pass-through; the dashboard server doesn't parse the request or response, just forwards bytes. Means the wire shape is defined once (in the Python service) and the Zig side never needs to know LanceDB's data model.

**Step 3:** Commit. `fullPrompt`: "Stage 5 Task 5.1 — Commentary retrieval proxy".

**Stage 5 exit gate:** With both `praescientia-server --kb-root=PATH --commentary-query-url=http://localhost:8002` and `python tools/indexer/index_commentary.py` running, `curl -X POST http://localhost:8080/api/kb/commentary/similar -d '{"anchor_hash":"...", "limit":5}'` returns ranked results.

---

## Stage 6 — End-to-end smoke + docs

### Task 6.1 — `scripts/commentary_smoke.sh`

**Files:**
- Create: `scripts/commentary_smoke.sh`

**Step 1:** Write a script that:
1. Verifies prerequisites (zig-out binaries exist, `llama-server` is reachable on 8001, Python deps installed).
2. Creates a tmp kb_root, runs `kb init --with-sample`.
3. Writes three commentary entries on the sample thesis via the CLI.
4. Runs `python tools/indexer/index_commentary.py --kb-root=$TMPKB --once`.
5. Asserts Lance directory exists and has rows.
6. Starts the dashboard server with `--commentary-query-url=http://localhost:8002`, starts the indexer in query-service-only mode, POSTs `/api/kb/commentary/similar` with one of the just-written hashes.
7. Asserts the response is well-formed and has at least one neighbor (the other two entries we wrote).
8. Tears down processes.

**Step 2:** Hand-run the script. Iterate until clean.

**Step 3:** Commit. `fullPrompt`: "Stage 6 Task 6.1 — commentary_smoke.sh".

### Task 6.2 — Documentation

**Files:**
- Modify: `README.md`
- Modify: `CLAUDE.md`

**Step 1:** Add a "Commentary" section to README under the existing "Knowledge Base" section, explaining the chain layout, the operator workflow (write → indexer picks up → query similar), and the `llama-server` requirement. Add a CLI table row for `praescientia-kb commentary`. Update CLAUDE.md project structure tree to include `src/kb/commentary.zig` and `tools/indexer/`.

**Step 2:** Commit. `fullPrompt`: "Stage 6 Task 6.2 — Document commentary surface".

**Stage 6 exit gate:** A new operator can run the commentary loop from the README alone.

---

## Cross-stage invariants

1. **Chain is canonical.** The Lance index can be deleted and rebuilt from the chain at any time. The chain never depends on Lance.
2. **No floats in hashed payload fields.** `ts` is int64 ms; tags are strings; no probabilistic anything in the chain payload itself.
3. **Existing tests stay green.** Every `zig build test --summary all` between commits passes.
4. **GitButler-only commits.** Never `git commit`. Always the MCP tool. Chain `but branch new && but mark` in one Bash call when starting fresh branches.
5. **Hash-anchor only retrieval.** Text-anchor and tag-index are v2 features. Don't pre-build them.

---

## Deferred (out of scope for this plan)

- Text-anchor retrieval (`anchor_text` field on `/similar`).
- Tag-based index. Grep the chain files for v1.
- Multi-vector / colbert retrieval.
- Commentary "supersede / deprecate" relationship.
- Per-agent quotas and rate limiting.
- Dashboard UI for browsing or writing commentary. CLI + HTTP is enough for v1.

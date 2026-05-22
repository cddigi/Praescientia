# Ollama Routing & Per-Role Backend Toggle — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Ship the embedder swap (llama-server → Ollama), the per-role agent backend toggle with A/B comparison, and the small composable router that makes dispatch decisions inspectable artifacts. Companion design at `docs/plans/2026-05-22-ollama-routing-design.md`.

**Architecture:** Two new Zig binaries (`praescientia-router`, `praescientia-ollama-agent`) + a pure-logic module (`src/kb/routing.zig`). The router reads `<kb_root>/.routing.json` and probes Ollama's `/api/ps` to pick backend+model per role; the worker posts to `/api/chat` with `@embedFile`-baked role prompts. Commentary schema gains three nullable fields (`variant`, `shadow_of`, `dispatch`) so A/B pairs persist alongside primary decisions. The indexer's embedder is refactored behind a `BGEEmbedder` Protocol; `OllamaEmbedder` replaces `LlamaServerEmbedder`.

**Tech Stack:** Zig 0.16.0 (existing). Python 3.11+ with `pytest-httpserver` (new test dep) for embedder HTTP mocks. Ollama (operator-managed; assumes `qwen3.6:27b-mlx`, `nemotron3:33b`, and `bge-m3` are pulled). GitButler MCP for all commits.

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

`zig build test --summary all`. Python tests: `pytest tools/indexer/`.

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

**Branch creation** (do this once before Stage 1 Task 1.1):

```bash
but branch new ollama-routing && but mark ollama-routing
```

Chain both commands in one Bash call so the post-tool hook can't spawn a parallel `cd-branch-N` stub (per `feedback_gitbutler_branch_marking`).

### Editing rules

- Inline Zig tests only; reuse `std.testing.allocator`.
- Canonical-JSON payloads have alphabetically-sorted keys; no floats in hashed fields.
- Python files use `ruff format` defaults; tests use plain `pytest` + `tmp_path`.
- `.claude/agents/*.md` content is the single source of truth for role behavior — never duplicate prompt text into Zig.

### Ollama assumptions for smokes

`ollama serve` is running locally; `ollama pull bge-m3`, `ollama pull qwen3.6:27b-mlx`, and `ollama pull nemotron3:33b` have been run. Ollama-dependent smokes are gated by `OLLAMA_SMOKE=1`; unit tests never require Ollama.

---

## Stage 0 — Branch setup (one-shot, no code)

**Deliverable:** A clean GitButler branch `ollama-routing` marked active so all subsequent commits flow to it.

### Task 0.1 — Create and mark the branch

**Step 1:** Verify clean workspace.

```bash
but status -fv
```
Expected: `(no changes)` and no other active virtual branches blocking new work.

**Step 2:** Create and mark in one call.

```bash
but branch new ollama-routing && but mark ollama-routing
```
Expected: branch created, marked active, post-tool hook will now stage to it.

**Step 3:** Confirm.

```bash
but status -fv
```
Expected: `ollama-routing` listed and marked.

No commit yet — Stage 1 Task 1.1 produces the first.

---

## Stage 1 — Embedder swap (Python)

**Deliverable:** `tools/indexer/index_commentary.py` defines a `BGEEmbedder` Protocol, implements `OllamaEmbedder` against `/api/embed`, deletes `LlamaServerEmbedder`, renames `--llama-url` → `--ollama-url`, adds `--embed-model`. Tests pass with no Ollama running (HTTP mocked). `scripts/commentary_smoke.sh` updated. End of stage: `pytest tools/indexer/` green; smoke runnable against real local Ollama.

### Task 1.1 — Add `pytest-httpserver` dev dep + failing OllamaEmbedder happy-path test

**Files:**
- Modify: `tools/indexer/pyproject.toml` (add `pytest-httpserver` to dev deps)
- Modify: `tools/indexer/test_indexer.py`

**Step 1: Failing test** in `test_indexer.py`:

```python
def test_ollama_embedder_happy_path(httpserver):
    httpserver.expect_request(
        "/api/embed", method="POST"
    ).respond_with_json({
        "embeddings": [[0.1] * 1024, [0.2] * 1024]
    })
    from index_commentary import OllamaEmbedder
    e = OllamaEmbedder(base_url=httpserver.url_for(""))
    out = e.embed_batch(["alpha", "beta"])
    assert len(out) == 2
    assert len(out[0]) == 1024
    assert out[0][0] == 0.1
    assert out[1][0] == 0.2
```

**Step 2: Run.**

```bash
cd tools/indexer && pytest test_indexer.py::test_ollama_embedder_happy_path -v
```
Expected: `ImportError: cannot import name 'OllamaEmbedder'`.

**Step 3: Implement** `OllamaEmbedder` in `index_commentary.py` (keep `LlamaServerEmbedder` for now — deletion is Task 1.4):

```python
class OllamaEmbedder:
    def __init__(self, base_url: str, model: str = "bge-m3",
                 timeout_s: float = 30.0):
        self._base_url = base_url.rstrip("/")
        self._model = model
        self._timeout_s = timeout_s
        self._client = httpx.Client(timeout=timeout_s)

    def embed_batch(self, texts: list[str]) -> list[list[float]]:
        if not texts:
            return []
        url = f"{self._base_url}/api/embed"
        try:
            resp = self._client.post(
                url, json={"model": self._model, "input": texts}
            )
        except httpx.HTTPError as e:
            raise EmbedderUnavailable(
                f"ollama unreachable at {url}: {e}"
            ) from e
        if resp.status_code != 200:
            raise EmbedderUnavailable(
                f"ollama /api/embed returned {resp.status_code}: {resp.text[:200]}"
            )
        payload = resp.json()
        embeddings = payload.get("embeddings")
        if not isinstance(embeddings, list) or len(embeddings) != len(texts):
            raise EmbedderUnavailable(
                f"unexpected /api/embed response shape: got {len(embeddings) if isinstance(embeddings, list) else type(embeddings).__name__} vectors for {len(texts)} inputs"
            )
        for i, vec in enumerate(embeddings):
            if not isinstance(vec, list) or len(vec) != VECTOR_DIM:
                raise EmbedderUnavailable(
                    f"vector {i}: expected len {VECTOR_DIM}, got {len(vec) if isinstance(vec, list) else type(vec).__name__}"
                )
        return embeddings

    def close(self) -> None:
        self._client.close()
```

**Step 4: Run.** Expected: green.

**Step 5: Commit.** `fullPrompt`: "Stage 1 Task 1.1 — OllamaEmbedder happy path".

### Task 1.2 — Failure-mode tests for OllamaEmbedder

**Files:**
- Modify: `tools/indexer/test_indexer.py`

**Step 1: Failing tests:**

```python
def test_ollama_embedder_connection_refused():
    from index_commentary import OllamaEmbedder, EmbedderUnavailable
    e = OllamaEmbedder(base_url="http://127.0.0.1:1")  # unused port
    with pytest.raises(EmbedderUnavailable):
        e.embed_batch(["alpha"])

def test_ollama_embedder_404_model_missing(httpserver):
    httpserver.expect_request("/api/embed", method="POST").respond_with_data(
        '{"error":"model not found"}', status=404
    )
    from index_commentary import OllamaEmbedder, EmbedderUnavailable
    e = OllamaEmbedder(base_url=httpserver.url_for(""))
    with pytest.raises(EmbedderUnavailable):
        e.embed_batch(["alpha"])

def test_ollama_embedder_dim_mismatch(httpserver):
    httpserver.expect_request("/api/embed", method="POST").respond_with_json({
        "embeddings": [[0.1] * 512]
    })
    from index_commentary import OllamaEmbedder, EmbedderUnavailable
    e = OllamaEmbedder(base_url=httpserver.url_for(""))
    with pytest.raises(EmbedderUnavailable):
        e.embed_batch(["alpha"])

def test_ollama_embedder_count_mismatch(httpserver):
    httpserver.expect_request("/api/embed", method="POST").respond_with_json({
        "embeddings": [[0.1] * 1024]  # 1 vector for 2 inputs
    })
    from index_commentary import OllamaEmbedder, EmbedderUnavailable
    e = OllamaEmbedder(base_url=httpserver.url_for(""))
    with pytest.raises(EmbedderUnavailable):
        e.embed_batch(["alpha", "beta"])
```

**Step 2: Run.** Expected: all four fail in different ways depending on what the impl currently catches.

**Step 3: Adjust** `OllamaEmbedder` if needed to make all four error paths raise `EmbedderUnavailable` exclusively (the happy-path impl from 1.1 already covers most; verify the count-mismatch check is present).

**Step 4: Run.** Expected: green.

**Step 5: Commit.** `fullPrompt`: "Stage 1 Task 1.2 — OllamaEmbedder failure modes".

### Task 1.3 — `BGEEmbedder` Protocol + type-hint downstream consumers

**Files:**
- Modify: `tools/indexer/index_commentary.py`

**Step 1: Failing test** (will fail at import until the Protocol exists):

```python
def test_bge_embedder_protocol_accepts_ollama_impl():
    from index_commentary import BGEEmbedder, OllamaEmbedder
    e: BGEEmbedder = OllamaEmbedder(base_url="http://localhost:11434")
    assert hasattr(e, "embed_batch")
    assert hasattr(e, "close")
```

**Step 2: Run.** Expected: `ImportError: cannot import name 'BGEEmbedder'`.

**Step 3: Implement** the Protocol near `VECTOR_DIM`:

```python
from typing import Protocol

class BGEEmbedder(Protocol):
    """Embedding backend contract. Implementations must return
    `len(texts)` vectors of `VECTOR_DIM` (1024) floats each.
    Raises EmbedderUnavailable on any backend failure."""
    def embed_batch(self, texts: list[str]) -> list[list[float]]: ...
    def close(self) -> None: ...
```

Update function signatures of `run_once`, `run_loop`, `build_query_app` to use `embedder: BGEEmbedder` instead of the untyped parameter.

**Step 4: Run.** `pytest tools/indexer/` — all tests green.

**Step 5: Commit.** `fullPrompt`: "Stage 1 Task 1.3 — BGEEmbedder Protocol".

### Task 1.4 — Delete `LlamaServerEmbedder`

**Files:**
- Modify: `tools/indexer/index_commentary.py`

**Step 1: Failing condition** — there are no tests covering `LlamaServerEmbedder` directly; this task is verified by the absence of the class and a green test suite.

**Step 2: Remove** the `LlamaServerEmbedder` class definition entirely. Remove any module-level import that's only used by the deleted class. Leave `EmbedderUnavailable` (still raised by `OllamaEmbedder`).

**Step 3: Search** for lingering references:

```bash
grep -rn "LlamaServerEmbedder\|llama-server" tools/indexer/ scripts/ docs/ CLAUDE.md
```
Expected: only `scripts/commentary_smoke.sh` and `CLAUDE.md` (those get rewritten in Tasks 1.6 / Stage 5).

**Step 4: Run.** `pytest tools/indexer/` — all tests green.

**Step 5: Commit.** `fullPrompt`: "Stage 1 Task 1.4 — Delete LlamaServerEmbedder".

### Task 1.5 — CLI flag rename: `--llama-url` → `--ollama-url`, add `--embed-model`

**Files:**
- Modify: `tools/indexer/index_commentary.py` (the `main()` argparse block)
- Modify: `tools/indexer/test_indexer.py` (if any test invokes the CLI)

**Step 1: Failing test** for `main()` arg parsing (add a new test if absent):

```python
def test_main_accepts_ollama_url_and_embed_model(tmp_path, monkeypatch):
    from index_commentary import build_arg_parser
    args = build_arg_parser().parse_args([
        "--kb-root", str(tmp_path),
        "--once",
        "--ollama-url", "http://example:11434",
        "--embed-model", "bge-m3",
    ])
    assert args.ollama_url == "http://example:11434"
    assert args.embed_model == "bge-m3"
```

**Step 2: Run.** Expected: fails if `build_arg_parser` is currently inlined inside `main()` — split it out if so.

**Step 3: Implement**: rename the argparse argument from `--llama-url` to `--ollama-url` (keep `dest="ollama_url"`); add `--embed-model` (default `"bge-m3"`); update `main()` to construct `OllamaEmbedder(base_url=args.ollama_url, model=args.embed_model)`.

**Step 4: Run.** Green.

**Step 5: Commit.** `fullPrompt`: "Stage 1 Task 1.5 — Indexer CLI: --ollama-url + --embed-model".

### Task 1.6 — Update `scripts/commentary_smoke.sh`

**Files:**
- Modify: `scripts/commentary_smoke.sh`

**Step 1:** Open the file and locate the llama-server bring-up block.

**Step 2:** Replace it with Ollama bring-up:

```bash
# Bring up Ollama embedder (assumes `ollama serve` is running)
if ! curl -sf http://localhost:11434/api/tags >/dev/null; then
  echo "[smoke] ollama not running on :11434 — start with 'ollama serve' first" >&2
  exit 1
fi
ollama pull bge-m3 >/dev/null

# Launch indexer (background) against Ollama
python "$REPO_ROOT/tools/indexer/index_commentary.py" \
  --kb-root "$KB_ROOT" --once \
  --ollama-url http://localhost:11434 \
  --embed-model bge-m3
```

**Step 3:** Remove any `llama-server` PID-tracking / kill-on-exit lines (Ollama is operator-managed; smoke doesn't tear it down).

**Step 4: Run** the smoke locally (requires `ollama serve` + `bge-m3`):

```bash
./scripts/commentary_smoke.sh
```
Expected: exits 0 with indexed-rows output.

**Step 5: Commit.** `fullPrompt`: "Stage 1 Task 1.6 — commentary_smoke.sh uses Ollama".

**Stage 1 acceptance:** `pytest tools/indexer/` green; `./scripts/commentary_smoke.sh` green; `grep -rn LlamaServerEmbedder` returns no matches.

---

## Stage 2 — `praescientia-ollama-agent` worker binary

**Deliverable:** `tools/ollama_agent.zig` builds a binary that takes role + model flags, reads a JSON prompt on stdin, posts to Ollama `/api/chat`, prose-strips the response, and emits a JSON envelope on stdout. The three `.claude/agents/*.md` role prompts are `@embedFile`-baked at build time. Exit codes 0/2/3/4 are deterministic. Skill and daemon are NOT yet wired — they keep using Sonnet via `Agent`.

### Task 2.1 — Stub binary in `build.zig`

**Files:**
- Modify: `build.zig`
- Create: `tools/ollama_agent.zig`

**Step 1: Failing condition** — `zig build` fails to find the new exe target.

**Step 2:** Add to `build.zig` alongside other tool exes:

```zig
const ollama_agent = b.addExecutable(.{
    .name = "praescientia-ollama-agent",
    .root_module = b.createModule(.{
        .root_source_file = b.path("tools/ollama_agent.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "praescientia", .module = lib_mod },
        },
    }),
});
b.installArtifact(ollama_agent);
```

Create `tools/ollama_agent.zig` with a hello-world `main`:

```zig
const std = @import("std");
pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    std.debug.print("praescientia-ollama-agent stub\n", .{});
}
```

**Step 3: Run.**

```bash
zig build
```
Expected: builds clean; `./zig-out/bin/praescientia-ollama-agent` exists.

**Step 4: Smoke** the stub:

```bash
./zig-out/bin/praescientia-ollama-agent
```
Expected: prints `praescientia-ollama-agent stub`.

**Step 5: Commit.** `fullPrompt`: "Stage 2 Task 2.1 — ollama_agent binary stub".

### Task 2.2 — Pure prose-strip logic + tests

**Files:**
- Modify: `tools/ollama_agent.zig`

**Step 1: Failing tests** (in-file `test {}` blocks):

```zig
test "extractJsonEnvelope handles bare JSON" {
    const out = try extractJsonEnvelope(std.testing.allocator, "{\"x\":1}");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("{\"x\":1}", out);
}

test "extractJsonEnvelope strips leading prose" {
    const out = try extractJsonEnvelope(std.testing.allocator,
        "Here is the JSON:\n{\"x\":1,\"y\":2}\n");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("{\"x\":1,\"y\":2}", out);
}

test "extractJsonEnvelope unwraps ```json fence" {
    const out = try extractJsonEnvelope(std.testing.allocator,
        "Thinking...\n```json\n{\"x\":1}\n```\n");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("{\"x\":1}", out);
}

test "extractJsonEnvelope handles nested braces in prose" {
    const out = try extractJsonEnvelope(std.testing.allocator,
        "Note: {sic}. JSON: {\"x\":{\"y\":1}}");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("{\"x\":{\"y\":1}}", out);
}

test "extractJsonEnvelope returns error on no JSON" {
    try std.testing.expectError(
        error.NoJsonFound,
        extractJsonEnvelope(std.testing.allocator, "no braces here"),
    );
}
```

**Step 2: Run.**

```bash
zig build test --summary all 2>&1 | grep ollama_agent
```
Expected: compile errors (function undefined).

**Step 3: Implement** `extractJsonEnvelope(allocator, raw) ![]u8`:

- First try parsing `raw` as-is with `std.json.parseFromSlice` (cheap, common case).
- Else look for ```` ```json ```` fence; if found, return contents between the fences (strip surrounding whitespace).
- Else find the first `{`, then scan forward tracking brace depth (respecting string literals — `\"`) until depth returns to 0. Slice and verify it parses. On parse failure, advance to next `{` and retry.
- Return error.NoJsonFound if no candidate parses.

Caller owns returned slice.

**Step 4: Run.** Green.

**Step 5: Commit.** `fullPrompt`: "Stage 2 Task 2.2 — Prose-strip pipeline".

### Task 2.3 — `@embedFile` role prompts + role dispatch

**Files:**
- Modify: `tools/ollama_agent.zig`

**Step 1: Failing test:**

```zig
test "rolePrompt returns expected embedded content per role" {
    const thesis = rolePrompt(.thesis_analyst);
    const loss   = rolePrompt(.loss_reflector);
    const screen = rolePrompt(.market_screener);
    try std.testing.expect(thesis.len > 100);
    try std.testing.expect(loss.len > 100);
    try std.testing.expect(screen.len > 100);
    try std.testing.expect(!std.mem.eql(u8, thesis, loss));
    try std.testing.expect(std.mem.indexOf(u8, thesis, "thesis") != null
        or std.mem.indexOf(u8, thesis, "Thesis") != null);
}
```

**Step 2: Run.** Compile error.

**Step 3: Implement:**

```zig
const Role = enum { thesis_analyst, loss_reflector, market_screener };

const thesis_prompt = @embedFile("../.claude/agents/praescientia-thesis-analyst.md");
const loss_prompt   = @embedFile("../.claude/agents/praescientia-loss-reflector.md");
const screen_prompt = @embedFile("../.claude/agents/praescientia-market-screener.md");

fn rolePrompt(role: Role) []const u8 {
    return switch (role) {
        .thesis_analyst => thesis_prompt,
        .loss_reflector => loss_prompt,
        .market_screener => screen_prompt,
    };
}

fn parseRole(s: []const u8) !Role {
    if (std.mem.eql(u8, s, "thesis-analyst")) return .thesis_analyst;
    if (std.mem.eql(u8, s, "loss-reflector")) return .loss_reflector;
    if (std.mem.eql(u8, s, "market-screener")) return .market_screener;
    return error.UnknownRole;
}
```

**Step 4: Run.** Green.

**Step 5: Commit.** `fullPrompt`: "Stage 2 Task 2.3 — Role prompt @embedFile + dispatch".

### Task 2.4 — Ollama `/api/chat` HTTP client + happy path

**Files:**
- Modify: `tools/ollama_agent.zig`

**Step 1: Failing integration test** (uses `std.http.Server` as an in-process stub, similar to the pattern in `src/kalshi/client.zig` tests):

```zig
test "callOllamaChat returns assistant content on 200" {
    // Spin up a localhost std.http.Server on an ephemeral port.
    // Stub: any POST /api/chat returns
    //   { "message": {"role":"assistant","content":"{\"ok\":true}"}, "done": true }
    // Then call callOllamaChat with base_url, role, model, prompt_payload.
    // Assert returned content == "{\"ok\":true}".
    // (Full stub-server boilerplate: ~40 lines; adapt from existing
    //  src/kalshi/client.zig:test "auth header round-trips through stub server")
}
```

**Step 2: Run.** Compile error.

**Step 3: Implement** `callOllamaChat(allocator, base_url, model, role, prompt_payload) ![]u8`:

- Build request body via `std.json.Stringify.value(.{
    .model = model,
    .messages = .{
        .{ .role = "system", .content = rolePrompt(role) },
        .{ .role = "user",   .content = prompt_payload },
    },
    .stream = false,
    .options = .{ .temperature = 0.2, .num_predict = 4096 },
}, ...)`.
- `std.http.Client` POST to `{base_url}/api/chat`.
- On non-200 → `error.OllamaHttp`.
- On 200 → parse body, extract `message.content`. Return owned copy.

**Step 4: Run.** Green.

**Step 5: Commit.** `fullPrompt`: "Stage 2 Task 2.4 — Ollama /api/chat client".

### Task 2.5 — `main()`: argparse, stdin, exit codes

**Files:**
- Modify: `tools/ollama_agent.zig`

**Step 1:** No new in-file unit test for `main` — verified by smoke (Task 2.6).

**Step 2: Implement** in `main`:

1. Parse flags: `--role=`, `--model=`, `--ollama-url=` (default `http://localhost:11434`), `--timeout-ms=` (default `120000`), `--temperature=` (default `0.2`).
2. Read all of stdin into `prompt_payload`.
3. Call `callOllamaChat(...)`; map errors to exit codes:
   - `error.OllamaHttp`, `error.ConnectionRefused`, `error.Timeout`, `error.ModelNotFound` → exit 2
   - any other connection/IO error → exit 2
4. Pass content to `extractJsonEnvelope`; on `error.NoJsonFound` → exit 3.
5. Write stripped envelope to stdout. Exit 0.

Add a minimal `--help` printing flags + exit codes.

**Step 3: Run** smoke build:

```bash
zig build
```
Expected: clean.

**Step 4: Manual smoke** (requires `ollama serve` + a small model like `qwen3.6:27b-mlx`):

```bash
echo '{"thesis_id":"smoke","markets":[],"reality_head":null}' | \
  ./zig-out/bin/praescientia-ollama-agent \
    --role=thesis-analyst --model=qwen3.6:27b-mlx
```
Expected: exit 0, JSON envelope on stdout (content shape depends on model; just verify exit and presence of `{`).

**Step 5: Commit.** `fullPrompt`: "Stage 2 Task 2.5 — ollama-agent main, argparse, exit codes".

### Task 2.6 — `scripts/ollama_agent_smoke.sh`

**Files:**
- Create: `scripts/ollama_agent_smoke.sh`

**Step 1: Implement:**

```bash
#!/usr/bin/env bash
set -euo pipefail

if [[ "${OLLAMA_SMOKE:-0}" != "1" ]]; then
  echo "[smoke] skipping: set OLLAMA_SMOKE=1 to run"
  exit 0
fi

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

if ! curl -sf http://localhost:11434/api/tags >/dev/null; then
  echo "[smoke] ollama not running on :11434" >&2
  exit 1
fi

zig build

MODEL="${OLLAMA_SMOKE_MODEL:-qwen3.6:27b-mlx}"

PROMPT='{"thesis_id":"smoke-thesis","markets":[],"reality_head":null,"now_ms":1747800000000}'

OUT="$(echo "$PROMPT" | ./zig-out/bin/praescientia-ollama-agent \
  --role=thesis-analyst --model="$MODEL" 2>/dev/null)"

# Just verify outer-{} present
case "$OUT" in
  '{'*'}') echo "[smoke] OK; envelope: ${OUT:0:80}..." ;;
  *) echo "[smoke] FAIL: no JSON envelope" >&2; exit 1 ;;
esac
```

**Step 2:** `chmod +x scripts/ollama_agent_smoke.sh`.

**Step 3: Run** the gated path:

```bash
OLLAMA_SMOKE=1 ./scripts/ollama_agent_smoke.sh
```
Expected: exits 0 with `OK` message.

**Step 4: Run** the skipped path:

```bash
./scripts/ollama_agent_smoke.sh
```
Expected: prints skip message, exits 0.

**Step 5: Commit.** `fullPrompt`: "Stage 2 Task 2.6 — ollama_agent_smoke.sh".

**Stage 2 acceptance:** `zig build test --summary all` green; `OLLAMA_SMOKE=1 ./scripts/ollama_agent_smoke.sh` green.

---

## Stage 3 — Router binary + commentary schema extension

**Deliverable:** Pure-logic `src/kb/routing.zig` parses policy and emits variants. `tools/router.zig` wraps it with the `/api/ps` probe + CLI. `src/kb/commentary.zig` gains three nullable fields. Validator accepts new fields, requires `shadow_of` when `variant == "b"`. Skill and daemon remain unchanged.

### Task 3.1 — `src/kb/routing.zig` — `Policy`, `parsePolicy`

**Files:**
- Create: `src/kb/routing.zig`
- Modify: `src/root.zig` (export `pub const routing = @import("kb/routing.zig"); _ = kb.routing;` in root test block)

**Step 1: Failing tests:**

```zig
test "parsePolicy handles full policy with all roles" {
    const src =
        \\{
        \\  "thesis_analyst": {
        \\    "primary": {"backend": "ollama", "model": "qwen3.6:27b-mlx"},
        \\    "fallback": [{"backend": "sonnet"}],
        \\    "require_loaded": true
        \\  },
        \\  "loss_reflector": {"primary": {"backend": "sonnet"}, "fallback": []},
        \\  "market_screener": {
        \\    "primary": {"backend": "ollama", "model": "qwen3.6:27b-mlx"},
        \\    "fallback": [{"backend": "sonnet"}],
        \\    "shadow_with": {"backend": "ollama", "model": "nemotron3:33b"}
        \\  }
        \\}
    ;
    var policy = try parsePolicy(std.testing.allocator, src);
    defer policy.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("qwen3.6:27b-mlx", policy.thesis_analyst.primary.model.?);
    try std.testing.expect(policy.thesis_analyst.require_loaded);
    try std.testing.expect(policy.market_screener.shadow_with != null);
}

test "parsePolicy missing role yields all-Sonnet default" {
    const src = "{}";
    var policy = try parsePolicy(std.testing.allocator, src);
    defer policy.deinit(std.testing.allocator);
    try std.testing.expectEqual(Backend.sonnet, policy.thesis_analyst.primary.backend);
    try std.testing.expectEqual(Backend.sonnet, policy.loss_reflector.primary.backend);
    try std.testing.expectEqual(Backend.sonnet, policy.market_screener.primary.backend);
}

test "parsePolicy unknown fields are ignored" {
    const src =
        \\{"thesis_analyst": {"primary": {"backend": "sonnet"}, "unknown": 42}}
    ;
    var policy = try parsePolicy(std.testing.allocator, src);
    defer policy.deinit(std.testing.allocator);
    try std.testing.expectEqual(Backend.sonnet, policy.thesis_analyst.primary.backend);
}
```

**Step 2: Run.** Compile errors.

**Step 3: Implement** `Backend` (enum `ollama`, `sonnet`), `BackendChoice` (`backend: Backend, model: ?[]const u8`), `RolePolicy` (primary, fallback, require_loaded, shadow_with), `Policy` (thesis_analyst, loss_reflector, market_screener), and `parsePolicy(allocator, src) !Policy`. Use `std.json.parseFromSlice` with `.ignore_unknown_fields = true`. Allocate strings into the policy's arena so `deinit` is single-call.

**Step 4: Run.** Green.

**Step 5: Commit.** `fullPrompt`: "Stage 3 Task 3.1 — routing.zig Policy + parsePolicy".

### Task 3.2 — `evaluate(role, policy, probe) → Variants`

**Files:**
- Modify: `src/kb/routing.zig`

**Step 1: Failing tests:**

```zig
test "evaluate returns primary when require_loaded=false" {
    const policy = try parsePolicy(std.testing.allocator,
        \\{"thesis_analyst": {"primary": {"backend": "ollama", "model": "qwen3.6:27b-mlx"}, "fallback": []}}
    );
    defer policy.deinit(std.testing.allocator);
    const probe: Probe = .{ .loaded = &.{}, .tags = &.{"qwen3.6:27b-mlx"} };
    var variants = try evaluate(std.testing.allocator, .thesis_analyst, policy, probe);
    defer variants.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), variants.items.len);
    try std.testing.expectEqualStrings("qwen3.6:27b-mlx", variants.items[0].model.?);
}

test "evaluate walks fallback chain when primary not loaded and require_loaded=true" {
    const policy = try parsePolicy(std.testing.allocator,
        \\{"thesis_analyst": {
        \\  "primary": {"backend": "ollama", "model": "qwen3.6:27b-mlx"},
        \\  "fallback": [{"backend": "ollama", "model": "nemotron3:33b"}, {"backend": "sonnet"}],
        \\  "require_loaded": true
        \\}}
    );
    defer policy.deinit(std.testing.allocator);
    const probe: Probe = .{ .loaded = &.{"nemotron3:33b"}, .tags = &.{} };
    var variants = try evaluate(std.testing.allocator, .thesis_analyst, policy, probe);
    defer variants.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("nemotron3:33b", variants.items[0].model.?);
}

test "evaluate emits 2 variants when shadow_with set" {
    const policy = try parsePolicy(std.testing.allocator,
        \\{"market_screener": {
        \\  "primary": {"backend": "ollama", "model": "qwen3.6:27b-mlx"},
        \\  "fallback": [],
        \\  "shadow_with": {"backend": "ollama", "model": "nemotron3:33b"}
        \\}}
    );
    defer policy.deinit(std.testing.allocator);
    const probe: Probe = .{ .loaded = &.{"qwen3.6:27b-mlx", "nemotron3:33b"}, .tags = &.{} };
    var variants = try evaluate(std.testing.allocator, .market_screener, policy, probe);
    defer variants.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), variants.items.len);
}

test "evaluate ignores loss_reflector shadow_with" {
    // Policy with shadow_with on loss_reflector → still emits 1 variant
    // (per design §3)
}

test "evaluate falls back to sonnet when whole chain cold" {
    // All ollama models cold + sonnet at end of fallback → 1 variant, sonnet
}
```

**Step 2: Run.** Compile errors.

**Step 3: Implement** `Probe = struct { loaded: []const []const u8, tags: []const []const u8 }`, `Variant = struct { backend, model, reason }`, and `evaluate(allocator, role, policy, probe) !std.ArrayListUnmanaged(Variant)`. Reason strings: `"primary; loaded"`, `"primary; not loaded → fallback"`, `"fallback after primary cold"`, `"sonnet fallback"`, `"shadow_with"`.

**Step 4: Run.** Green.

**Step 5: Commit.** `fullPrompt`: "Stage 3 Task 3.2 — routing.evaluate".

### Task 3.3 — `tools/router.zig` — CLI + `/api/ps` probe

**Files:**
- Create: `tools/router.zig`
- Modify: `build.zig` (add `praescientia-router` executable)

**Step 1: Failing integration test** (in-file, using the same `std.http.Server` stub pattern as Task 2.4):

```zig
test "probeOllama returns loaded + tags from stubbed /api/ps + /api/tags" {
    // Stub server: GET /api/ps → {"models":[{"name":"qwen3.6:27b-mlx"}]}
    //              GET /api/tags → {"models":[{"name":"qwen3.6:27b-mlx"},{"name":"bge-m3"}]}
    // probe = try probeOllama(allocator, stub_url);
    // assert probe.loaded contains qwen3.6:27b-mlx
    // assert probe.tags contains bge-m3
}
```

**Step 2: Run.** Compile error.

**Step 3: Implement** `probeOllama(allocator, base_url) !Probe`. Use `std.http.Client`. Cache the response in-memory; the `--probe-cache-ms` flag is applied at the `main` level (next step).

Add `build.zig` exe target for `praescientia-router` similar to Task 2.1.

Implement `main`:
1. Subcommand `pick` only for v1; reject others with usage message.
2. Parse `--role=`, `--policy=PATH`, `--ollama-url=`, `--probe-cache-ms=`.
3. Read policy file (or synthesize all-Sonnet default if missing).
4. Probe Ollama (catch errors → return all-Sonnet variant with `reason: "probe failed: <err>"`).
5. Call `routing.evaluate`.
6. Marshal to the design's JSON shape; write to stdout. Exit 0 always.

**Step 4: Run.** Build + test green.

**Step 5: Commit.** `fullPrompt`: "Stage 3 Task 3.3 — router CLI + Ollama probe".

### Task 3.4 — `scripts/router_smoke.sh`

**Files:**
- Create: `scripts/router_smoke.sh`

**Step 1: Implement** a smoke that:

1. Spins up `python3 -m http.server` with two static files mimicking `/api/ps` and `/api/tags` JSON (via a tiny custom handler) — OR uses `nc` to serve canned HTTP responses on a fixed port.
2. Writes a temp policy file with `thesis_analyst.primary = qwen3.6:27b-mlx`, `require_loaded = true`, `fallback = [{sonnet}]`.
3. Runs `praescientia-router pick --role=thesis-analyst --policy=$POLICY --ollama-url=http://localhost:<stub-port>`.
4. Asserts stdout JSON includes `"role":"thesis-analyst"` and a variant.

Keep it simple — a Python one-liner stub server is easier to maintain than `nc`:

```bash
python3 -c '
from http.server import BaseHTTPRequestHandler, HTTPServer
import json, threading, sys
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        body = {"/api/ps": {"models":[{"name":"qwen3.6:27b-mlx"}]},
                "/api/tags": {"models":[{"name":"qwen3.6:27b-mlx"}]}}.get(self.path, {})
        b = json.dumps(body).encode()
        self.send_response(200); self.send_header("content-type","application/json")
        self.send_header("content-length", str(len(b))); self.end_headers(); self.wfile.write(b)
srv = HTTPServer(("127.0.0.1", 0), H)
print(srv.server_port, flush=True)
srv.serve_forever()
' &
```

**Step 2:** `chmod +x scripts/router_smoke.sh`.

**Step 3: Run.**

```bash
./scripts/router_smoke.sh
```
Expected: prints `[smoke] OK` and the router JSON output.

**Step 4: Add** the smoke to `scripts/orchestrator_smoke.sh`'s preamble checks (optional; can also stand alone).

**Step 5: Commit.** `fullPrompt`: "Stage 3 Task 3.4 — router_smoke.sh".

### Task 3.5 — Commentary schema: nullable `variant`, `shadow_of`, `dispatch`

**Files:**
- Modify: `src/kb/commentary.zig`

**Step 1: Failing tests:**

```zig
test "encodePayload with variant=b emits variant + shadow_of + dispatch keys" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try encodePayload(&aw.writer, .{
        .agent = .{ .model = "qwen3.6:27b-mlx", .run_id = "abc" },
        .body = "shadow body",
        .references = &.{},
        .parent_hash = null,
        .inputs = .{},
        .tags = &.{},
        .ts_ms = 1747800000000,
        .variant = "b",
        .shadow_of = "deadbeef" ** 8,
        .dispatch = .{
            .backend = "ollama",
            .model = "nemotron3:33b",
            .router_decided_at_ms = 1747800000000,
            .reason = "shadow_with",
        },
    });
    const out = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, out, "\"variant\":\"b\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"shadow_of\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"dispatch\":{") != null);
}

test "encodePayload with all-null new fields omits them entirely" {
    // Confirms forward compat: existing chains round-trip unchanged.
    // Body should NOT contain the keys "variant", "shadow_of", or "dispatch".
}

test "decodePayload reads a payload with new fields" {
    // Construct a JSON body with variant=b, shadow_of=<hash>, dispatch=...
    // Parse via existing decoder; assert struct fields populated.
}
```

**Step 2: Run.** Compile errors (field on `CommentaryPayload` missing).

**Step 3: Implement**:

- Add to `CommentaryPayload`:
  ```zig
  variant: ?[]const u8 = null,
  shadow_of: ?[]const u8 = null,
  dispatch: ?Dispatch = null,
  ```
- Define `pub const Dispatch = struct { backend: []const u8, model: ?[]const u8 = null, router_decided_at_ms: i64, reason: []const u8 };`
- Update `encodePayload`: emit each new key only when non-null. Keep alphabetical key order (note that `dispatch` < `inputs` < `kind` < `parent_hash` < `references` < `shadow_of` < `tags` < `ts` < `variant`).
- Update `decodePayload` (or whichever JSON parser exists) to populate the new fields when present.

**Step 4: Run.** Green.

**Step 5: Commit.** `fullPrompt`: "Stage 3 Task 3.5 — Commentary nullable variant/shadow_of/dispatch".

### Task 3.6 — Validator: require `shadow_of` iff `variant == "b"`

**Files:**
- Modify: `src/kb/commentary.zig` (validatePayload)
- Modify: `src/kb/ticks.zig` if it has its own commentary validation path

**Step 1: Failing tests:**

```zig
test "validatePayload rejects variant=b without shadow_of" {
    var p: CommentaryPayload = .{ /* ... minimal valid ... */ };
    p.variant = "b";
    p.shadow_of = null;
    try std.testing.expectError(error.MissingShadowOf, validatePayload(&p));
}

test "validatePayload rejects variant=b with malformed shadow_of" {
    var p: CommentaryPayload = .{ /* ... */ };
    p.variant = "b";
    p.shadow_of = "not-hex";
    try std.testing.expectError(error.InvalidHashFormat, validatePayload(&p));
}

test "validatePayload accepts variant=a with shadow_of=null" {
    // Primary entries don't have shadow_of
}

test "validatePayload accepts variant=null (legacy)" {
    // Existing entries with no variant field validate
}

test "validatePayload rejects unknown variant value" {
    var p: CommentaryPayload = .{ /* ... */ };
    p.variant = "c";
    try std.testing.expectError(error.InvalidVariant, validatePayload(&p));
}
```

**Step 2: Run.** Errors undefined.

**Step 3: Implement** the four new error names + checks in `validatePayload`.

**Step 4: Run.** Green.

**Step 5: Commit.** `fullPrompt`: "Stage 3 Task 3.6 — Validator: variant/shadow_of rules".

**Stage 3 acceptance:** `zig build test --summary all` green; `./scripts/router_smoke.sh` green; `./zig-out/bin/praescientia-router pick --role=thesis-analyst --policy=/nonexistent` returns all-Sonnet variant with `reason: "policy missing; default"`.

---

## Stage 4 — Wire router into daemon + skill; A/B persistence

**Deliverable:** `tools/orchestrate_daemon.zig` consults the router before each role dispatch and shells out to either `Agent` (Sonnet) or `praescientia-ollama-agent`. Shadow variants persist as paired commentary entries. `.claude/skills/praescientia-orchestrate/tick.md` mirrors the same flow. `scripts/orchestrator_smoke.sh` extends to assert paired entries.

### Task 4.1 — Daemon: `--policy=` flag + per-role router invocation

**Files:**
- Modify: `tools/orchestrate_daemon.zig`

**Step 1: Failing test** (or smoke, if the daemon has no unit-test surface today — most likely an integration check via the orchestrator smoke):

If `tools/orchestrate_daemon.zig` has an internal function like `dispatchRole(allocator, role, ...) !Decision`, write a unit test that injects a fake router-output JSON and asserts the right path is taken. Otherwise, defer to Task 4.4's extended smoke.

**Step 2:** Parse `--policy=PATH` (default `<kb_root>/.routing.json`), `--ollama-url=URL`, `--ollama-bin=PATH` (default `./zig-out/bin/praescientia-ollama-agent`), `--router-bin=PATH` (default `./zig-out/bin/praescientia-router`).

**Step 3: Implement** per role:

```zig
// Pseudocode shape:
fn dispatchRole(ctx, role) !DispatchOutcome {
    const router_json = try runRouter(ctx, role); // shells out, captures stdout
    const variants = try parseRouterVariants(ctx.allocator, router_json);
    defer ctx.allocator.free(variants);

    var primary_decision: ?Decision = null;
    var shadow_decision: ?ShadowDecision = null;
    for (variants, 0..) |v, i| {
        const decision_json = switch (v.backend) {
            .sonnet => try invokeClaudeAgent(ctx, role, ...), // existing path
            .ollama => try runOllamaAgent(ctx, role, v.model.?, ...),
        };
        // Validate via praescientia-ticks validate
        try ctx.runValidator(role, decision_json);
        if (i == 0) primary_decision = decision_json
        else shadow_decision = .{ .decision = decision_json, .variant = v };
    }
    return .{ .primary = primary_decision.?, .shadow = shadow_decision };
}
```

**Step 4: Run** `zig build`.

**Step 5: Commit.** `fullPrompt`: "Stage 4 Task 4.1 — Daemon: router invocation + per-role dispatch".

### Task 4.2 — Shadow persistence path

**Files:**
- Modify: `tools/orchestrate_daemon.zig`
- Possibly modify: `src/kb/commentary.zig` (helper for "write shadow commentary" if cleaner)

**Step 1: Failing assertion** in `scripts/orchestrator_smoke.sh` (Task 4.4) — easiest to red/green at the integration level.

**Step 2: Implement**:

- After persisting the primary's commentary entry (existing code path), capture its CID.
- If `shadow_decision != null`, build a `CommentaryPayload` with:
  - `body` = the shadow's prose
  - `variant` = `"b"`
  - `shadow_of` = primary's CID
  - `dispatch` = the variant's `{backend, model, router_decided_at_ms, reason}` (router output carries this; pass through)
  - `parent_hash` = the chain head AFTER the primary entry was written
- Call `writeCommentary` for the shadow.
- **Do not** flow the shadow's `orders[]` to any order-placement code.

**Step 3:** Add stderr logging line: `[daemon] role=<r> primary=<backend>/<model> shadow=<backend>/<model>` so smoke can grep.

**Step 4: Build.**

**Step 5: Commit.** `fullPrompt`: "Stage 4 Task 4.2 — Shadow commentary persistence".

### Task 4.3 — Update `.claude/skills/praescientia-orchestrate/tick.md`

**Files:**
- Modify: `.claude/skills/praescientia-orchestrate/tick.md`
- Modify: `.claude/skills/praescientia-orchestrate/SKILL.md`

**Step 1:** Read current `tick.md` to locate the per-role Agent invocation block (likely in a §-numbered section per role).

**Step 2: Modify** each role's dispatch instruction:

Before each `Agent(...)` call, insert a router-pick step:

```markdown
**Step N.0 — Router pick.**

Run:

```bash
./zig-out/bin/praescientia-router pick --role=<role> --policy=<kb_root>/.routing.json
```

Parse the JSON. For each variant:

- `backend == "sonnet"` → invoke `Agent({subagent_type: "praescientia-<role>", model: "sonnet", prompt: <role-JSON>})`
- `backend == "ollama"` → run `echo "<role-JSON>" | ./zig-out/bin/praescientia-ollama-agent --role=<role> --model=<variant.model>`

Validate each decision via `praescientia-ticks validate`. Primary's decision drives `praescientia-ticks finish` and order placement. Shadow's decision writes a paired commentary entry (variant="b", shadow_of=<primary cid>, dispatch={...}) and is otherwise ignored.
```

**Step 3:** In `SKILL.md`, document the new orchestrator flags: `--policy=PATH`, `--ollama-url=URL`, A/B comparison behavior, missing-policy default. Add one example invocation showing a shadow run.

**Step 4: Verify** the skill still loads — eyeball check; no automated test.

**Step 5: Commit.** `fullPrompt`: "Stage 4 Task 4.3 — Skill tick.md + SKILL.md router/A-B docs".

### Task 4.4 — Extend `scripts/orchestrator_smoke.sh` with A/B assertion

**Files:**
- Modify: `scripts/orchestrator_smoke.sh`
- Possibly modify: `tests/fixtures/mock_thesis_analyst.sh` (if a separate shadow mock needed)

**Step 1: Failing condition** — current smoke doesn't write a shadow entry.

**Step 2:** Extend the smoke:

1. Write a `.routing.json` into the smoke's temp kb_root with `market_screener.shadow_with` set to a mock-pointing variant.
2. Make the mock router output the variant pair (or use the real `praescientia-router` binary with a stub-policy file pointing to a non-existent Ollama URL → it'll return all-Sonnet; in that case, force the shadow path via env override `PRAESCIENTIA_FORCE_SHADOW=1` honored by the daemon for tests).
3. After the tick completes, `praescientia-kb inspect --scope=thesis/<id>/commentary` and assert at least one entry has `variant=b` and a populated `shadow_of`.

**Step 3: Run** the extended smoke:

```bash
./scripts/orchestrator_smoke.sh
```
Expected: exits 0 with `OK — shadow entry observed`.

**Step 4:** Confirm the smoke still passes WITHOUT the routing changes (i.e. with no `.routing.json` and the daemon falling back to Sonnet-only) — it should be backward-compatible.

**Step 5: Commit.** `fullPrompt`: "Stage 4 Task 4.4 — orchestrator_smoke.sh A/B assertion".

**Stage 4 acceptance:** Both smokes green (`./scripts/orchestrator_smoke.sh` and `./scripts/router_smoke.sh`); `zig build test --summary all` green; manually running a tick with a shadow policy produces a paired commentary entry visible in `praescientia-kb inspect`.

---

## Stage 5 — `praescientia-ticks compare` + docs sweep

**Deliverable:** New `compare --tick-id=ID` subcommand walks the commentary chain and prints primary + shadow side-by-side with a diff summary. `CLAUDE.md` reflects the new binaries, routing policy, and flags. `README.md` (if it mentions any of the touched surfaces) is updated.

### Task 5.1 — `tools/ticks.zig` — `compare` subcommand

**Files:**
- Modify: `tools/ticks.zig`

**Step 1: Failing test:**

```zig
test "compare subcommand prints both decisions when paired" {
    // Set up tmp kb with one primary + one shadow commentary entry sharing tick_id.
    // Capture stdout of `cmdCompare(ctx, .{ .tick_id = "..." })`.
    // Assert output contains both decision bodies and a "DIFF" section.
}

test "compare returns user-friendly error when tick_id has no shadow" {
    // Single primary entry, no shadow → message "no shadow for tick X" + exit 0.
}
```

**Step 2: Run.** Compile error.

**Step 3: Implement** `cmdCompare`:

1. Walk all `theses/*/commentary/main.jsonl` (or accept a `--scope=` flag if needed).
2. Find entries with `tick_id == <given>`.
3. Pair primary (`variant=null or "a"`) with shadow (`variant="b"` linked by `shadow_of=<primary cid>`).
4. If only primary found, print primary + "no shadow for this tick".
5. If both found, print side-by-side: `confidence_bp` diff, top-3 `orders[]` diff (ticker, side, count, limit), rationale snippets.

**Step 4: Run.** Green.

**Step 5: Commit.** `fullPrompt`: "Stage 5 Task 5.1 — ticks compare subcommand".

### Task 5.2 — Goldens for `compare`

**Files:**
- Create: `tests/fixtures/decisions/ab_pair_primary.json`
- Create: `tests/fixtures/decisions/ab_pair_shadow.json`
- Modify: `tools/ticks.zig` (test that loads these)

**Step 1: Failing test** that reads both fixtures into a tmp kb chain, runs `cmdCompare`, and snapshot-asserts the output.

**Step 2:** Write the two fixture JSON files. Primary uses `qwen3.6:27b-mlx` confidence 6800 / one buy order. Shadow uses `nemotron3:33b` confidence 5500 / no orders. Same `tick_id`. Shadow's `shadow_of` points to primary's CID (computed at fixture-build time; the test can synthesize the chain dynamically rather than hardcoding the CID).

**Step 3:** Run.

**Step 4:** Green.

**Step 5: Commit.** `fullPrompt`: "Stage 5 Task 5.2 — A/B compare golden fixtures".

### Task 5.3 — `CLAUDE.md` updates

**Files:**
- Modify: `CLAUDE.md`

**Step 1:** Open `CLAUDE.md`. Locate the tools table.

**Step 2: Add two rows** for the new binaries:

```
| Router (per-role dispatch) | `./zig-out/bin/praescientia-router pick --role=<r> --policy=PATH` | `tools/router.zig` + `src/kb/routing.zig` |
| Ollama agent worker | `./zig-out/bin/praescientia-ollama-agent --role=<r> --model=<tag>` | `tools/ollama_agent.zig` |
```

**Step 3: Update** the existing `Commentary indexer` row's command to reflect `--ollama-url` (already noted by the indexer line).

**Step 4: Add to the "Notes" section** a short paragraph:

> Agent backend routing lives in `<kb_root>/.routing.json` (see `docs/plans/2026-05-22-ollama-routing-design.md`). Missing file → all-Sonnet. Shadow comparisons (`shadow_with`) emit paired commentary entries with `variant: "b"`; replay them via `praescientia-ticks compare --tick-id=ID`.

**Step 5: Commit.** `fullPrompt`: "Stage 5 Task 5.3 — CLAUDE.md tools table + routing notes".

### Task 5.4 — Project memory updates

**Files:**
- Create: `/Users/lawls/.claude/projects/-Users-lawls-Development-TuesdayCrowd-Praescientia/memory/project_ollama_routing_landed.md`
- Modify: `/Users/lawls/.claude/projects/-Users-lawls-Development-TuesdayCrowd-Praescientia/memory/MEMORY.md`

**Step 1:** Write a project memory recording the dispatch architecture:

```markdown
---
name: ollama-routing-landed
description: Per-role agent backend routing via praescientia-router; A/B via shadow_with; Ollama embedder replaces llama-server
metadata:
  type: project
---

The orchestrator dispatches each sub-agent role via `praescientia-router pick`, which reads `<kb_root>/.routing.json` and probes Ollama `/api/ps`. Backends: `sonnet` (Claude Code Agent tool) or `ollama` (praescientia-ollama-agent binary, `/api/chat`). A/B comparisons set `shadow_with` on a role and produce paired commentary entries (`variant: "b"`, `shadow_of: <primary cid>`). Embedder is Ollama BGE-M3 via `/api/embed`. Default policy (file missing): all-Sonnet.

**Why:** Cost + experimentation. Local models (qwen3.6:27b-mlx, nemotron3:33b) handle routine roles; Sonnet stays for high-stakes or no-signal-rejection cases. A/B lets us compare without doubling exposure.

**How to apply:** When user mentions routing, model choice, or A/B comparison, refer to the policy file at <kb_root>/.routing.json. For shadow inspection, use `praescientia-ticks compare --tick-id=ID`. Design and impl in `docs/plans/2026-05-22-ollama-routing-*.md`.
```

**Step 2:** Append to `MEMORY.md`:

```markdown
- [Ollama routing landed](project_ollama_routing_landed.md) — Per-role agent backend routing via praescientia-router + A/B via shadow_with; Ollama BGE-M3 replaces llama-server
```

**Step 3:** No test; this is documentation.

**Step 4:** Verify both files exist and `MEMORY.md` stays under its line cap.

**Step 5: Commit.** `fullPrompt`: "Stage 5 Task 5.4 — Project memory: ollama routing landed".

**Stage 5 acceptance:** `zig build test --summary all` green; `./scripts/orchestrator_smoke.sh` green; `./zig-out/bin/praescientia-ticks compare --tick-id=<any-ab-tick>` produces side-by-side output.

---

## Final acceptance (end of Stage 5)

- `zig build test --summary all` — all tests green.
- `pytest tools/indexer/` — green.
- `./scripts/commentary_smoke.sh` — green (against local Ollama + BGE-M3).
- `./scripts/router_smoke.sh` — green.
- `OLLAMA_SMOKE=1 ./scripts/ollama_agent_smoke.sh` — green.
- `./scripts/orchestrator_smoke.sh` — green, including A/B assertion.
- `grep -rn LlamaServerEmbedder tools/ scripts/` — no matches.
- `CLAUDE.md` mentions both new binaries and the routing policy.
- Project memory `ollama_routing_landed.md` exists; `MEMORY.md` indexes it.

After acceptance, push the branch and open a PR via `but review publish`.

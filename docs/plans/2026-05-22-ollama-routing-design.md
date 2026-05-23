# Ollama Routing & Per-Role Backend Toggle — Design

> Swap the BGE-M3 embedder from llama-server to Ollama, and add a small composable router that lets the orchestrator dispatch each sub-agent role (thesis-analyst, loss-reflector, market-screener) to either Claude Sonnet or a local Ollama model — resource-aware and A/B-capable. Dispatch decisions become discrete inspectable artifacts, in keeping with the Hopper doctrine the rest of the codebase already follows.

## Context

Today the orchestrator skill and `praescientia-orchestrate-daemon` invoke three Claude Code sub-agents (`praescientia-thesis-analyst`, `praescientia-loss-reflector`, `praescientia-market-screener`) via the `Agent` tool, all defaulting to Sonnet (switched from Opus on 2026-05-21 for cost — see `feedback`/`project` memory). The commentary indexer embeds entries with a `llama-server --embeddings` daemon serving BGE-M3.

Two shifts:

1. **Embedding** moves from llama-server to Ollama, same BGE-M3 model.
2. **Agent inference** gains a local Ollama option per role. The local box already has `qwen3.6:27b-mlx` (19 GB) and `nemotron3:33b` (27 GB) pulled.

The orchestrator should be able to hand different roles to different models based on what's currently loaded in VRAM, and should be able to run two models on the same input for comparison. Static per-role flags don't capture this; a small router binary does.

## Decision summary

| Area | Choice |
|---|---|
| Embedder backend | Ollama `/api/embed` with `model=bge-m3`, replacing llama-server entirely |
| Embedder abstraction | `BGEEmbedder` Protocol in `tools/indexer/index_commentary.py`; one impl (`OllamaEmbedder`) |
| Agent routing scope | Per sub-agent role (thesis-analyst, loss-reflector, market-screener) |
| Routing locus | New `praescientia-router pick` binary; skill + daemon shell out to it before each role dispatch |
| Agent worker | New `praescientia-ollama-agent` binary; one binary, `--role` flag, posts to Ollama `/api/chat` |
| Policy file | `<kb_root>/.routing.json`; missing file → all-Sonnet default (no breakage) |
| A/B mode | `shadow_with` policy field; primary decides + places orders, shadow logs only |
| Shadow persistence | Paired commentary entry with `variant: "b"`, `shadow_of: <primary cid>`, `dispatch: {…}` |
| Loss-reflector A/B | Excluded from v1 (`shadow_with` ignored with warning) |
| Validator | Backend-agnostic; same envelope from Sonnet and Ollama paths |
| Agent definitions | `.claude/agents/*.md` system prompts shared by both backends (`@embedFile` in worker) |

---

## §1. Architecture overview

Two parallel inference paths share one validator, one persistence layer, and one set of role prompts.

```
                                ┌──────────────────────────────┐
                                │   .claude/agents/*.md         │
                                │   (role system prompts)       │
                                └──────────┬─────────┬──────────┘
                                           │         │
            ┌──────────────────────────────┘         └──────────────────┐
            │                                                            │
            ▼                                                            ▼
   ┌─────────────────┐                                       ┌──────────────────────┐
   │ Claude Code     │                                       │ praescientia-        │
   │ Agent tool      │                                       │ ollama-agent (Zig)   │
   │ (subagent_type) │                                       │  POST /api/chat      │
   └────────┬────────┘                                       └──────────┬───────────┘
            │ JSON envelope                                              │ JSON envelope
            └────────────────────────────┬───────────────────────────────┘
                                         │
                                         ▼
                               ┌──────────────────────┐
                               │ praescientia-ticks   │
                               │ validate (existing)  │
                               └──────────┬───────────┘
                                          │
                                          ▼
                               persist → orders → snapshot
```

Both call sites are entered from the same dispatcher (skill or daemon), which first asks the router which backend(s) to use for the role at hand:

```
                  ┌─────────────────────────┐
                  │ praescientia-router     │
                  │ pick --role=<R>         │
                  │   --policy=<kb>/.routing│
                  │   probes Ollama /api/ps │
                  └────────┬────────────────┘
                           │ JSON: variants[]
                           ▼
                ┌──────────────────────────┐
                │  for v in variants:      │
                │    if v.backend==sonnet  │
                │       → Agent(...)       │
                │    else                  │
                │       → ollama-agent     │
                │  primary → persist+order │
                │  shadow  → persist only  │
                └──────────────────────────┘
```

The router never blocks a tick — on probe failure or missing policy it falls back to Sonnet and explains why in its output.

---

## §2. `praescientia-router pick` contract

**Invocation:**

```
praescientia-router pick \
  --role=thesis-analyst|loss-reflector|market-screener \
  --policy=PATH                    # default: <kb_root>/.routing.json
  --ollama-url=URL                 # default: http://localhost:11434
  [--probe-cache-ms=N]             # default: 2000
```

**stdout (success):**

```json
{
  "role": "thesis-analyst",
  "decided_at_ms": 1747800000000,
  "variants": [
    {"backend": "ollama", "model": "qwen3.6:27b-mlx", "reason": "primary; loaded"}
  ],
  "probe": {
    "ollama_loaded": ["qwen3.6:27b-mlx", "bge-m3"],
    "ollama_tags":   ["qwen3.6:27b-mlx", "nemotron3:33b", "bge-m3"]
  }
}
```

A/B mode returns `variants` of length 2 (primary first, shadow second). Exit 0 always; failures surface as a `fallback` variant (Sonnet) and a `reason`.

**Policy file (`<kb_root>/.routing.json`):**

```json
{
  "thesis_analyst": {
    "primary":        {"backend": "ollama", "model": "qwen3.6:27b-mlx"},
    "fallback":       [{"backend": "ollama", "model": "nemotron3:33b"},
                       {"backend": "sonnet"}],
    "require_loaded": true,
    "shadow_with":    null
  },
  "loss_reflector": {
    "primary":  {"backend": "sonnet"},
    "fallback": []
  },
  "market_screener": {
    "primary":     {"backend": "ollama", "model": "qwen3.6:27b-mlx"},
    "fallback":    [{"backend": "sonnet"}],
    "shadow_with": {"backend": "ollama", "model": "nemotron3:33b"}
  }
}
```

`require_loaded: true` forces the router to check `model in /api/ps` before accepting the primary; on cold model it walks `fallback[]` in order. `shadow_with` triggers A/B (length-2 variants). If the policy file is missing, the router synthesizes an in-memory all-Sonnet policy — no breakage on a fresh checkout.

**Module split:** Pure logic (policy parsing, fallback evaluation, A/B emission) lives in `src/kb/routing.zig` and is fully unit-testable without HTTP. The CLI shell + `/api/ps` probe lives in `tools/router.zig`.

---

## §3. Dispatch & A/B execution flow

Per role, both the daemon (`tools/orchestrate_daemon.zig`) and the skill's `tick.md` follow:

```
1. Spawn:  praescientia-router pick --role=<role>
2. Parse:  variants[]    (len 1 normal, len 2 shadow)
3. For each variant, in order:
     if variant.backend == "sonnet":
       Agent({subagent_type: "praescientia-<role>",
              model: "sonnet",
              prompt: <role-prompt-JSON>})
     else:
       Bash("praescientia-ollama-agent \
              --role=<role> \
              --model=<variant.model> \
              --ollama-url=<url>")
        with <role-prompt-JSON> on stdin
4. Validate each decision via `praescientia-ticks validate ...`
5. Persist:
     primary  → existing path: thesis.decisions + thesis.commentary entry
     shadow   → thesis.commentary entry only, with:
                  variant:   "b"
                  tick_id:   <primary's tick_id>
                  shadow_of: <primary commentary cid>
                  dispatch:  {backend, model, router_decided_at_ms, reason}
                — never reaches orders/, never triggers Kalshi calls
6. Orders: only the primary's decision flows to order placement.
```

**Commentary schema delta** (`src/kb/commentary.zig`):

| Field | Type | Required when |
|---|---|---|
| `variant` | `?[]const u8` | optional; `"a"` (primary) or `"b"` (shadow); null for legacy |
| `shadow_of` | `?[]const u8` | required iff `variant == "b"`; CID of paired primary entry |
| `dispatch` | `?Dispatch` | optional; `{backend, model, router_decided_at_ms, reason}` for audit |

All three are nullable so existing chains keep validating. The validator (`praescientia-ticks validate`) requires `shadow_of` only when `variant == "b"`.

**Comparison surface:** New subcommand `praescientia-ticks compare --tick-id=ID` walks the commentary chain and prints primary + shadow decisions side-by-side (confidence_bp, rationale, orders[]) plus a diff summary. This is the discrete inspectable artifact the Hopper bet earns us — any tick's A/B is replayable from chain state, no model re-runs needed.

**Loss-reflector A/B:** Excluded from v1. Loss reflections are rare and cost-tolerant (per `feedback_haiku_no_signal_hard_floor` adjacent context); comparing two retrospectives on a closed position has marginal value. Policy file's `loss_reflector.shadow_with` is ignored with a warning logged to stderr.

---

## §4. `praescientia-ollama-agent` worker binary

The router decides *what* to run; this binary executes it. One binary, three roles via `--role`.

**Invocation:**

```
praescientia-ollama-agent \
  --role=thesis-analyst|loss-reflector|market-screener \
  --model=<ollama-tag>                # e.g. qwen3.6:27b-mlx
  --ollama-url=URL                    # default http://localhost:11434
  [--timeout-ms=N]                    # default 120000
  [--temperature=F]                   # default 0.2
  < stdin: role-specific prompt JSON  (same shape today's Agent receives)
  > stdout: validated JSON envelope   (same shape today's Agent returns)
```

**Exit codes:**

| Code | Meaning |
|---|---|
| 0 | Success; envelope on stdout |
| 2 | Ollama unreachable / model not loaded / HTTP timeout |
| 3 | Response JSON parse failure (after prose-strip retries) |
| 4 | Validator-incompatible envelope (e.g. missing `analysis` block) |

**Internal flow** (`tools/ollama_agent.zig`):

1. Read stdin → `prompt_payload` (JSON blob the dispatcher assembled).
2. Load the role's system prompt from `.claude/agents/praescientia-<role>.md` — **same prompt text the Sonnet path uses**, `@embedFile`-baked at build time so the binary is hermetic. The agent definition files are the single source of truth for role behavior; both backends inherit them.
3. `POST /api/chat` to Ollama with:
   ```json
   {
     "model": "<tag>",
     "messages": [
       {"role": "system", "content": "<role-md>"},
       {"role": "user",   "content": "<prompt_payload>"}
     ],
     "stream": false,
     "options": {"temperature": 0.2, "num_predict": 4096}
   }
   ```
4. Extract `message.content` from response.
5. **Prose-strip pipeline** (per `feedback_haiku_json_prose_prefix`): outer-`{}` substring scan, attempt `json.parse`. On failure: ```` ```json ```` fence extraction, then leading-prose strip. Local models leak prose worse than Haiku did — this is mandatory.
6. Emit parsed JSON to stdout. Exit 0.

**Decoupling:** This binary knows nothing about state chains, commentary persistence, or order placement. Pure prompt-in / JSON-out. The dispatcher owns validation, persistence, and order routing.

---

## §5. Embedding swap (Ollama BGE-M3)

The embedder change is mostly mechanical; the Protocol factoring is the one architectural choice that earns its keep next time we swap.

**New shape in `tools/indexer/index_commentary.py`:**

```python
class BGEEmbedder(Protocol):
    """Embedding backend contract. Implementations must return
    `len(texts)` vectors of `VECTOR_DIM` (1024) floats each."""
    def embed_batch(self, texts: list[str]) -> list[list[float]]: ...
    def close(self) -> None: ...


class OllamaEmbedder:
    """Posts to Ollama's /api/embed endpoint."""
    def __init__(self, base_url: str, model: str = "bge-m3",
                 timeout_s: float = 30.0): ...
    def embed_batch(self, texts):
        # POST {base_url}/api/embed
        # body: {"model": self.model, "input": texts}
        # resp: {"embeddings": [[float, ...], ...]}
        ...
    def close(self): ...
```

`LlamaServerEmbedder` is **deleted**. `EmbedderUnavailable` (already raised by the llama path) stays — `OllamaEmbedder` raises it on connection refused, non-200, missing/short `embeddings`, or per-vector dim mismatch. Downstream consumers (`run_once`, `run_loop`, `build_query_app`) already take an `embedder` by duck-typing; the type hint formalizes to the Protocol.

**CLI surface changes:**

| Old | New | Default |
|---|---|---|
| `--llama-url` | `--ollama-url` | `http://localhost:11434` |
| (n/a) | `--embed-model` | `bge-m3` |

**Tests** (`tools/indexer/test_indexer.py`): existing tests mock `embed_batch` on a fake embedder and keep working unchanged — the Protocol contract is preserved. Add `OllamaEmbedder` tests against `pytest-httpserver` stubs (200 valid, 404 model-not-found, connection-refused, dim mismatch).

**Smoke** (`scripts/commentary_smoke.sh`): replace llama-server bring-up with `ollama serve` + `ollama pull bge-m3`. Smoke remains end-to-end against a real local embedder.

**Docs**: `CLAUDE.md` (indexer line + tools table), `README.md` if it mentions the embedder.

---

## §6. Testing strategy

**Unit (Zig `test {}` blocks):**

| Surface | Test cases |
|---|---|
| `src/kb/routing.zig` | malformed policy JSON; missing role keys → all-Sonnet default; unknown fields ignored; fallback chain evaluation with stubbed `/api/ps` JSON; A/B variant emission |
| `tools/router.zig` | HTTP probe error → Sonnet fallback with `reason`; cache TTL respected |
| `tools/ollama_agent.zig` | prose-strip: bare, fenced, prose-prefix, prose-suffix, nested-`{}`-in-prose, trailing-comma JSON; HTTP error → exit 2; non-JSON body → exit 3; missing `analysis` block → exit 4 |
| `src/kb/commentary.zig` | new fields round-trip through canonical_json; legacy entries still validate |
| `tools/ticks.zig` | `compare --tick-id=ID` against golden fixture |

**Unit (Python):** `tools/indexer/test_indexer.py` adds `OllamaEmbedder` HTTP tests via `pytest-httpserver`.

**New smoke scripts:**

- `scripts/router_smoke.sh` — temp policy + stub HTTP server simulating `/api/ps`; runs `praescientia-router pick` for each role; asserts JSON output structure. No real Ollama required.
- `scripts/ollama_agent_smoke.sh` — gated by `OLLAMA_SMOKE=1`; requires real `ollama serve`; pipes canned thesis-analyst prompt to the binary; asserts a valid decision envelope.
- `scripts/commentary_smoke.sh` — updated to use Ollama instead of llama-server.
- `scripts/orchestrator_smoke.sh` — extended: run a second invocation with `market_screener.shadow_with` set, using the existing mock sub-agent fixtures; assert paired commentary entries appear with correct `variant`/`shadow_of` linkage.

**Goldens:**
- `tests/fixtures/decisions/ab_pair_primary.json` + `tests/fixtures/decisions/ab_pair_shadow.json` for `ticks compare`.

---

## §7. Staged rollout

| Stage | Deliverable | Verifiable by |
|---|---|---|
| 1 | Embedder Protocol + `OllamaEmbedder`; delete llama path; update tests + smoke | `pytest tools/indexer/test_indexer.py` + `scripts/commentary_smoke.sh` |
| 2 | `praescientia-ollama-agent` binary (no router yet); skill/daemon still Sonnet-only | `scripts/ollama_agent_smoke.sh` (gated) + `zig build test` |
| 3 | `praescientia-router` binary + policy schema + commentary schema extension | `scripts/router_smoke.sh` + `zig build test` |
| 4 | Wire router into `tools/orchestrate_daemon.zig` and `tick.md`; A/B persistence | extended `scripts/orchestrator_smoke.sh` |
| 5 | `praescientia-ticks compare` + docs sweep (CLAUDE.md, README) | manual `compare` invocation + doc review |

Each stage compiles and passes tests; lands as its own GitButler virtual branch; the system stays runnable after every stage.

---

## §8. File inventory

**New:**

| Path | Purpose |
|---|---|
| `src/kb/routing.zig` | Policy parser + fallback evaluator + A/B emission (pure logic) |
| `tools/router.zig` | `praescientia-router pick` CLI + `/api/ps` probe |
| `tools/ollama_agent.zig` | `praescientia-ollama-agent` CLI; `@embedFile`s role prompts; posts to `/api/chat` |
| `scripts/router_smoke.sh` | Router smoke with stubbed `/api/ps` |
| `scripts/ollama_agent_smoke.sh` | Live Ollama smoke (gated by `OLLAMA_SMOKE=1`) |
| `tests/fixtures/decisions/ab_pair_*.json` | Golden A/B pair for `ticks compare` |
| `docs/plans/2026-05-22-ollama-routing-design.md` | This doc |
| `docs/plans/2026-05-22-ollama-routing-implementation.md` | Stage-level IMPLEMENTATION_PLAN.md, written next |

**Modified:**

| Path | Change |
|---|---|
| `tools/indexer/index_commentary.py` | `BGEEmbedder` Protocol, `OllamaEmbedder`, delete llama path, rename `--llama-url` → `--ollama-url`, add `--embed-model` |
| `tools/indexer/test_indexer.py` | Type hints + new `OllamaEmbedder` HTTP tests |
| `scripts/commentary_smoke.sh` | Replace llama-server bring-up with `ollama serve` + `ollama pull bge-m3` |
| `src/kb/commentary.zig` | Add nullable `variant`, `shadow_of`, `dispatch` fields; update canonical_json |
| `src/kb/ticks.zig` | Validator accepts new fields; requires `shadow_of` only when `variant == "b"` |
| `tools/ticks.zig` | New `compare --tick-id=ID` subcommand |
| `tools/orchestrate_daemon.zig` | Per-role router invocation + dual-variant dispatch + shadow persistence |
| `.claude/skills/praescientia-orchestrate/tick.md` | Same dispatch flow expressed for the interactive skill |
| `.claude/skills/praescientia-orchestrate/SKILL.md` | Document `--policy=PATH`, `--ollama-url`, A/B behavior |
| `build.zig` | Two new binaries: `praescientia-router`, `praescientia-ollama-agent` |
| `CLAUDE.md` | Tools table + indexer line + Notes on routing policy |
| `scripts/orchestrator_smoke.sh` | A/B variant assertion |

**Deleted (in-file):** `LlamaServerEmbedder` class — no file deletions.

---

## §9. Open risks

1. **Local model JSON-following floor.** Per `feedback_haiku_no_signal_hard_floor`, even Haiku has a hard instruction-following floor on no-signal inputs; a 27B local model is likely worse. The prose-strip pipeline mitigates surface noise, but if Qwen3.6 outright refuses no-signal ticks the way Haiku did, we'll need a Sonnet fallback chain in the router policy (already supported — `fallback: [{backend:"sonnet"}]`). Document this in the Stage 4 runbook.
2. **VRAM pressure.** `qwen3.6:27b-mlx` (19 GB) + `nemotron3:33b` (27 GB) = ~46 GB. On a machine that can't hold both warm, the router probe sees only one in `/api/ps`; the cold one triggers a load-on-call (10–60 s). A/B on the screener will swap models in and out unless both fit. Mitigation: `require_loaded: true` on shadow variants skips them silently when cold — A/B becomes best-effort, not blocking.
3. **`/api/ps` race.** Between router probe and agent invocation, Ollama may evict the model from VRAM. Worker exit 2 + dispatcher retry-with-fallback handles it; adds latency. Acceptable for v1.
4. **Commentary schema migration.** New nullable fields are forward-compatible by construction. The Zig validator's `?T = null` pattern (per `project_validate_null_commentary_body_bug` lessons) makes this straightforward — but is the single thing worth explicit golden-fixture coverage in Stage 3.
5. **Skill/daemon dispatch drift.** Two implementations of the same logic (`tick.md` and `orchestrate_daemon.zig`). The router binary minimizes drift — both sides just shell out to it — but the call sites still need to be kept in sync. Known cost of the existing dual-locus design.

---

*Dispatch decisions are state. State should be discrete, hashed, and replayable. That's the bet.*

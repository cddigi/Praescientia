"""Praescientia commentary indexer + query service.

Single process, two roles:

  1. Loop:  scan kb_root commentary chains, embed unindexed entries via
            an Ollama daemon, write rows into LanceDB, advance per-scope
            cursors.
  2. Serve: FastAPI app exposing /similar (k-NN over the Lance table) and
            /health (row count).

The Lance index is disposable — `rm -rf <kb_root>/.commentary_index && restart`
rebuilds from the chain. The chain is canonical.
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Iterator, Optional, Protocol, runtime_checkable

import httpx
import lancedb
import pyarrow as pa


VECTOR_DIM = 1024  # BGE-M3 dense output


@runtime_checkable
class BGEEmbedder(Protocol):
    """Embedding backend contract. Implementations must return
    `len(texts)` vectors of `VECTOR_DIM` (1024) floats each.
    Raises EmbedderUnavailable on any backend failure.

    close() releases any underlying client; not required to be idempotent."""

    def embed_batch(self, texts: list[str]) -> list[list[float]]: ...
    def close(self) -> None: ...


class EmbedderUnavailable(RuntimeError):
    """Raised when the embedder HTTP call fails for any transport or
    shape-validation reason.

    Caller decides whether to back off + retry — for the indexer loop, the
    cursor stays put and we sleep until the next pass.
    """


def tail(jsonl_path: Path, after_hash: Optional[str]) -> Iterator[dict]:
    """Stream chain entries newer than `after_hash` from a single .jsonl file.

    Lifecycle:
      - Returns nothing if the file doesn't exist (a freshly admitted scope
        with no writes yet).
      - Skips the final line if it lacks a trailing newline — that's a
        torn write the Zig writer will recover on the next openForWrite.
        We just observe the safe prefix.
      - When `after_hash` is given, yields entries strictly *after* the
        matching entry on the chain. If the cursor hash isn't on the chain
        (e.g. a fork), behaves as if `after_hash=None` so the indexer
        doesn't silently stall.
    """
    if not jsonl_path.exists():
        return

    raw = jsonl_path.read_text()
    if not raw:
        return

    # Drop torn final line — anything after the last '\n' is partial.
    if not raw.endswith("\n"):
        last_nl = raw.rfind("\n")
        if last_nl == -1:
            return  # entire file is a torn partial line
        raw = raw[: last_nl + 1]

    entries: list[dict] = []
    for line in raw.split("\n"):
        if not line:
            continue
        try:
            entries.append(json.loads(line))
        except json.JSONDecodeError:
            # Malformed line — skip rather than crash. Chain integrity is the
            # Zig side's responsibility; the indexer is a read-only consumer.
            continue

    if after_hash is None:
        yield from entries
        return

    found = False
    for entry in entries:
        if found:
            yield entry
        elif entry.get("hash") == after_hash:
            found = True

    if not found:
        # Cursor hash isn't on the chain — replay from the beginning to avoid
        # silent stalls when a branch has been forked underneath us.
        yield from entries


class Cursors:
    """Per-scope `last indexed hash` persistence.

    File shape (`<kb_root>/.commentary_index/cursors.json`):

      {
        "theses/sample/commentary":   "abc...64-hex",
        "markets/KXBTC/commentary":   "def...64-hex",
        "commentary/global":          "012...64-hex"
      }

    Missing file == empty dict. Writes are atomic (temp-file + rename) so a
    crash mid-write can't leave a half-written cursors.json on disk.
    """

    def __init__(self, path: Path) -> None:
        self.path = path

    def read(self) -> dict[str, str]:
        if not self.path.exists():
            return {}
        return json.loads(self.path.read_text())

    def write(self, cursors: dict[str, str]) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        tmp = self.path.with_suffix(self.path.suffix + ".tmp")
        tmp.write_text(json.dumps(cursors, sort_keys=True))
        tmp.replace(self.path)


class OllamaEmbedder:
    """Posts to a long-lived Ollama daemon's `/api/embed` endpoint.

    Endpoint contract — Ollama's /api/embed accepts
    `{"model": "<name>", "input": ["text1", ...]}` and returns
    `{"embeddings": [[...vec...], ...]}` (one vector per input, in order).

    All HTTP failures and shape mismatches surface as `EmbedderUnavailable`
    so the indexer loop can skip the scope without crashing.
    """

    def __init__(
        self,
        base_url: str,
        model: str = "bge-m3",
        timeout_s: float = 30.0,
    ) -> None:
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
        try:
            payload = resp.json()
        except ValueError as e:
            raise EmbedderUnavailable(
                f"ollama /api/embed returned non-JSON body: {e}"
            ) from e
        if not isinstance(payload, dict):
            raise EmbedderUnavailable(
                f"unexpected /api/embed response: expected object, got {type(payload).__name__}"
            )
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


# ----- LanceDB ---------------------------------------------------------------

LANCE_TABLE_NAME = "commentary"

LANCE_SCHEMA = pa.schema(
    [
        pa.field("hash", pa.string()),
        pa.field("vector", pa.list_(pa.float32(), VECTOR_DIM)),
        pa.field("scope_path", pa.string()),
        pa.field("agent_run_id", pa.string()),
        pa.field("tags", pa.list_(pa.string())),
        pa.field("ts", pa.int64()),
    ]
)


def open_or_create_table(lance_dir: Path):
    """Open the commentary Lance table, creating an empty one with the right
    schema if it doesn't exist yet.

    LanceDB's sync `list_tables()` is async-only in some versions, so we
    `open_table` first and fall back to `create_table` on miss.
    """
    lance_dir = Path(lance_dir)
    lance_dir.mkdir(parents=True, exist_ok=True)
    db = lancedb.connect(str(lance_dir))
    try:
        return db.open_table(LANCE_TABLE_NAME)
    except (FileNotFoundError, ValueError):
        empty = pa.Table.from_pylist([], schema=LANCE_SCHEMA)
        return db.create_table(LANCE_TABLE_NAME, data=empty, schema=LANCE_SCHEMA)


def insert_rows(table, rows: list[dict]) -> None:
    """Append rows to the table. No-op on empty input.

    Rows must have all six columns: hash, vector (1024-len list), scope_path,
    agent_run_id, tags (list of strings), ts (int64 ms).
    """
    if not rows:
        return
    arrow_table = pa.Table.from_pylist(rows, schema=LANCE_SCHEMA)
    table.add(arrow_table)


# ----- Main loop -------------------------------------------------------------


def _discover_scopes(kb_root: Path) -> list[tuple[str, Path]]:
    """Return [(scope_path, jsonl_path), ...] for every commentary chain under kb_root.

    Walks `theses/*/commentary`, `markets/*/commentary`, and the single
    `commentary/global` path. Caller-side filtering by .exists() is the
    chain-tail reader's job.
    """
    scopes: list[tuple[str, Path]] = []
    theses_dir = kb_root / "theses"
    if theses_dir.is_dir():
        for sub in sorted(theses_dir.iterdir()):
            if not sub.is_dir():
                continue
            jsonl = sub / "commentary" / "main.jsonl"
            scopes.append((f"theses/{sub.name}/commentary", jsonl))

    markets_dir = kb_root / "markets"
    if markets_dir.is_dir():
        for sub in sorted(markets_dir.iterdir()):
            if not sub.is_dir():
                continue
            jsonl = sub / "commentary" / "main.jsonl"
            scopes.append((f"markets/{sub.name}/commentary", jsonl))

    global_jsonl = kb_root / "commentary" / "global" / "main.jsonl"
    scopes.append(("commentary/global", global_jsonl))

    return scopes


_FM_PREFIX = "--- src: "
_FM_SUFFIX = " ---"


def strip_source_frontmatter(body: str) -> str:
    """Remove a leading source-provenance frontmatter line before embedding.

    Curator-written (source-backed) entries lead with:

        --- src: <url> fetched: <iso8601> valid_until: <iso8601> ---\\n

    That line is provenance metadata, not prose — embedding it would pollute
    the vector with URLs and timestamps and pull unrelated sources together by
    their shared frontmatter shape. Strip it so similarity reflects content.

    Bodies without the frontmatter prefix (every pre-curator entry, and any
    model_synthesis entry) are returned unchanged. Must agree byte-for-byte
    with `parseFrontmatter`/`stripFrontmatter` in src/kb/commentary.zig.
    """
    if not body.startswith(_FM_PREFIX):
        return body
    nl = body.find("\n")
    if nl == -1:
        # Body is only a frontmatter line — nothing but metadata to embed.
        return ""
    if not body[:nl].endswith(_FM_SUFFIX):
        return body  # malformed; leave as-is rather than mangle the prose
    return body[nl + 1 :]


def _row_from_entry(entry: dict, scope_path: str, vector: list[float]) -> dict:
    payload = entry.get("payload", {}) or {}
    agent = payload.get("agent", {}) or {}
    return {
        "hash": entry["hash"],
        "vector": vector,
        "scope_path": scope_path,
        "agent_run_id": str(agent.get("run_id", "")),
        "tags": [str(t) for t in (payload.get("tags") or [])],
        "ts": int(payload.get("ts", 0)),
    }


def run_once(*, kb_root: Path, lance_dir: Path, embedder: BGEEmbedder, verbose: bool = False) -> int:
    """One pass over every commentary scope. Returns the number of newly
    indexed rows. Embedder failures (`EmbedderUnavailable`) leave the cursor
    untouched for that scope and the loop continues to the next.
    """
    kb_root = Path(kb_root)
    lance_dir = Path(lance_dir)

    table = open_or_create_table(lance_dir)
    cursors_file = Cursors(kb_root / ".commentary_index" / "cursors.json")
    cursors = cursors_file.read()
    indexed_total = 0

    for scope_path, jsonl_path in _discover_scopes(kb_root):
        last_hash = cursors.get(scope_path)
        new_entries = list(tail(jsonl_path, after_hash=last_hash))
        if not new_entries:
            continue

        bodies = [
            strip_source_frontmatter((e.get("payload") or {}).get("body", ""))
            for e in new_entries
        ]
        try:
            vectors = embedder.embed_batch(bodies)
        except EmbedderUnavailable as e:
            if verbose:
                print(f"[indexer] skip {scope_path}: {e}")
            continue

        if len(vectors) != len(new_entries):
            if verbose:
                print(
                    f"[indexer] skip {scope_path}: embedder returned {len(vectors)} vectors "
                    f"for {len(new_entries)} entries"
                )
            continue

        rows = [_row_from_entry(e, scope_path, v) for e, v in zip(new_entries, vectors)]
        insert_rows(table, rows)
        indexed_total += len(rows)

        # Advance the cursor to the head of what we just indexed.
        cursors[scope_path] = new_entries[-1]["hash"]
        cursors_file.write(cursors)

    return indexed_total


def run_loop(
    *,
    kb_root: Path,
    lance_dir: Path,
    embedder: BGEEmbedder,
    interval_seconds: float = 60.0,
    verbose: bool = False,
) -> None:
    """Forever-loop: run_once, sleep, repeat. Ctrl-C exits cleanly."""
    import time

    while True:
        try:
            run_once(kb_root=kb_root, lance_dir=lance_dir, embedder=embedder, verbose=verbose)
        except Exception as e:  # noqa: BLE001
            print(f"[indexer] iteration failed: {e!r}")
        time.sleep(interval_seconds)


# ----- Query service ---------------------------------------------------------

from pydantic import BaseModel, Field  # noqa: E402  (import here so the module loads even without fastapi-only deps)


class SimilarRequest(BaseModel):
    """Request body for POST /similar — k-NN over the commentary index by hash anchor."""

    anchor_hash: str = Field(..., min_length=64, max_length=64)
    limit: int = Field(10, ge=1, le=200)
    exclude_scopes: list[str] = Field(default_factory=list)
    min_ts: Optional[int] = None


def build_query_app(table, *, lance_dir: Path | None = None):
    """Build a FastAPI app exposing POST /similar and GET /health.

    `table` is a LanceDB table handle as returned by `open_or_create_table` —
    used directly when `lance_dir` is None (tests). In serve mode the
    background indexer loop opens its own handle and writes new rows, so the
    handlers re-open the table per request (via `lance_dir`) to see them.
    """
    from fastapi import FastAPI, HTTPException

    def _table():
        if lance_dir is not None:
            return open_or_create_table(Path(lance_dir))
        return table

    app = FastAPI(title="Praescientia commentary query")

    @app.get("/health")
    def health() -> dict:
        n = _table().to_arrow().num_rows
        return {"status": "ok", "indexed_rows": n}

    @app.post("/similar")
    def similar(req: SimilarRequest) -> dict:
        t = _table()
        # 1. Look up the anchor's vector.
        rows = t.to_arrow().to_pylist()
        anchor = next((r for r in rows if r["hash"] == req.anchor_hash), None)
        if anchor is None:
            raise HTTPException(status_code=404, detail=f"anchor_hash not indexed: {req.anchor_hash}")

        # 2. Run k-NN. Lance returns rows in similarity order, with a
        #    `_distance` column we map to `score`.
        # Ask for limit + 1 + len(exclude_scopes) so post-filtering can
        # still leave us `limit` neighbors.
        query_limit = req.limit + 1 + len(req.exclude_scopes) * req.limit
        results = (
            t.search(anchor["vector"])
            .limit(query_limit)
            .to_arrow()
            .to_pylist()
        )

        filtered: list[dict] = []
        for row in results:
            if row["hash"] == req.anchor_hash:
                continue
            if row["scope_path"] in req.exclude_scopes:
                continue
            if req.min_ts is not None and row["ts"] < req.min_ts:
                continue
            filtered.append(
                {
                    "hash": row["hash"],
                    "scope_path": row["scope_path"],
                    "score": float(row.get("_distance", 0.0)),
                    "ts": int(row["ts"]),
                    "tags": list(row.get("tags") or []),
                }
            )
            if len(filtered) >= req.limit:
                break

        return {"results": filtered}

    return app


# ----- CLI entry --------------------------------------------------------------


def build_arg_parser():
    import argparse

    p = argparse.ArgumentParser(prog="praescientia-indexer", description="Commentary indexer + query service")
    p.add_argument("--kb-root", required=True, type=Path, help="Path to the praescientia kb_root")
    p.add_argument("--ollama-url", default="http://localhost:11434", help="Ollama daemon base URL")
    p.add_argument(
        "--embed-model",
        default="bge-m3",
        help="Embedding model tag to request from Ollama (default: bge-m3)",
    )
    p.add_argument(
        "--lance-dir",
        type=Path,
        default=None,
        help="LanceDB directory (default: <kb_root>/.commentary_index/lance)",
    )
    p.add_argument("--once", action="store_true", help="Single pass then exit")
    p.add_argument("--interval", type=float, default=60.0, help="Loop interval in seconds (default 60)")
    p.add_argument("--query-port", type=int, default=8002, help="Port for the /similar service")
    p.add_argument("--serve", action="store_true", help="Run the query service alongside the loop")
    p.add_argument("--verbose", action="store_true")
    return p


def _parse_args(argv: Optional[list[str]] = None):
    return build_arg_parser().parse_args(argv)


def main(argv: Optional[list[str]] = None) -> int:
    args = _parse_args(argv)
    lance_dir = args.lance_dir or (args.kb_root / ".commentary_index" / "lance")
    embedder = OllamaEmbedder(args.ollama_url, model=args.embed_model)
    try:
        if args.once:
            indexed = run_once(
                kb_root=args.kb_root, lance_dir=lance_dir, embedder=embedder, verbose=args.verbose
            )
            print(f"indexed {indexed} new entries")
            return 0

        if args.serve:
            return _run_serve_and_loop(
                kb_root=args.kb_root,
                lance_dir=lance_dir,
                embedder=embedder,
                interval=args.interval,
                query_port=args.query_port,
                verbose=args.verbose,
            )

        # Default: loop forever, no query service.
        run_loop(
            kb_root=args.kb_root,
            lance_dir=lance_dir,
            embedder=embedder,
            interval_seconds=args.interval,
            verbose=args.verbose,
        )
        return 0
    finally:
        embedder.close()


def _run_serve_and_loop(
    *,
    kb_root: Path,
    lance_dir: Path,
    embedder: BGEEmbedder,
    interval: float,
    query_port: int,
    verbose: bool,
) -> int:
    """Run the indexer loop in a background thread + the FastAPI query service
    in the foreground. Single process, both roles."""
    import threading

    import uvicorn

    # Open or create the table once; both the loop and the app share this handle.
    table = open_or_create_table(lance_dir)

    def _loop():
        import time

        while True:
            try:
                run_once(kb_root=kb_root, lance_dir=lance_dir, embedder=embedder, verbose=verbose)
            except Exception as e:  # noqa: BLE001
                print(f"[indexer] iteration failed: {e!r}")
            time.sleep(interval)

    t = threading.Thread(target=_loop, name="commentary-indexer-loop", daemon=True)
    t.start()

    app = build_query_app(table, lance_dir=lance_dir)
    uvicorn.run(app, host="127.0.0.1", port=query_port, log_level="warning")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

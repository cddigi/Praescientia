"""Praescientia commentary indexer + query service.

Single process, two roles:

  1. Loop:  scan kb_root commentary chains, embed unindexed entries via
            llama-server, write rows into LanceDB, advance per-scope cursors.
  2. Serve: FastAPI app exposing /similar (k-NN over the Lance table) and
            /health (row count).

The Lance index is disposable — `rm -rf <kb_root>/.commentary_index && restart`
rebuilds from the chain. The chain is canonical.
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Iterator, Optional

import httpx
import lancedb
import pyarrow as pa


VECTOR_DIM = 1024  # BGE-M3 dense output


class EmbedderUnavailable(RuntimeError):
    """Raised when the llama-server HTTP call fails for any transport reason.

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


class LlamaServerEmbedder:
    """Posts to a long-lived llama-server `--embeddings` daemon.

    Endpoint contract — llama.cpp's /embedding accepts `{"input": ["text1", ...]}`
    and returns either:
      - the OpenAI-compatible shape: `[{"embedding": [...]}, ...]`
      - the legacy shape:            `[[...vec...], ...]`

    Both are handled.
    """

    def __init__(self, base_url: str, *, client=None, timeout: float = 60.0) -> None:
        self.base_url = base_url.rstrip("/")
        self.timeout = timeout
        self._owns_client = client is None
        self._client = client if client is not None else httpx.Client(timeout=timeout)

    def close(self) -> None:
        if self._owns_client:
            self._client.close()

    def embed_batch(self, texts: list[str]) -> list[list[float]]:
        if not texts:
            return []
        url = f"{self.base_url}/embedding"
        try:
            resp = self._client.post(url, json={"input": texts}, timeout=self.timeout)
            resp.raise_for_status()
            payload = resp.json()
        except (httpx.TransportError, httpx.HTTPStatusError) as e:
            raise EmbedderUnavailable(f"llama-server unreachable at {url}: {e}") from e

        # Handle both response shapes. OpenAI-compatible has `data` wrapper too
        # depending on build; tolerate it.
        if isinstance(payload, dict) and "data" in payload:
            payload = payload["data"]
        if not isinstance(payload, list):
            raise EmbedderUnavailable(f"unexpected /embedding response shape: {type(payload)}")

        vectors: list[list[float]] = []
        for item in payload:
            if isinstance(item, dict) and "embedding" in item:
                vectors.append(list(item["embedding"]))
            elif isinstance(item, list):
                vectors.append(list(item))
            else:
                raise EmbedderUnavailable(f"unexpected /embedding row shape: {type(item)}")
        return vectors


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

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

"""Pytest suite for index_commentary.py.

Run via `pytest tools/indexer/` from the project root.

llama-server is NOT required — the embed call is mocked.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

import index_commentary as ic


def _write_jsonl_chain(chain_dir: Path, entries: list[dict]) -> None:
    """Hand-craft a JSONL chain file with the given prev_hash/hash/payload entries."""
    chain_dir.mkdir(parents=True, exist_ok=True)
    lines = [json.dumps(entry, sort_keys=False) for entry in entries]
    (chain_dir / "main.jsonl").write_text("\n".join(lines) + "\n")


def test_tail_returns_entries_after_cursor(tmp_path: Path) -> None:
    chain_dir = tmp_path / "theses" / "sample" / "commentary"
    _write_jsonl_chain(
        chain_dir,
        [
            {"tx_id": "tx_a", "prev_hash": "0" * 64, "hash": "a" * 64, "payload": {"body": "1"}},
            {"tx_id": "tx_b", "prev_hash": "a" * 64, "hash": "b" * 64, "payload": {"body": "2"}},
            {"tx_id": "tx_c", "prev_hash": "b" * 64, "hash": "c" * 64, "payload": {"body": "3"}},
        ],
    )
    entries = list(ic.tail(chain_dir / "main.jsonl", after_hash="a" * 64))
    assert [e["hash"] for e in entries] == ["b" * 64, "c" * 64]


def test_tail_yields_everything_when_after_hash_is_none(tmp_path: Path) -> None:
    chain_dir = tmp_path / "commentary" / "global"
    _write_jsonl_chain(
        chain_dir,
        [
            {"tx_id": "tx_a", "prev_hash": "0" * 64, "hash": "a" * 64, "payload": {"body": "one"}},
            {"tx_id": "tx_b", "prev_hash": "a" * 64, "hash": "b" * 64, "payload": {"body": "two"}},
        ],
    )
    entries = list(ic.tail(chain_dir / "main.jsonl", after_hash=None))
    assert [e["hash"] for e in entries] == ["a" * 64, "b" * 64]


def test_tail_yields_nothing_when_cursor_is_head(tmp_path: Path) -> None:
    chain_dir = tmp_path / "commentary" / "global"
    _write_jsonl_chain(
        chain_dir,
        [
            {"tx_id": "tx_a", "prev_hash": "0" * 64, "hash": "a" * 64, "payload": {"body": "one"}},
        ],
    )
    entries = list(ic.tail(chain_dir / "main.jsonl", after_hash="a" * 64))
    assert entries == []


def test_tail_skips_torn_final_line(tmp_path: Path) -> None:
    """A partial final line (no trailing newline) is a torn write — skip it.

    The Zig side recovers torn tails on the next openForWrite; we just observe
    the safe prefix.
    """
    chain_dir = tmp_path / "theses" / "x" / "commentary"
    chain_dir.mkdir(parents=True)
    good = json.dumps({"tx_id": "tx_a", "prev_hash": "0" * 64, "hash": "a" * 64, "payload": {"body": "ok"}})
    (chain_dir / "main.jsonl").write_text(good + "\n" + '{"tx_id":"tx_TORN')  # no newline
    entries = list(ic.tail(chain_dir / "main.jsonl", after_hash=None))
    assert [e["hash"] for e in entries] == ["a" * 64]


def test_tail_returns_empty_when_chain_missing(tmp_path: Path) -> None:
    # Not an error — newly admitted scope, no writes yet.
    entries = list(ic.tail(tmp_path / "nope.jsonl", after_hash=None))
    assert entries == []


def test_cursors_read_missing_returns_empty(tmp_path: Path) -> None:
    c = ic.Cursors(tmp_path / ".commentary_index" / "cursors.json")
    assert c.read() == {}


def test_cursors_write_then_read(tmp_path: Path) -> None:
    path = tmp_path / ".commentary_index" / "cursors.json"
    c = ic.Cursors(path)
    c.write({"theses/sample/commentary": "a" * 64, "commentary/global": "b" * 64})
    assert c.read() == {"theses/sample/commentary": "a" * 64, "commentary/global": "b" * 64}


def test_cursors_write_is_atomic(tmp_path: Path) -> None:
    """The write must not leave a half-written cursors.json under any failure mode.

    We can't easily fault-inject here, so we just assert that no .tmp file
    survives a successful write — proves the rename happened.
    """
    path = tmp_path / ".commentary_index" / "cursors.json"
    c = ic.Cursors(path)
    c.write({"k": "v"})
    leftover = list(path.parent.glob("*.tmp"))
    assert leftover == []


def test_cursors_overwrites_prior_value(tmp_path: Path) -> None:
    path = tmp_path / "cursors.json"
    c = ic.Cursors(path)
    c.write({"k": "v1"})
    c.write({"k": "v2"})
    assert c.read() == {"k": "v2"}

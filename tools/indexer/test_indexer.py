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


class _FakeHttpClient:
    """Minimal stand-in for httpx.Client to avoid the network in unit tests."""

    def __init__(self, response_payload, *, raises: BaseException | None = None) -> None:
        self.response_payload = response_payload
        self.raises = raises
        self.last_url: str | None = None
        self.last_json: dict | None = None

    def post(self, url: str, *, json: dict, timeout: float | None = None):  # noqa: A002
        self.last_url = url
        self.last_json = json
        if self.raises:
            raise self.raises

        class _R:
            def __init__(self, payload):
                self._payload = payload

            def raise_for_status(self):
                return None

            def json(self):
                return self._payload

        return _R(self.response_payload)

    def close(self) -> None:
        pass


def test_embed_batch_calls_llama_server_with_input_list() -> None:
    # llama-server's /embedding returns one object per input with .embedding.
    fake = _FakeHttpClient([{"embedding": [0.0] * 1024}, {"embedding": [1.0] * 1024}])
    embedder = ic.LlamaServerEmbedder("http://localhost:8001", client=fake)

    vectors = embedder.embed_batch(["hello", "world"])

    assert fake.last_url == "http://localhost:8001/embedding"
    assert fake.last_json == {"input": ["hello", "world"]}
    assert len(vectors) == 2
    assert vectors[0][0] == 0.0
    assert vectors[1][0] == 1.0
    assert all(len(v) == 1024 for v in vectors)


def test_embed_batch_handles_top_level_array_response() -> None:
    """Older llama-server builds return [[...vec...], ...] directly."""
    fake = _FakeHttpClient([[0.5] * 1024])
    embedder = ic.LlamaServerEmbedder("http://localhost:8001", client=fake)
    vectors = embedder.embed_batch(["solo"])
    assert vectors == [[0.5] * 1024]


def test_embed_batch_returns_empty_for_empty_input() -> None:
    fake = _FakeHttpClient([])
    embedder = ic.LlamaServerEmbedder("http://localhost:8001", client=fake)
    assert embedder.embed_batch([]) == []
    # Shouldn't even fire the HTTP call.
    assert fake.last_url is None


def test_embed_batch_raises_embedder_unavailable_on_network_error() -> None:
    import httpx

    fake = _FakeHttpClient(None, raises=httpx.ConnectError("nope"))
    embedder = ic.LlamaServerEmbedder("http://localhost:8001", client=fake)
    with pytest.raises(ic.EmbedderUnavailable):
        embedder.embed_batch(["x"])


def _make_row(hash_: str, *, scope_path="theses/sample/commentary", agent_run_id="r", tags=None, ts=1779000000000, vec_value=0.5):
    return {
        "hash": hash_,
        "vector": [vec_value] * 1024,
        "scope_path": scope_path,
        "agent_run_id": agent_run_id,
        "tags": list(tags) if tags else [],
        "ts": ts,
    }


def test_insert_rows_then_read_back(tmp_path: Path) -> None:
    table = ic.open_or_create_table(tmp_path / "lance")
    rows = [_make_row("a" * 64, vec_value=0.1), _make_row("b" * 64, vec_value=0.2)]
    ic.insert_rows(table, rows)

    arr = table.to_arrow()
    assert arr.num_rows == 2
    hashes = set(arr.column("hash").to_pylist())
    assert hashes == {"a" * 64, "b" * 64}
    # Vector column comes back as a list of float32 per row.
    by_hash = {row["hash"]: row for row in arr.to_pylist()}
    a_vec = by_hash["a" * 64]["vector"]
    assert len(a_vec) == 1024
    assert float(a_vec[0]) == pytest.approx(0.1)


def test_insert_rows_skips_empty(tmp_path: Path) -> None:
    table = ic.open_or_create_table(tmp_path / "lance")
    ic.insert_rows(table, [])
    assert table.to_arrow().num_rows == 0


def test_open_or_create_table_reuses_existing(tmp_path: Path) -> None:
    table_a = ic.open_or_create_table(tmp_path / "lance")
    ic.insert_rows(table_a, [_make_row("a" * 64)])

    table_b = ic.open_or_create_table(tmp_path / "lance")
    assert table_b.to_arrow().num_rows == 1

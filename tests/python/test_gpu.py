"""Tests for optional MAX GPU acceleration (`has_gpu`, `GpuTomlParser`)."""

from __future__ import annotations

import json
from pathlib import Path

import pytest

import motoml


def test_gpu_parser_or_cpu_fallback(tmp_path: Path) -> None:
    if not motoml.has_gpu():
        with pytest.raises(RuntimeError, match="MAX GPU support"):
            motoml.GpuTomlParser()
        return

    parser = motoml.GpuTomlParser(initial_capacity_bytes=512 * 1024, min_gpu_bytes=64)
    assert isinstance(parser.has_unified_memory, bool)
    parser.warmup()

    src = "\n".join(
        f'[[items]]\nid = {i}\nname = "item-{i}"\nactive = {"true" if i % 2 == 0 else "false"}\n'
        for i in range(100)
    )

    doc = parser.parse(src, force_gpu=True)
    assert len(doc["items"]) == 100
    assert doc["items"][42]["name"] == "item-42"
    assert doc.to_dict() == motoml.loads(src)

    loaded = parser.loads(src, force_gpu=True)
    assert loaded == motoml.loads(src)

    p = tmp_path / "gpu.toml"
    p.write_text(src, encoding="utf-8")
    assert parser.parse_file(p, force_gpu=True).to_dict() == loaded
    assert parser.load_file(p, force_gpu=True) == loaded

    # Batch GPU parse in a single launch
    docs = [f'id = {i}\nlabel = "doc-{i}"\n' for i in range(8)]
    batch = parser.parse_batch(docs, force_gpu=True)
    assert [d["id"] for d in batch] == list(range(8))
    assert [d["label"] for d in batch] == [f"doc-{i}" for i in range(8)]

    # GPU tagged JSON
    assert json.loads(parser.to_tagged_json(src, force_gpu=True)) == json.loads(
        motoml.to_tagged_json(src)
    )

    # Error propagation
    with pytest.raises(motoml.TOMLDecodeError):
        parser.loads("a = [unterminated", force_gpu=True)

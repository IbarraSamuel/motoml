"""Tests for `validate`, `to_tagged_json`, and GIL-free multithreaded parsing."""

from __future__ import annotations

import json
from concurrent.futures import ThreadPoolExecutor

import pytest

import motoml


def test_validate_and_to_tagged_json() -> None:
    src = 'name = "motoml"\nport = 8080\n'
    motoml.validate(src)
    motoml.validate(src.encode("utf-8"), mode="trusted")

    with pytest.raises(motoml.TOMLDecodeError):
        motoml.validate("a = 1\na = 2\n")

    tagged = json.loads(motoml.to_tagged_json(src))
    assert tagged == {
        "name": {"type": "string", "value": "motoml"},
        "port": {"type": "integer", "value": "8080"},
    }


def test_multithreaded_gil_released_parsing() -> None:
    corpus = "\n".join(
        f'[section_{i}]\nname = "svc-{i}"\nport = {8000 + i}\nenabled = true\n'
        for i in range(200)
    )

    def worker(idx: int) -> tuple[int, str]:
        motoml.validate(corpus)
        doc = motoml.parse(corpus)
        d = motoml.loads(corpus)
        assert d[f"section_{idx}"]["port"] == 8000 + idx
        return doc[f"section_{idx}"]["port"], doc[f"section_{idx}"]["name"]

    with ThreadPoolExecutor(max_workers=8) as pool:
        results = list(pool.map(worker, range(32)))

    assert results == [(8000 + i, f"svc-{i}") for i in range(32)]

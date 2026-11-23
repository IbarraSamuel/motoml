"""Tests for lazy native `TomlDocument` and `TomlView` API."""

from __future__ import annotations

import datetime
import json
from pathlib import Path

import pytest

import motoml

SAMPLE = """
title = "motoml"
count = 7
pi = 3.5
enabled = true
release = 2026-11-23
cutoff = 09:15:30.250
deployed = 2026-11-23T09:15:30Z

[server]
host = "0.0.0.0"
port = 8443

[[routes]]
path = "/health"
auth = false

[[routes]]
path = "/v1/orders"
auth = true
tags = ["core", "prod"]
"""


def test_parse_lazy_document_and_views() -> None:
    doc = motoml.parse(SAMPLE)
    assert isinstance(doc, motoml.TomlDocument)
    assert doc.kind == "table"
    assert len(doc) == 9
    assert "server" in doc
    assert "missing" not in doc

    assert doc["title"] == "motoml"
    assert doc["count"] == 7
    assert doc["pi"] == 3.5
    assert doc["enabled"] is True
    assert doc["release"] == datetime.date(2026, 11, 23)
    assert doc["cutoff"] == datetime.time(9, 15, 30, 250000)
    assert doc["deployed"] == datetime.datetime(
        2026, 11, 23, 9, 15, 30, tzinfo=datetime.timezone.utc
    )

    server = doc["server"]
    assert isinstance(server, motoml.TomlView)
    assert server.kind == "table"
    assert server["host"] == "0.0.0.0"
    assert server["port"] == 8443
    assert server.get("tls", False) is False
    assert server.keys() == ["host", "port"]
    assert list(server) == ["host", "port"]
    assert server.items() == [("host", "0.0.0.0"), ("port", 8443)]
    assert server.to_dict() == {"host": "0.0.0.0", "port": 8443}
    assert server == {"host": "0.0.0.0", "port": 8443}

    routes = doc["routes"]
    assert isinstance(routes, motoml.TomlView)
    assert routes.kind == "array"
    assert len(routes) == 2
    assert routes[0]["path"] == "/health"
    assert routes[-1]["path"] == "/v1/orders"
    assert routes[-1]["tags"][:] == ["core", "prod"]
    assert "core" in routes[-1]["tags"]
    assert "dev" not in routes[-1]["tags"]
    assert routes[-1]["tags"].to_list() == ["core", "prod"]
    assert [r["path"] for r in routes] == ["/health", "/v1/orders"]

    # Explicit scalar view
    title_view = doc.view("title")
    assert isinstance(title_view, motoml.TomlView)
    assert title_view.kind == "string"
    assert title_view.value == "motoml"

    # Full materialization parity
    assert doc.to_dict() == motoml.loads(SAMPLE)
    assert json.loads(doc.to_json()) == json.loads(motoml.to_tagged_json(SAMPLE))


def test_parse_file_lazy(tmp_path: Path) -> None:
    p = tmp_path / "app.toml"
    p.write_text(SAMPLE, encoding="utf-8")
    doc = motoml.parse_file(p)
    assert doc["server"]["port"] == 8443
    assert doc["routes"][1]["auth"] is True
    with pytest.raises(OSError):
        motoml.parse_file(tmp_path / "missing.toml")


def test_view_errors() -> None:
    doc = motoml.parse('a = [1, 2]\nb = "hi"\n')
    with pytest.raises(KeyError):
        _ = doc["nope"]
    with pytest.raises(IndexError):
        _ = doc["a"][10]
    with pytest.raises(TypeError):
        doc["a"].to_dict()
    with pytest.raises(TypeError):
        doc.to_list()
    with pytest.raises(motoml.TOMLDecodeError):
        motoml.parse("a = [unterminated")

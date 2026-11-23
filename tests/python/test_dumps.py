"""Tests for TOML 1.1 serialization (`dumps` / `dump`)."""

from __future__ import annotations

import datetime
import io
import math
import tomllib

import pytest

import motoml


def test_dumps_roundtrip_comprehensive() -> None:
    payload = {
        "title": "motoml",
        "quoted.key": 'hello "world"\n\t\\path',
        "count": 42,
        "negative": -999,
        "flag": True,
        "off": False,
        "ratio": 3.5,
        "whole_float": 2.0,
        "pos_inf": float("inf"),
        "neg_inf": float("-inf"),
        "date": datetime.date(2026, 11, 23),
        "time": datetime.time(14, 30, 5, 125000),
        "dt_local": datetime.datetime(2026, 11, 23, 8, 30, 0),
        "dt_utc": datetime.datetime(
            2026, 11, 23, 8, 30, 0, tzinfo=datetime.timezone.utc
        ),
        "dt_offset": datetime.datetime(
            2026,
            11,
            23,
            8,
            30,
            0,
            tzinfo=datetime.timezone(datetime.timedelta(hours=-5, minutes=-30)),
        ),
        "empty_list": [],
        "mixed_inline": [1, "two", {"inline": True, "vals": [3, 4]}],
        "empty_table": {},
        "server": {
            "host": "127.0.0.1",
            "port": 8080,
            "tls": {"enabled": True, "cert": "/etc/ssl/cert.pem"},
        },
        "routes": [
            {"path": "/health", "auth": False},
            {"path": "/v1/items", "auth": True, "methods": ["GET", "POST"]},
        ],
    }

    text = motoml.dumps(payload)
    assert "[server]" in text
    assert "[[routes]]" in text
    assert "[empty_table]" in text
    assert '"quoted.key"' in text

    reparsed_motoml = motoml.loads(text)
    reparsed_tomllib = tomllib.loads(text)
    assert reparsed_motoml == payload
    assert reparsed_tomllib == payload


def test_dumps_nan() -> None:
    text = motoml.dumps({"x": float("nan")})
    assert text.strip() == "x = nan"
    assert math.isnan(motoml.loads(text)["x"])


def test_dump_text_and_binary_streams() -> None:
    data = {"app": {"name": "demo", "workers": 4}}
    sbuf = io.StringIO()
    motoml.dump(data, sbuf)
    assert motoml.loads(sbuf.getvalue()) == data

    bbuf = io.BytesIO()
    motoml.dump(data, bbuf)
    assert motoml.loads(bbuf.getvalue()) == data


def test_dumps_error_cases() -> None:
    with pytest.raises(TypeError):
        motoml.dumps([1, 2, 3])  # type: ignore[arg-type]
    with pytest.raises(TypeError):
        motoml.dumps({"a": None})
    with pytest.raises(TypeError):
        motoml.dumps({1: "bad"})  # type: ignore[dict-item]
    with pytest.raises(OverflowError):
        motoml.dumps({"huge": 1 << 80})
    with pytest.raises(ValueError):
        motoml.dumps({"t": datetime.time(12, 0, tzinfo=datetime.timezone.utc)})

    # Cyclic dict hits nesting depth limit cleanly
    cyclic: dict[str, object] = {}
    cyclic["self"] = cyclic
    with pytest.raises(ValueError, match="depth"):
        motoml.dumps(cyclic)

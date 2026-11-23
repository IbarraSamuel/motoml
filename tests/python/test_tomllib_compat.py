"""PEP 680 `tomllib` compatibility & official TOML 1.1 test-suite tests."""

from __future__ import annotations

import datetime
import decimal
import io
import json
import math
import tomllib
from pathlib import Path

import pytest

import motoml

TOML_TEST_ROOT = Path(__file__).resolve().parents[2] / "tests" / "toml_files" / "tests"


def test_loads_basic_types_and_tomllib_parity() -> None:
    src = """
    title = "api-gateway"
    escaped = "line1\\nline2\\t\\"quoted\\"\\\\\\u00e9"
    literal = 'C:\\Users\\new'
    count = 42
    neg = -1_000_000
    hex_val = 0xdead_beef
    pi = 3.14159
    inf_val = inf
    ninf_val = -inf
    nan_val = nan
    flag = true
    off = false
    d = 2026-11-21
    t = 14:30:05.123456789
    dt_local = 2026-11-21T08:30:00.5
    dt_utc = 2026-11-21T08:30:00Z
    dt_neg_zero = 2026-11-21T08:30:00-00:00
    dt_off = 2026-11-21T08:30:00+05:30

    [server]
    host = "127.0.0.1"
    port = 8080

    [[routes]]
    path = "/health"
    auth = false

    [[routes]]
    path = "/v1/users"
    auth = true
    """
    got = motoml.loads(src)
    expected = tomllib.loads(src)

    assert math.isnan(got.pop("nan_val"))
    assert math.isnan(expected.pop("nan_val"))
    assert got == expected
    assert got["dt_utc"].tzinfo is datetime.timezone.utc
    assert got["dt_neg_zero"].tzinfo is datetime.timezone.utc
    assert got["t"] == datetime.time(14, 30, 5, 123456)
    assert got["d"] == datetime.date(2026, 11, 21)


def test_loads_bytes_and_bytearray() -> None:
    raw = b'name = "motoml"\nnums = [1, 2, 3]\n'
    assert motoml.loads(raw) == {"name": "motoml", "nums": [1, 2, 3]}
    assert motoml.loads(bytearray(raw)) == {"name": "motoml", "nums": [1, 2, 3]}


def test_loads_parse_float_decimal() -> None:
    src = "a = 1_000.5\nb = +nan\nc = -inf\nd = [0.1, 0.2]\n"
    got = motoml.loads(src, parse_float=decimal.Decimal)
    assert got["a"] == decimal.Decimal("1000.5")
    assert isinstance(got["a"], decimal.Decimal)
    assert got["b"].is_nan()
    assert got["c"] == decimal.Decimal("-Infinity")
    assert got["d"] == [decimal.Decimal("0.1"), decimal.Decimal("0.2")]


def test_loads_trusted_mode() -> None:
    src = 'host = "localhost"\nport = 9000\nratio = 0.75\n'
    assert motoml.loads(src, mode="trusted") == {
        "host": "localhost",
        "port": 9000,
        "ratio": 0.75,
    }
    with pytest.raises(ValueError, match="mode"):
        motoml.loads(src, mode="invalid")  # type: ignore[arg-type]


def test_loads_type_errors() -> None:
    with pytest.raises(TypeError):
        motoml.loads(123)  # type: ignore[arg-type]


def test_load_binary_and_text_streams() -> None:
    src = 'k = "v"\n[a]\nb = 1\n'
    assert motoml.load(io.BytesIO(src.encode("utf-8"))) == {"k": "v", "a": {"b": 1}}
    assert motoml.load(io.StringIO(src)) == {"k": "v", "a": {"b": 1}}


def test_load_file_mmap(tmp_path: Path) -> None:
    p = tmp_path / "config.toml"
    p.write_text('service = "edge"\n[limits]\nmax_conns = 1024\n', encoding="utf-8")
    assert motoml.load_file(p) == {"service": "edge", "limits": {"max_conns": 1024}}
    assert motoml.load_file(str(p), mode="trusted") == {
        "service": "edge",
        "limits": {"max_conns": 1024},
    }
    with pytest.raises(OSError):
        motoml.load_file(tmp_path / "does_not_exist.toml")


def test_decode_error_subclasses_value_error() -> None:
    assert issubclass(motoml.TOMLDecodeError, ValueError)
    with pytest.raises(motoml.TOMLDecodeError) as exc_info:
        motoml.loads("a = 1\na = 2\n")
    err = exc_info.value
    assert isinstance(err, ValueError)
    assert err.lineno == 2


def _tagged_equal(got: object, exp: object) -> bool:
    """Semantic `toml-test` tagged JSON equality (matching toml-test rules)."""
    if isinstance(got, list) and isinstance(exp, list):
        return len(got) == len(exp) and all(
            _tagged_equal(a, b) for a, b in zip(got, exp, strict=True)
        )
    if isinstance(got, dict) and isinstance(exp, dict):
        if set(got.keys()) == {"type", "value"} and set(exp.keys()) == {
            "type",
            "value",
        } and isinstance(got["type"], str) and isinstance(exp["type"], str):
            t = exp["type"]
            if got["type"] != t:
                return False
            gv, ev = str(got["value"]), str(exp["value"])
            if t == "float":
                gf, ef = float(gv), float(ev)
                if math.isnan(gf) and math.isnan(ef):
                    return True
                return gf == ef
            if t in ("datetime", "datetime-local"):
                return datetime.datetime.fromisoformat(
                    gv.replace(" ", "T")
                ) == datetime.datetime.fromisoformat(ev.replace(" ", "T"))
            if t == "time-local":
                return datetime.time.fromisoformat(
                    gv
                ) == datetime.time.fromisoformat(ev)
            return gv == ev
        if set(got.keys()) != set(exp.keys()):
            return False
        return all(_tagged_equal(got[k], exp[k]) for k in exp)
    return got == exp


def test_official_toml_1_1_suite() -> None:
    """Verify 100% pass rate on the bundled official toml-test 1.1.0 corpus."""
    list_file = TOML_TEST_ROOT / "files-toml-1.1.0"
    if not list_file.is_file():
        pytest.skip("Official toml-test 1.1.0 files not present")

    entries = [line.strip() for line in list_file.read_text().splitlines() if line.strip()]
    valid_count = 0
    invalid_count = 0
    for rel in entries:
        if not rel.endswith(".toml"):
            continue
        path = TOML_TEST_ROOT / rel
        raw = path.read_bytes()
        if rel.startswith("valid/"):
            valid_count += 1
            # Validate both dict materialization and tagged JSON output
            parsed = motoml.loads(raw)
            assert isinstance(parsed, dict)
            expected_json = path.with_suffix(".json")
            if expected_json.is_file():
                got_tagged = json.loads(motoml.to_tagged_json(raw))
                exp_tagged = json.loads(expected_json.read_text(encoding="utf-8"))
                assert _tagged_equal(got_tagged, exp_tagged), (
                    f"Tagged JSON mismatch on {rel}: {got_tagged!r} != {exp_tagged!r}"
                )
        elif rel.startswith("invalid/"):
            invalid_count += 1
            with pytest.raises(motoml.TOMLDecodeError, match="."):
                motoml.loads(raw)

    assert valid_count > 150
    assert invalid_count > 400

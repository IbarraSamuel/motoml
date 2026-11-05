#!/usr/bin/env python3
"""Deterministic synthetic TOML corpora for benchmarking motoml readers.

Usage: python tests/gen_bench_data.py [size_mb ...]   (default: 1 10)
Writes tests/bench_data/<corpus>_<N>mb.toml (gitignored).
"""

import random
import sys
from pathlib import Path

OUT = Path(__file__).parent / "bench_data"


def _word(r: random.Random, lo=3, hi=12) -> str:
    return "".join(r.choice("abcdefghijklmnopqrstuvwxyz") for _ in range(r.randint(lo, hi)))


def strings_plain(r, n):
    return f'k{n} = "{_word(r, 8, 60)} {_word(r, 8, 60)}"\n'


def strings_escaped(r, n):
    return f'k{n} = "line\\n{_word(r)}\\t\\"{_word(r)}\\\\\\r\\f"\n'


def ints_floats(r, n):
    return (
        f"i{n} = {r.randint(-10**9, 10**9)}\n"
        f"u{n} = {r.randint(1, 999)}_{r.randint(100, 999)}\n"
        f"f{n} = {r.uniform(-1e6, 1e6):.6f}\n"
        f"e{n} = {r.randint(1, 9)}.{r.randint(1, 99)}e{r.randint(-20, 20)}\n"
    )


def dates(r, n):
    y, m, d = r.randint(1970, 2099), r.randint(1, 12), r.randint(1, 28)
    h, mi, s = r.randint(0, 23), r.randint(0, 59), r.randint(0, 59)
    return (
        f"d{n} = {y:04}-{m:02}-{d:02}\n"
        f"t{n} = {h:02}:{mi:02}:{s:02}\n"
        f"dt{n} = {y:04}-{m:02}-{d:02}T{h:02}:{mi:02}:{s:02}Z\n"
    )


def many_tables(r, n):
    return f"[root.sec{n % 50}.sub{n}]\nname = \"{_word(r)}\"\nvalue = {r.randint(0, 1000)}\n\n"


def array_of_tables(r, n):
    return (
        f"[[pkg]]\nname = \"{_word(r)}\"\nversion = \"{r.randint(0,9)}.{r.randint(0,99)}.{r.randint(0,99)}\"\n"
        f"deps = [\"{_word(r)}\", \"{_word(r)}\"]\n\n"
    )


def inline_nested(r, n):
    return (
        f"p{n} = {{ x = {r.randint(0, 99)}, y = {r.randint(0, 99)}, "
        f"tags = [\"{_word(r)}\", \"{_word(r)}\", {{ a = 1, b = [1, 2, 3] }}] }}\n"
    )


def mixed(r, n):
    return r.choice([strings_plain, ints_floats, dates, inline_nested])(r, n)


def deep_nesting(r, n):
    # one deeply nested inline structure per record, bounded depth
    depth = 24
    return f"deep{n} = " + "[" * depth + "1" + "]" * depth + "\n"


def huge_table(r, n):
    return f"key_{n}_{_word(r, 4, 10)} = {n}\n"


def dotted_keys(r, n):
    return f"a.b{n % 100}.c{n} = {n}\n"


def realworld_lock(r, n):
    """Hold-out: Cargo.lock / uv.lock style with comments, hashes, multi-line arrays."""
    pkg = f"{_word(r, 4, 12)}-{_word(r, 3, 8)}"
    ver = f"{r.randint(0, 5)}.{r.randint(0, 30)}.{r.randint(0, 20)}"
    cksum = "".join(r.choice("0123456789abcdef") for _ in range(64))
    deps = ",\n ".join(
        f'"{_word(r, 4, 10)} {r.randint(0,3)}.{r.randint(0,15)}.0"'
        for _ in range(r.randint(0, 6))
    )
    return (
        f"# Package entry {n}\n"
        f"[[package]]\n"
        f'name = "{pkg}"\n'
        f'version = "{ver}"\n'
        f'source = "registry+https://github.com/rust-lang/crates.io-index"\n'
        f'checksum = "{cksum}"\n'
        f"dependencies = [\n {deps}\n]\n\n"
    )


def realworld_config(r, n):
    """Hold-out: pyproject / hugo / service config with CRLF, quoted keys, multiline strings, inline tables, dates."""
    sec = f"service_{n}"
    desc = f"Service {n} handles {_word(r, 6, 15)} workloads.\\nLine two with \\\"quotes\\\" and tab\\there."
    ml = f'"""\nMulti-line description for {sec}.\nSupports unicode \\u00e9 and paths \'C:\\\\Users\\\\app\'.\n"""'
    return (
        f"# Configuration block {n}\r\n"
        f"[{sec}]\r\n"
        f'title = "{desc}"\r\n'
        f"readme = {ml}\r\n"
        f"enabled = {'true' if n % 2 == 0 else 'false'}\r\n"
        f"max_conns = {r.randint(10, 10_000)}\r\n"
        f"timeout_sec = {r.uniform(0.05, 30.0):.4f}\r\n"
        f"deployed_at = 2026-0{r.randint(1,9)}-1{r.randint(0,9)}T12:34:56Z\r\n"
        f'"{_word(r, 3, 7)}.dotted" = {{ host = "10.0.{n % 255}.{r.randint(1,254)}", port = {8000 + (n % 1000)}, tls = true }}\r\n'
        f"[{sec}.limits]\r\n"
        f"cpu_quota = 0x{r.randint(16, 4096):x}\r\n"
        f"burst = 1_000_{r.randint(100, 999)}\r\n\r\n"
    )


# corpus name -> (generator, header_per_file)
CORPORA = {
    "strings_plain": strings_plain,
    "strings_escaped": strings_escaped,
    "ints_floats": ints_floats,
    "dates": dates,
    "many_tables": many_tables,
    "array_of_tables": array_of_tables,
    "inline_nested": inline_nested,
    "mixed": mixed,
    "deep_nesting": deep_nesting,
    "huge_table": huge_table,
    "dotted_keys": dotted_keys,
    "realworld_lock": realworld_lock,
    "realworld_config": realworld_config,
}


def build(name: str, size_mb: int) -> None:
    r = random.Random(f"{name}-{size_mb}")
    gen = CORPORA[name]
    target = size_mb * 1024 * 1024
    parts, size, n = [], 0, 0
    while size < target:
        chunk = gen(r, n)
        parts.append(chunk)
        size += len(chunk)
        n += 1
    path = OUT / f"{name}_{size_mb}mb.toml"
    path.write_text("".join(parts))
    print(f"{path.name}: {size} bytes, {n} records")


def build_toml_test_concat() -> None:
    """Hold-out: concatenation of valid simple/flat toml-test 1.1 files namespaced under [t_N]."""
    suite_dir = Path(__file__).parent / "toml_files" / "tests"
    manifest = suite_dir / "files-toml-1.1.0"
    if not manifest.exists():
        return
    chunks = []
    idx = 0
    for line in manifest.read_text().splitlines():
        if not line.startswith("valid/") or not line.endswith(".toml"):
            continue
        p = suite_dir / line
        if not p.exists():
            continue
        try:
            txt = p.read_text(encoding="utf-8")
        except Exception:
            continue
        # Only include files without top-level [table] headers so they nest cleanly under [t_N]
        if "\n[" in ("\n" + txt):
            continue
        chunks.append(f"[t_{idx}]\n{txt}\n")
        idx += 1
    body = "".join(chunks)
    if not body:
        return
    # Repeat with distinct prefixes to reach ~1MB
    out_parts = []
    rep = 0
    total = 0
    while total < 1024 * 1024:
        part = body.replace("[t_", f"[r{rep}_t_")
        out_parts.append(part)
        total += len(part)
        rep += 1
    path = OUT / "toml_test_concat_1mb.toml"
    path.write_text("".join(out_parts), encoding="utf-8")
    print(f"{path.name}: {total} bytes, {rep * idx} sections")


def main() -> None:
    sizes = [int(a) for a in sys.argv[1:]] or [1, 10]
    OUT.mkdir(exist_ok=True)
    for name in CORPORA:
        for s in sizes:
            build(name, s)
    build_toml_test_concat()


if __name__ == "__main__":
    main()

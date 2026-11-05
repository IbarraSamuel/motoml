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


def main() -> None:
    sizes = [int(a) for a in sys.argv[1:]] or [1, 10]
    OUT.mkdir(exist_ok=True)
    for name in CORPORA:
        for s in sizes:
            build(name, s)


if __name__ == "__main__":
    main()

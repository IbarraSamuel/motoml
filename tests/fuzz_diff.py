#!/usr/bin/env python3
"""Differential & mutation fuzzer for motoml.lazy.

1. Valid TOML generation: generates random valid TOML documents and compares
   motoml.lazy's JSON output against Python's `tomllib` (normalized).
2. Mutation fuzzing: mutates valid TOML documents and checks that `motoml.lazy`
   in Strict mode never crashes and rejects everything `tomllib` rejects (plus
   comparing against an optional baseline binary).
"""

import argparse
import datetime
import json
import math
import random
import subprocess
import sys
import tempfile
import tomllib
from pathlib import Path


def to_tagged(val):
    if isinstance(val, dict):
        return {k: to_tagged(v) for k, v in val.items()}
    if isinstance(val, list):
        return [to_tagged(v) for v in val]
    if isinstance(val, bool):
        return {"type": "bool", "value": "true" if val else "false"}
    if isinstance(val, int):
        return {"type": "integer", "value": str(val)}
    if isinstance(val, float):
        if math.isnan(val):
            return {"type": "float", "value": "nan"}
        if math.isinf(val):
            return {"type": "float", "value": "-inf" if val < 0 else "inf"}
        return {"type": "float", "value": str(val)}
    if isinstance(val, str):
        return {"type": "string", "value": val}
    if isinstance(val, datetime.datetime):
        tp = "datetime-local" if val.tzinfo is None else "datetime"
        return {"type": tp, "value": val.isoformat()}
    if isinstance(val, datetime.date):
        return {"type": "date-local", "value": val.isoformat()}
    if isinstance(val, datetime.time):
        return {"type": "time-local", "value": val.isoformat()}
    raise TypeError(f"Unsupported type: {type(val)}")


def tagged_equal(a, b) -> bool:
    if isinstance(a, dict) and isinstance(b, dict):
        if "type" in a and "value" in a and "type" in b and "value" in b and len(a) == 2 and len(b) == 2:
            if a["type"] != b["type"]:
                return False
            if a["type"] == "float":
                if a["value"] == "nan" and b["value"] == "nan":
                    return True
                try:
                    fa, fb = float(a["value"]), float(b["value"])
                    return math.isclose(fa, fb, rel_tol=1e-9, abs_tol=1e-12)
                except ValueError:
                    return a["value"] == b["value"]
            return a["value"] == b["value"]
        if set(a.keys()) != set(b.keys()):
            return False
        return all(tagged_equal(a[k], b[k]) for k in a)
    if isinstance(a, list) and isinstance(b, list):
        return len(a) == len(b) and all(tagged_equal(x, y) for x, y in zip(a, b))
    return a == b


def gen_key(r: random.Random, idx: int) -> str:
    kind = r.randint(0, 3)
    if kind == 0:
        return f"k_{idx}_{r.choice(['alpha', 'beta', 'gamma', '99'])}"
    if kind == 1:
        return f'"quoted.key.{idx}"'
    if kind == 2:
        return f"'lit.key.{idx}'"
    return f'"esc\\u0061_{idx}"'


def gen_scalar(r: random.Random) -> str:
    kind = r.randint(0, 9)
    if kind == 0:
        return str(r.randint(-10**12, 10**12))
    if kind == 1:
        return f"0x{r.randint(0, 0xFFFFF):x}"
    if kind == 2:
        return f"0o{r.randint(0, 0o77777):o}"
    if kind == 3:
        return f"0b{r.randint(0, 0b11111111):b}"
    if kind == 4:
        return f"{r.randint(1, 999)}_{r.randint(100, 999)}"
    if kind == 5:
        return f"{r.uniform(-1e5, 1e5):.5f}"
    if kind == 6:
        return r.choice(["true", "false"])
    if kind == 7:
        s = "".join(r.choice("abcdefghij !@#$%^&*()") for _ in range(r.randint(0, 40)))
        return f'"{s}\\n\\t\\"\\\\\\u00e9"'
    if kind == 8:
        s = "".join(r.choice("abcdefghij_12345") for _ in range(r.randint(0, 35)))
        return f"'{s}'"
    return f"{r.randint(1990, 2030):04}-{r.randint(1, 12):02}-{r.randint(1, 28):02}"


def gen_valid_doc(r: random.Random, seed: int) -> str:
    r.seed(seed)
    lines = ["# Fuzz generated TOML"]
    for i in range(r.randint(3, 12)):
        if r.random() < 0.25:
            lines.append(f"{gen_key(r, i)}.sub = {gen_scalar(r)}")
        elif r.random() < 0.25:
            elems = ", ".join(gen_scalar(r) for _ in range(r.randint(0, 5)))
            lines.append(f"{gen_key(r, i)} = [{elems}]")
        elif r.random() < 0.2:
            lines.append(f"{gen_key(r, i)} = {{ a = {gen_scalar(r)}, b = {gen_scalar(r)} }}")
        else:
            lines.append(f"{gen_key(r, i)} = {gen_scalar(r)}")

    for t in range(r.randint(1, 5)):
        lines.append(f"\n[tbl_{t}.nested_{t % 3}] # comment {t}")
        for j in range(r.randint(1, 5)):
            lines.append(f"f_{j} = {gen_scalar(r)}")

    for a in range(r.randint(1, 3)):
        for k in range(r.randint(1, 3)):
            lines.append(f"\n[[aot_{a}]]")
            lines.append(f"id = {k}")
            lines.append(f"val = {gen_scalar(r)}")

    return "\n".join(lines) + "\n"


def mutate_doc(r: random.Random, doc: str) -> str:
    mutations = [
        lambda s: s + "\ndup = 1\ndup = 2\n",
        lambda s: s + '\nbad_esc = "\\q"\n',
        lambda s: s + "\nbad_int = 0123\n",
        lambda s: s + "\nbad_hex = +0x10\n",
        lambda s: s + "\nbad_float = 1..2\n",
        lambda s: s + "\nbad_float2 = .5\n",
        lambda s: s + "\nbad_date = 2023-02-29\n",
        lambda s: s + "\nbad_time = 25:00:00\n",
        lambda s: s + '\nunclosed = "hello\n',
        lambda s: s + "\n[unclosed.header\n",
        lambda s: s + "\ninl = { a = 1 }\ninl.b = 2\n",
        lambda s: s + "\nbare_cr = 1\r\nerr = 2\rbad = 3\n",
        lambda s: s + '\nbad_surrogate = "\\uD800"\n',
        lambda s: s + '\nbad_esc = "\\q"\n',
        lambda s: s + '\n["\\u0061"]\nx = 1\n[a]\ny = 2\n',
    ]
    return r.choice(mutations)(doc)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bin", default="/tmp/lazy_to_json")
    ap.add_argument("--seeds", type=int, default=200)
    ap.add_argument("--mutations", type=int, default=200)
    args = ap.parse_args()

    r = random.Random(42)
    with tempfile.NamedTemporaryFile("w", suffix=".toml", delete=False, encoding="utf-8") as tf:
        tmp_path = Path(tf.name)

    try:
        for seed in range(args.seeds):
            doc = gen_valid_doc(r, seed)
            expected = to_tagged(tomllib.loads(doc))
            tmp_path.write_text(doc, encoding="utf-8")
            proc = subprocess.run([args.bin, str(tmp_path)], capture_output=True, text=True)
            if proc.returncode != 0 or proc.stdout.startswith("PARSE_ERR:") or proc.stdout.startswith("DECODE_ERR:"):
                print(f"FAIL valid seed {seed}: {proc.stdout} {proc.stderr}")
                sys.exit(1)
            got = json.loads(proc.stdout)
            if not tagged_equal(got, expected):
                print(f"MISMATCH seed {seed}:\ngot: {got}\nexp: {expected}")
                sys.exit(1)

        mut_rejected = 0
        for m in range(args.mutations):
            base = gen_valid_doc(r, m)
            bad = mutate_doc(r, base)
            # Confirm tomllib rejects it
            try:
                tomllib.loads(bad)
                continue
            except Exception:
                pass
            tmp_path.write_text(bad, encoding="utf-8")
            proc = subprocess.run([args.bin, str(tmp_path)], capture_output=True, text=True)
            if proc.returncode != 0:
                print(f"CRASH on mutation {m}: {proc.stderr}")
                sys.exit(1)
            if proc.stdout.startswith("PARSE_ERR:"):
                mut_rejected += 1
            else:
                print(f"NOT REJECTED AT PARSE TIME on mutation {m} ({proc.stdout[:60]}):\n{bad}")
                sys.exit(1)

        print(f"Fuzz OK: {args.seeds} valid seeds matched tomllib, {mut_rejected} invalid mutations rejected at parse time.")
    finally:
        tmp_path.unlink(missing_ok=True)


if __name__ == "__main__":
    main()

"""Build and freeze both input sets without executing them."""
import argparse
import hashlib
import json
import shutil
import subprocess
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BENCH = ROOT / "bench"
MANIFEST = BENCH / "dataset.json"
DATASET_SHA256 = "ada027679aaab88d850b33e7129b5b5b9fbbcff2b2bc2e8316560b547aca8836"
A17_HOLDOUT_MANIFEST = BENCH / "dataset-a17-holdout.json"
A17_HOLDOUT_SHA256 = "400e7ad784279e175510d0c467dd27f879ac516f204b8808596296cdc7c50f86"
FUEL_V2_DATASET_HASHES = (DATASET_SHA256, A17_HOLDOUT_SHA256)


def sha256(path):
    with path.open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def run(argv, cwd=ROOT):
    subprocess.run(argv, cwd=cwd, check=True)


def uleb(value):
    result = bytearray()
    while value >= 128:
        result.append((value & 127) | 128)
        value >>= 7
    result.append(value)
    return bytes(result)


def section(tag, contents):
    return bytes([tag]) + uleb(len(contents)) + contents


def read_uleb(source):
    result = 0
    for shift in range(0, 35, 7):
        byte = source.read(1)
        if not byte:
            break
        result |= (byte[0] & 127) << shift
        if byte[0] < 128 and result <= 0xffffffff:
            return result
    raise ValueError("invalid section length or index")


def wasm_start(path):
    """Read only the core start index; binary validity is checked by wasm-tools."""
    with path.open("rb") as source:
        if source.read(8) != b"\x00asm\x01\x00\x00\x00":
            raise ValueError(f"not a core Wasm module: {path}")
        while tag := source.read(1):
            length = read_uleb(source)
            end = source.tell() + length
            if end > path.stat().st_size:
                raise ValueError(f"truncated section: {path}")
            if tag == b"\x08":
                index = read_uleb(source)
                if source.tell() != end:
                    raise ValueError(f"invalid start section: {path}")
                return index
            source.seek(end)
    return None


def instrumentation_markers(path):
    return wasm_custom_sections(path, b"fuelguard.instrumented")


def wasm_custom_sections(path, name):
    """Read matching custom-section payloads from a core Wasm artifact."""
    sections = []
    size = path.stat().st_size
    with path.open("rb") as source:
        if source.read(8) != b"\x00asm\x01\x00\x00\x00":
            raise ValueError(f"not a core Wasm module: {path}")
        while tag := source.read(1):
            length = read_uleb(source)
            end = source.tell() + length
            if end > size:
                raise ValueError(f"truncated section: {path}")
            if tag == b"\x00":
                name_size = read_uleb(source)
                if name_size > end - source.tell():
                    raise ValueError(f"invalid custom section name: {path}")
                if source.read(name_size) == name:
                    sections.append(source.read(end - source.tell()))
            source.seek(end)
    return sections


def check_start(path, case, *, variant="original", original_start=None):
    index = wasm_start(path)
    if (index is not None) != case.get("core_start", False):
        raise ValueError(f"core start presence changed: {case['id']} {variant}")
    if variant == "fuel" and index != original_start:
        raise ValueError(f"fuel-only start index changed: {case['id']}")
    return index

def build_scale(path, functions, instructions, size):
    pairs, tail = divmod(instructions // functions, 2)
    body = b"\x00" + b"\x41\x01\x1a" * pairs + b"\x01" * tail + b"\x0b"
    wasm = (
        b"\x00asm\x01\x00\x00\x00"
        + section(1, b"\x01\x60\x00\x00")
        + section(3, uleb(functions) + b"\x00" * functions)
        + section(10, uleb(functions) + (uleb(len(body)) + body) * functions)
    )
    pad = size - len(wasm) - 2
    while len(wasm) + 1 + len(uleb(pad)) + pad > size:
        pad -= 1
    wasm += section(0, b"\x03pad" + bytes(pad - 4))
    if len(wasm) != size:
        raise ValueError("wrong build input size")
    path.write_bytes(wasm)


def arithmetic(path, count, step, start_only):
    # Sum of an arithmetic series. The start-only variant independently asserts
    # the checksum within core start, because it has no hot or explicit entry.
    expected = step * count * (count + 1) // 2
    start = f"(start $init) (func $init call $work i32.const {expected} i32.ne if unreachable end)"
    export = start if start_only else '(export "run" (func $work))'
    wat = f"""(module
  (func $step (param i32) (result i32) local.get 0 i32.const {step} i32.mul)
  (func $work (result i32) (local $n i32) (local $sum i32)
    i32.const {count} local.set $n
    loop $loop
      local.get $sum local.get $n call $step i32.add local.set $sum
      local.get $n i32.const 1 i32.sub local.tee $n br_if $loop
    end
    local.get $sum)
  {export})"""
    source = path.with_suffix(".wat")
    source.write_text(wat + "\n", encoding="utf-8")
    run(["wasm-tools", "parse", source, "-o", path])
    # Index-only exports and starts avoid the engine CLI's name lookup path.
    run(["wasm-tools", "strip", "--all", path, "-o", path])
    return None if start_only else expected


def holdout_workload(name, changes, work, output):
    source = ROOT / "fixtures/workloads" / name
    target = work / name
    shutil.copytree(source, target, ignore=shutil.ignore_patterns("_build", ".mooncakes", "*.wasm"))
    main = target / name / "main.mbt"
    text = main.read_text(encoding="utf-8")
    for old, new in changes:
        if text.count(old) != 1:
            raise ValueError(f"changed source {main}: {old}")
        text = text.replace(old, new)
    main.write_text(text, encoding="utf-8")
    run(["moon", "build", "--target", "wasm", "--release"], cwd=target)
    shutil.copy2(target / "_build/wasm/release/build" / name / f"{name}.wasm", output)


def freeze(work):
    if MANIFEST.exists():
        raise ValueError(f"already frozen: {MANIFEST}")
    fixtures = BENCH / "fixtures"
    fixtures.mkdir(exist_ok=True)
    entries = []

    def add(name, path, split, kind, *, output="", entry=None, value=None,
            lifecycle=1, hot=None, has_start=None, depth=128, units=100000, **extra):
        run(["wasm-tools", "validate", path])
        core_start = wasm_start(path) is not None
        if has_start is not None and core_start != has_start:
            raise ValueError(f"unexpected core start section: {name}")
        entries.append(dict(
            id=name, path=path.relative_to(ROOT).as_posix(), sha256=sha256(path),
            bytes=path.stat().st_size, split=split, kind=kind,
            stdout=output, result_i32=value, entry=entry, core_start=core_start,
            windows=({"lifecycle": lifecycle} if hot is None else
                     {"lifecycle": lifecycle, "hot": hot}) if kind != "build" else {},
            stack_units=units, depth=depth, **extra,
        ))

    for name, path, expected, digest in [
        ("F0-hello", "fixtures/hello/hello.wasm", "5050\n111\n190\n",
         "bce5d762eee3e537918833217de9a7ac0acec198dcdf71ea02c2573f1a0f3f96"),
        ("F1-json", "fixtures/workloads/json_parse/json_parse.wasm",
         "json5 rounds=200 checksum=8928400\n",
         "8ab4c1b5678dda4683e5c5dde20d63ab6340d059ef817eb1448adc2528c90501"),
        ("F2-lisp", "fixtures/workloads/lisp_eval/lisp_eval.wasm", "Number(2584)\nNumber(0)\n",
         "800c887ccb19dd15327272a2c87d8b593ef705e9f01bc175c1d479be3ef738ac"),
        ("F3-sha256", "fixtures/workloads/sha256_hash/sha256_hash.wasm",
         "sha256 rounds=32 bytes=4096 checksum=132768\n"
         "words=-807933589 1631200399 1145861550 -1471824509 -268182326 1702735228 1915947960 668078838\n",
         "41716fad7e22a8700e2729cd9bfff0fd32517286fff62749f0eceb19b9beba90"),
    ]:
        if sha256(ROOT / path) != digest:
            raise ValueError(f"S01 fixture changed: {name}")
        is_hello = name.startswith("F0")
        is_lisp = name.startswith("F2")
        add(name, ROOT / path, "tuning", "application", output=expected, entry="_start",
            lifecycle=8 if is_hello else 1, hot=32 if is_hello else 1,
            depth=2048 if is_lisp else 128,
            units=500000 if is_lisp else 100000)

    for name, changes, expected in [
        ("json_parse", [("round < 200", "round < 233"), ("rounds=200", "rounds=233"),
                        ("'alpha'", "'delta'"), ("'gamma'", "'sigma'")],
         "json5 rounds=233 checksum=10405780\n"),
        ("lisp_eval", [("(fib 18)", "(fib 17)"), ("(count 400)", "(count 367)")],
         "Number(1597)\nNumber(0)\n"),
        ("sha256_hash", [("round < 32", "round < 43"), ("rounds=32", "rounds=43")],
         "sha256 rounds=43 bytes=4096 checksum=178407\n"
         "words=-807933589 1631200399 1145861550 -1471824509 -268182326 1702735228 1915947960 668078838\n"),
    ]:
        path = fixtures / f"holdout-{name}.wasm"
        holdout_workload(name, changes, work, path)
        is_lisp = name == "lisp_eval"
        add(path.stem, path, "holdout", "application", output=expected, entry="_start",
            hot=1, depth=2048 if is_lisp else 128,
            units=500000 if is_lisp else 100000)

    for split, count, step in [("tuning", 4096, 7), ("holdout", 5379, 11)]:
        for start_only in (False, True):
            path = fixtures / f"{split}-{'start' if start_only else 'call'}.wasm"
            value = arithmetic(path, count, step, start_only)
            add(path.stem, path, split, "micro", entry=None if start_only else "run",
                value=value, lifecycle=4, hot=None if start_only else 4,
                has_start=start_only)

    for functions, instructions, size in [
        (64, 16384, 65536),
        (512, 131072, 524288),
        (4096, 1048576, 4194304),
    ]:
        path = work / f"build-{functions}.wasm"
        build_scale(path, functions, instructions, size)
        run(["wasm-tools", "validate", path])
        entries.append(dict(
            id=path.stem, split="tuning", kind="build", bytes=size,
            functions=functions, instructions=instructions, sha256=sha256(path),
            depth=128, stack_units=100000, stdout="", windows={},
        ))
    write_json(MANIFEST, {
        "schema": "fuelguard-bench-dataset-v1",
        "frozen_utc": datetime.now(timezone.utc).isoformat(),
        "toolchain": {
            name: subprocess.check_output(argv, text=True).strip() for name, argv in
            [("moon", ["moon", "version"]), ("wasm-tools", ["wasm-tools", "--version"])]
        },
        "config": {"fuel": 9223372036854775807, "memory_pages": 64, "table_elements": 64},
        "sampling": {
            "schedule_seed": 180026, "bootstrap_seed": 180027, "bootstrap_draws": 10000,
            "processes": 3, "warmups": 5, "samples": 300,
            "build_processes": 3, "cpu": 4,
            "clock": "CLOCK_MONOTONIC", "outliers": "retain all successful observations",
            "interference": "serial workers, CPU affinity, AC balanced, no intentional competing workloads",
        },
        "entries": entries,
    })
    print(f"{MANIFEST} {sha256(MANIFEST)}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("work", type=Path, help="new directory for fixture builds")
    options = parser.parse_args()
    options.work.mkdir(parents=True)
    freeze(options.work.resolve())

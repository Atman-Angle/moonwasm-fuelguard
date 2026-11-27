"""Measure fuel-v2 on the frozen S29 F1–F3 inputs and original compact artifacts."""

import argparse
import hashlib
import json
import platform
import re
import struct
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from bench import dataset
from bench.performance_evidence import size_limit
from integration.fuel_v2.check import instrument, repeat_delivery, runtime, stack

CASES = ("F1-json", "F2-lisp", "F3-sha256")
COMPACT = ("join-span-compact", "join-span-compact-v2")
LIMIT = 19
OFFSET_LINE = re.compile(r"^\(;@([0-9a-f]+)\s*;\)( +)(.*)$")
FUNCTION = re.compile(r"^\(func \(;(\d+);\)")
LOCAL_DEBIT = "local.get i64.const i64.sub local.tee i64.const i64.lt_s"
GLOBAL_DEBIT = "global.get i64.const i64.sub global.set global.get i64.const i64.lt_s"
SPAN_SECTION = b"fuelguard.fuel-v2-spans-v1"


def guards(wat, details, proof=None):
    """Count static guard sites and their byte ranges from disassembled offsets."""
    current = []
    functions = []
    v2 = details["fuel_model"] == "fuel-v2"
    if v2:
        bounds = [end for end, in struct.iter_unpack("<i", proof[32:])]
        first_helper = None
    else:
        first_helper = details["appended"]["functions"]["first_index"]
    for line in wat.splitlines():
        match = OFFSET_LINE.match(line)
        if not match:
            continue
        offset, indent, text = match.groups()
        if len(indent) == 2 and (function := FUNCTION.match(text)):
            index = int(function[1])
            if first_helper is None:
                first_helper = index + len(bounds)
            if index >= first_helper:
                break
            current = []
            functions.append((index, current))
        elif len(indent) >= 4 and functions:
            current.append((int(offset, 16), text.split(" ;;", 1)[0]))

    sites = []
    inline_count = inline_bytes = cold_bytes = shared_count = shared_bytes = 0
    max_weight = max_immediate_bytes = 0
    rows = bytearray()
    lengths = []
    for j, (function_index, lines) in enumerate(functions):
        ops = [op for _, op in lines]
        names = [op.partition(" ")[0] for op in ops]
        function_spans = []
        for i, op in enumerate(ops):
            if op == f"call {first_helper}":
                branch = i - (2 if v2 else 4)
                assert branch >= 6 and ops[branch] == "if" and ops[i + 1] == "end"
                if not v2:
                    assert names[i - 2] in ("local.get", "global.get")
                    assert names[i - 1] == "i64.const"
                assert names[branch + 1] == "i32.const"
                sites.append(int(ops[branch + 1].split()[1]))
                start = branch - 6
                if " ".join(names[start:branch]) != LOCAL_DEBIT:
                    start = branch - 7
                    assert start >= 0 and " ".join(names[start:branch]) == GLOBAL_DEBIT
                assert ops[branch - 2] == "i64.const 0"
                end = lines[i + 1][0] + 1  # end opcode
                weight = int(ops[start + 1].split()[1])
                assert weight > 0
                function_spans.append((sites[-1], weight))
                inline_count += 1
                inline_bytes += end - lines[start][0]
                cold_bytes += end - lines[branch][0]
                max_weight = max(max_weight, weight)
                max_immediate_bytes = max(
                    max_immediate_bytes, lines[start + 2][0] - lines[start + 1][0] - 1,
                )
            elif not v2 and op == f"call {first_helper + 1}" and ops[i - 1].startswith("i64.const "):
                assert i >= 2 and names[i - 2] == "i32.const"
                sites.append(int(ops[i - 2].split()[1]))
                shared_count += 1
                shared_bytes += lines[i + 1][0] - lines[i - 2][0]
        if v2:
            assert bool(function_spans) == (bounds[j] > 0)
            ends = [first for first, _ in function_spans[1:]] + [bounds[j] + 1]
            for (first, weight), end in zip(function_spans, ends):
                length = end - first
                lengths.append(length)
                rows.extend(struct.pack("<iiiq", function_index, first, length, weight))
    if v2:
        assert len(functions) == len(bounds) and hashlib.sha256(rows).digest() == proof[:32]
    else:
        spans = details["fuel_spans"]
        assert sites == [span["first_site"] for span in spans], "Wasm guard sites differ from the manifest"
        lengths = [span["length"] for span in spans]
    return dict(guard_count=len(sites), guard_bytes=inline_bytes + shared_bytes,
                inline_count=inline_count, inline_bytes=inline_bytes, cold_bytes=cold_bytes,
                shared_count=shared_count, shared_bytes=shared_bytes, max_inline_weight=max_weight,
                max_inline_immediate_bytes=max_immediate_bytes,
                max_span_length=max(lengths),
                extra_guards_at_19=sum((length - 1) // LIMIT for length in lengths))


def measure(name, wasm, report, details):
    wat = runtime.run(f"offsets-{name}", ["wasm-tools", "print", "--print-offsets", wasm], runtime.ok)
    proofs = dataset.wasm_custom_sections(wasm, SPAN_SECTION) if details["fuel_model"] == "fuel-v2" else [None]
    proof, = proofs
    return dict(wasm_bytes=wasm.stat().st_size, wasm_sha256=dataset.sha256(wasm),
                sidecar_bytes=report.stat().st_size, sidecar_sha256=dataset.sha256(report),
                **guards(wat, details, proof))


def archived(directory, case, layout, current):
    folder = directory / case["id"]
    wasm = folder / f"{layout}-0.wasm"
    report = folder / f"manifest-{layout}.json"
    manifest = json.loads(report.read_text(encoding="utf-8"))
    details = manifest["instrumentation"]
    assert details["codegen"] == (layout + "-v1" if layout == COMPACT[0] else layout)
    assert details["fuel_model"] == "fuel-v1.2"
    assert manifest["input_sha256"] == case["sha256"] == dataset.sha256(folder / "original.wasm")
    assert manifest["output_sha256"] == dataset.sha256(wasm)
    assert details["config"] == current["config"]
    measured = measure(f"{case['id']}-{layout}", wasm, report, details)
    volumes = json.loads((directory / "volumes.json").read_text(encoding="utf-8"))
    recorded, = [row for row in volumes if row["case"] == case["id"] and row["variant"] == layout]
    assert (recorded["bytes"], recorded["sha256"], recorded["sidecar_bytes"]) == (
        measured["wasm_bytes"], measured["wasm_sha256"], measured["sidecar_bytes"],
    )
    return measured


def workload(case, baselines):
    name = case["id"]
    source = dataset.ROOT / case["path"]
    assert source.stat().st_size == case["bytes"] and dataset.sha256(source) == case["sha256"]
    first, details = repeat_delivery(name, source, stack.MAX,
                                     units=case["stack_units"], depth=case["depth"])
    report = first.with_suffix(".json")
    manifest = json.loads(report.read_text(encoding="utf-8"))
    assert manifest["input_sha256"] == case["sha256"]
    assert manifest["output_sha256"] == dataset.sha256(first)
    runtime.run(f"validate-{name}-source", ["wasm-tools", "validate", source], runtime.ok)
    original_start = dataset.check_start(source, case)
    dataset.check_start(first, case, variant="fuel-v2", original_start=original_start)
    for engine in ("wasmoon", "wasmtime"):
        for suffix, module in (("original", source), ("fuel-v2", first)):
            label = f"{engine}-{name}-{suffix}"
            runtime.run(label, runtime.invoke(engine, module), runtime.ok)
            assert (stack.OUT / f"{label}.stdout").read_bytes() == case["stdout"].encode()
    result = measure(name, first, report, details)
    limit = size_limit(case["bytes"])
    return dict(original_bytes=case["bytes"], original_sha256=case["sha256"], size_limit=limit,
                fuel_v2=result, **{layout: archived(path, case, layout, details)
                                   for layout, path in zip(COMPACT, baselines, strict=True)})


def leb_edge():
    result = {}
    for weight, width in ((63, 1), (64, 2), (8191, 2), (8192, 3)):
        name = f"sleb-{weight}"
        source = stack.compile_wat(name, '(module (func (export "go") ' + "nop " * weight + "))")
        exact, details = instrument(f"{name}-exact", source, weight)
        entry = measure(name, exact, exact.with_suffix(".json"), details)
        assert entry["guard_count"] == 1 and entry["max_inline_weight"] == weight
        assert entry["max_inline_immediate_bytes"] == width
        stack.run(f"{name}-exact", exact, stack.returns(stack.invoke("go")))
        low, _ = instrument(f"{name}-low", source, weight - 1)
        stack.run(f"{name}-low", low, stack.trap_check(stack.invoke("go"), 1, 2))
        result[weight] = entry
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--compact-v1", type=Path, required=True, help="S29 initial run")
    parser.add_argument("--compact-v2", type=Path, required=True, help="S29-autoresearch v2 benchmark run")
    args = parser.parse_args()
    if not __debug__:
        raise SystemExit("S32 requires Python assertions enabled")
    if (platform.system(), platform.machine()) != ("Linux", "x86_64"):
        raise SystemExit("S32 requires x86_64 Linux")
    stack.OUT = runtime.OUT = args.out.resolve()
    stack.OUT.mkdir(parents=True)
    for tool, version in runtime.VERSIONS.items():
        runtime.run(f"version-{tool}", [tool, "--version"],
                    lambda code, out, _err: code == 0 and version in out)
    assert dataset.sha256(dataset.MANIFEST) == dataset.DATASET_SHA256
    cases = {case["id"]: case for case in json.loads(dataset.MANIFEST.read_text(encoding="utf-8"))["entries"]}
    stack.build_instrument("build-instrument")
    workloads = {name: workload(cases[name], (args.compact_v1, args.compact_v2)) for name in CASES}
    dataset.write_json(stack.OUT / "measurements.json", dict(workloads=workloads, sleb=leb_edge()))
    runtime.artifact("measurements", stack.OUT / "measurements.json")


if __name__ == "__main__":
    main()

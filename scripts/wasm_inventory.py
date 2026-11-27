#!/usr/bin/env python3
"""Independent feature inventory for FuelGuard support-matrix freezing.

Reads the disassembly produced by `wasm-tools print` and reports structural
facts, opcode categories and per-function limits. This is a test/analysis tool
only; it is not part of the MoonBit instrumentation core.

Usage:
  wasm-tools print module.wasm > module.wat
  python scripts/wasm_inventory.py module.wat [--wasm module.wasm]
"""

import argparse
import hashlib
import json
import re
import sys
from collections import Counter
from pathlib import Path

OPENERS = {"block", "loop", "if", "try", "try_table"}
CLOSERS = {"end"}
SIMD_PREFIXES = ("v128", "i8x16", "i16x8", "i32x4", "i64x2", "f32x4", "f64x2")
BULK = {
    "memory.init", "data.drop", "memory.copy", "memory.fill",
    "table.init", "elem.drop", "table.copy", "table.grow",
    "table.size", "table.fill",
}
REFERENCE = {"ref.null", "ref.is_null", "ref.func", "ref.as_non_null",
             "br_on_null", "br_on_non_null", "ref.eq", "any.convert_extern",
             "extern.convert_any"}
GC_MARKERS = {"struct.new", "struct.get", "array.new", "array.get", "ref.cast",
              "ref.test", "br_on_cast", "i31.new", "extern.internalize"}
EXCEPTION = {"throw", "rethrow", "catch", "catch_all", "delegate", "throw_ref"}
THREADS = {"atomic.fence", "memory.atomic.notify", "memory.atomic.wait32"}
TAIL_CALL = {"return_call", "return_call_indirect", "return_call_ref"}


def classify(opcode):
    if opcode.startswith(SIMD_PREFIXES):
        return "simd"
    if opcode in BULK:
        return "bulk-memory"
    if opcode in REFERENCE:
        return "reference-types"
    if opcode in GC_MARKERS:
        return "gc"
    if opcode in EXCEPTION:
        return "exception-handling"
    if opcode.startswith("atomic.") or opcode in THREADS:
        return "threads"
    if opcode in TAIL_CALL:
        return "tail-call"
    if opcode in {"call_indirect", "call_ref"}:
        return "indirect-call"
    if opcode.startswith(("i32.", "i64.", "f32.", "f64.")):
        return "numeric"
    if opcode in OPENERS or opcode in CLOSERS or opcode in {
        "else", "br", "br_if", "br_table", "return", "unreachable", "nop",
        "drop", "select",
    }:
        return "control"
    if opcode.startswith(("local.", "global.", "table.get", "table.set")):
        return "variable"
    if opcode in {"memory.size", "memory.grow"}:
        return "memory"
    if opcode == "call":
        return "direct-call"
    return "other"


def count_types(line, keyword):
    match = re.search(r"\(%s([^)]*)\)" % keyword, line)
    if not match:
        return 0
    return len(match.group(1).split())


def inventory(wat_path, wasm_path=None):
    lines = Path(wat_path).read_text(encoding="utf-8").splitlines()
    result = {
        "types": 0, "imports": [], "functions": 0, "tables": [], "memories": [],
        "globals": 0, "exports": [], "start": None, "elements": [],
        "data_segments": 0, "opcodes": Counter(), "categories": Counter(),
        "max_params": 0, "max_results": 0, "max_locals": 0,
        "max_nesting": 0, "max_body_instructions": 0,
        "total_instructions": 0, "v128_locals": 0, "v128_signature_types": 0,
    }
    in_func = False
    depth = 0
    locals_current = 0
    body_instructions = 0
    func_index = -1
    per_function = []

    for raw in lines:
        line = raw.strip()
        if not line:
            continue
        if line.startswith("(type "):
            result["types"] += 1
            result["max_params"] = max(result["max_params"], count_types(line, "param"))
            result["max_results"] = max(result["max_results"], count_types(line, "result"))
            if "v128" in line:
                result["v128_signature_types"] += 1
            continue
        if line.startswith("(import "):
            match = re.match(r'\(import "([^"]*)" "([^"]*)" \((\w+)', line)
            if match:
                result["imports"].append({
                    "module": match.group(1), "name": match.group(2),
                    "kind": match.group(3),
                })
            continue
        if line.startswith("(table "):
            result["tables"].append(line)
            continue
        if line.startswith("(memory "):
            result["memories"].append(line)
            continue
        if line.startswith("(global "):
            result["globals"] += 1
            continue
        if line.startswith("(export "):
            result["exports"].append(line)
            continue
        if line.startswith("(start "):
            result["start"] = line
            continue
        if line.startswith("(elem "):
            result["elements"].append(line)
            continue
        if line.startswith("(data "):
            result["data_segments"] += 1
            continue
        if line.startswith("(func "):
            in_func = True
            depth = 0
            locals_current = 0
            body_instructions = 0
            func_index += 1
            result["functions"] += 1
            result["max_params"] = max(result["max_params"], count_types(line, "param"))
            result["max_results"] = max(result["max_results"], count_types(line, "result"))
            continue
        if not in_func:
            continue
        if line.startswith("(local"):
            tokens = line.strip("()").split()
            count = len(tokens) - 1
            locals_current += count
            if "v128" in tokens:
                result["v128_locals"] += tokens.count("v128")
            continue
        if line == ")" or line.startswith(")"):
            if depth == 0:
                in_func = False
                result["max_locals"] = max(result["max_locals"], locals_current)
                result["max_body_instructions"] = max(
                    result["max_body_instructions"], body_instructions)
                per_function.append({
                    "index": func_index, "locals": locals_current,
                    "instructions": body_instructions,
                })
                continue
        opcode = line.split()[0].lstrip("(")
        if opcode in OPENERS:
            depth += 1
            result["max_nesting"] = max(result["max_nesting"], depth)
        elif opcode in CLOSERS:
            depth -= 1
        result["opcodes"][opcode] += 1
        result["categories"][classify(opcode)] += 1
        result["total_instructions"] += 1
        body_instructions += 1

    result["opcodes"] = dict(sorted(result["opcodes"].items()))
    result["categories"] = dict(sorted(result["categories"].items()))
    result["per_function_top5_locals"] = sorted(
        per_function, key=lambda item: -item["locals"])[:5]
    if wasm_path:
        data = Path(wasm_path).read_bytes()
        result["wasm_bytes"] = len(data)
        result["wasm_sha256"] = hashlib.sha256(data).hexdigest()
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("wat")
    parser.add_argument("--wasm")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()
    report = inventory(args.wat, args.wasm)
    if args.json:
        json.dump(report, sys.stdout, indent=2, ensure_ascii=False)
        print()
        return
    for key in (
        "wasm_bytes", "wasm_sha256", "types", "functions", "globals",
        "data_segments", "max_params", "max_results", "max_locals",
        "max_nesting", "max_body_instructions", "total_instructions",
        "v128_locals", "v128_signature_types", "start",
    ):
        print(f"{key}: {report[key]}")
    print("imports:", json.dumps(report["imports"], ensure_ascii=False))
    print("tables:", report["tables"])
    print("memories:", report["memories"])
    print("exports:", report["exports"])
    print("elements:", report["elements"])
    print("categories:", json.dumps(report["categories"]))
    print("simd_opcodes:", json.dumps(
        {k: v for k, v in report["opcodes"].items() if k.startswith(SIMD_PREFIXES)}))
    print("top5_locals:", json.dumps(report["per_function_top5_locals"]))


if __name__ == "__main__":
    main()
"""Build mutated negative inputs and verify production CLI refusals for A15."""

import argparse
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))

from integration.generated.check import CommandLog, file_hash, save_json
from integration.generated.recipes import FUEL_V2, JOIN_LAYOUTS, SEED, generate

A15_CASE_COUNT = 23
from integration.policy.check import code_body


def run(directory, codegen=FUEL_V2):
    log = CommandLog(directory / "commands.jsonl")
    target = ROOT / "_build/s17-reject"
    command, _ = log.run(["moon", "build", "--target", "wasm", "--debug", "cmd/instrument",
                           "--target-dir", target], timeout=300)
    if command["exit_code"] != 0:
        save_json(directory / "summary.json", {"status": "BLOCKED", "reason": "cannot build instrument CLI"})
        return 2
    built_tool = target / "wasm/debug/build/cmd/instrument/instrument.wasm"
    tool = directory / "instrument-tool.wasm"
    tool.write_bytes(built_tool.read_bytes())
    recipe = generate(SEED, 0)
    wat = directory / "parent.wat"
    wat.write_text(recipe.trial().wat + "\n", encoding="ascii")
    parent = directory / "parent.wasm"
    command, _ = log.run(["wasm-tools", "parse", wat, "-o", parent])
    if command["exit_code"] != 0:
        save_json(directory / "summary.json", {"status": "BLOCKED", "reason": "cannot assemble parent"})
        return 2
    baseline = parent.read_bytes()
    mutations = (
        ("truncate-parent", baseline[:-1], None, "truncated"),
        ("replace-version", baseline[:4] + b"\x02\x00\x00\x00" + baseline[8:], None,
         "expected core Wasm version 1"),
        ("replace-opcode", code_body(b"\x00\xff\x0b"), None, "opcode 255"),
        ("nest-257", None, "(module (func " + "block " * 257 + "end " * 257 + "))", "structured nesting 257"),
        ("relaxed-vector", None, "(module (func (param v128 v128) local.get 0 local.get 1 "
                                 "i8x16.relaxed_swizzle drop))", "relaxed SIMD"),
        ("unlisted-vector", None, "(module (func v128.const i32x4 0 0 0 0 drop))",
         "outside production-v1 allowlist"),
        ("escape-call-table", None, '(module (table (export "tbl") 1 1 funcref))', "exported table"),
        ("simd-v128-load", None, "(module (func i32.const 0 v128.load drop))", "outside production-v1 allowlist"),
        ("simd-v128-store", None, "(module (func i32.const 0 v128.const i32x4 0 0 0 0 v128.store))", "outside production-v1 allowlist"),
        ("simd-v128-and", None, "(module (func v128.const i32x4 0 0 0 0 v128.const i32x4 0 0 0 0 v128.and drop))", "outside production-v1 allowlist"),
        ("simd-v128-or", None, "(module (func v128.const i32x4 0 0 0 0 v128.const i32x4 0 0 0 0 v128.or drop))", "outside production-v1 allowlist"),
        ("simd-v128-any-true", None, "(module (func v128.const i32x4 0 0 0 0 v128.any_true drop))", "outside production-v1 allowlist"),
        ("simd-i8x16-eq", None, "(module (func v128.const i32x4 0 0 0 0 v128.const i32x4 0 0 0 0 i8x16.eq drop))", "outside production-v1 allowlist"),
        ("simd-i8x16-all-true", None, "(module (func v128.const i32x4 0 0 0 0 i8x16.all_true drop))", "outside production-v1 allowlist"),
        ("simd-i8x16-shuffle", None, "(module (func v128.const i32x4 0 0 0 0 v128.const i32x4 0 0 0 0 i8x16.shuffle 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 drop))", "outside production-v1 allowlist"),
        ("simd-i16x8-splat", None, "(module (func i32.const 1 i16x8.splat drop))", "outside production-v1 allowlist"),
        ("simd-i16x8-eq", None, "(module (func v128.const i32x4 0 0 0 0 v128.const i32x4 0 0 0 0 i16x8.eq drop))", "outside production-v1 allowlist"),
        ("simd-i16x8-sub", None, "(module (func v128.const i32x4 0 0 0 0 v128.const i32x4 0 0 0 0 i16x8.sub drop))", "outside production-v1 allowlist"),
        ("simd-i16x8-le-u", None, "(module (func v128.const i32x4 0 0 0 0 v128.const i32x4 0 0 0 0 i16x8.le_u drop))", "outside production-v1 allowlist"),
        ("simd-i16x8-lt-u", None, "(module (func v128.const i32x4 0 0 0 0 v128.const i32x4 0 0 0 0 i16x8.lt_u drop))", "outside production-v1 allowlist"),
        ("simd-i16x8-bitmask", None, "(module (func v128.const i32x4 0 0 0 0 i16x8.bitmask drop))", "outside production-v1 allowlist"),
        ("simd-i32x4-extract-lane", None, "(module (func v128.const i32x4 0 0 0 0 i32x4.extract_lane 0 drop))", "outside production-v1 allowlist"),
        ("simd-i64x2-extract-lane", None, "(module (func v128.const i32x4 0 0 0 0 i64x2.extract_lane 0 drop))", "outside production-v1 allowlist"),
    )
    outcomes = []
    for name, data, source, expected in mutations:
        case_id = f"r-{name}"
        raw = directory / f"{case_id}.wasm"
        product = directory / f"{case_id}.protected.wasm"
        manifest = directory / f"{case_id}.json"
        preparation = None
        if source is None:
            raw.write_bytes(data)
        else:
            text = raw.with_suffix(".wat")
            text.write_text(source + "\n", encoding="ascii")
            preparation, _ = log.run(["wasm-tools", "parse", text, "-o", raw])
        command = preparation
        stderr = stdout = ""
        if preparation is None or preparation["exit_code"] == 0:
            command, stdout = log.run(["moonrun", tool, raw, "-o", product, "--report", manifest,
                                       "--fuel", 100000, "--max-stack-units", 100000,
                                       "--max-call-depth", 64, "--max-memory-pages", 2,
                                       "--max-table-elements", 2, "--codegen", codegen])
            if "stderr" in command:
                stderr = Path(command["stderr"]).read_text(errors="replace")
            success = (command["exit_code"] == 2 and expected in stdout + stderr
                       and not product.exists() and not manifest.exists())
        else:
            success = False
        outcomes.append({"case_id": case_id, "gate_id": "A15", "seed": SEED,
                         "status": "PASS" if success else
                         "BLOCKED" if command["environment_error"] else "FAIL",
                         "command": command, "exit_code": command["exit_code"], "expected": expected,
                         "actual": {"stdout": stdout, "stderr": stderr,
                                    "wasm_published": product.exists(), "manifest_published": manifest.exists()},
                         "input_hash": file_hash(raw) if raw.is_file() else None,
                         "output_hash": file_hash(product) if product.is_file() else None,
                         "engine_config": None, "trap_code": None, "site_id": None,
                         "diagnostic_reason": "instrumentation rejection before execution",
                         "artifact_paths": {"input": str(raw), "output": str(product),
                                            "manifest": str(manifest)}})
    save_json(directory / "cases.json", outcomes)
    assert len(outcomes) == A15_CASE_COUNT
    statuses = {case["status"] for case in outcomes}
    status = "FAIL" if "FAIL" in statuses else "BLOCKED" if "BLOCKED" in statuses else "PASS"
    save_json(directory / "summary.json",
              {"status": status, "codegen": codegen,
               "rejected": sum(case["status"] == "PASS" for case in outcomes),
               "requested": len(outcomes), "input_parent_sha256": file_hash(parent),
               "instrumenter_sha256": file_hash(tool), "cases_sha256": file_hash(directory / "cases.json")})
    return {"PASS": 0, "FAIL": 1, "BLOCKED": 2}[status]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--codegen", choices=("p0", *JOIN_LAYOUTS, FUEL_V2), default=FUEL_V2)
    args = parser.parse_args()
    directory = args.out.resolve()
    try:
        directory.mkdir(parents=True)
        return run(directory, args.codegen)
    except (OSError, ValueError) as error:
        print(error, file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())

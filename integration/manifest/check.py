"""Verify the delivery schema, CLI migration, and diagnostic sites in both engines."""
import hashlib
import json
import struct
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from integration.stack_pass import check as stack
from bench import dataset
from integration.fuel_v2.workloads import SPAN_SECTION

runtime = stack.runtime
FLAGS = (
    "--profile", "production-v1", "--cost-model", "fuel-v2",
    "--fuel", stack.MAX, "--max-stack-units", 10000, "--max-call-depth", 1,
    "--max-memory-pages", 1, "--max-table-elements", 1,
    "--allow-import", "spectest.print_i32", "--allow-import", "spectest.global_i32",
)
STAGES = ["FuelPass", "GrowthPass", "StackPass"]


def instrument(name, source, flags=FLAGS, *, error=None, report=True):
    wasm = OUT / f"{name}.wasm"
    manifest = OUT / f"{name}.json"
    args = ["moonrun", TOOL, source, "-o", wasm, *flags]
    if report:
        args.extend(["--report", manifest])
    summary = runtime.run(f"cli-{name}", args, lambda code, out, _err:
                          code == (2 if error else 0) and (error is None or error in out))
    if error:
        assert not wasm.exists() and not manifest.exists()
        return
    runtime.run(f"validate-{name}", ["wasm-tools", "validate", wasm], runtime.ok)
    runtime.artifact(name, wasm)
    if not report:
        return wasm
    runtime.artifact(f"{name}-manifest", manifest)
    doc = json.loads(manifest.read_bytes())
    assert doc["input_sha256"] == runtime.sha256(source)
    assert doc["output_sha256"] == runtime.sha256(wasm)
    stages = STAGES if doc["instrumentation"]["profile"] == "production-v1" else STAGES[:2]
    assert "passes: " + ", ".join(stages) in summary
    assert set(doc) == {"schema", "tool_version", "input_sha256", "output_sha256",
                        "deterministic", "instrumentation"}
    assert doc["deterministic"] is True
    runtime.run(f"verify-{name}", ["moonrun", TOOL, "verify", wasm, "--report", manifest], runtime.ok)
    return wasm, manifest, doc


def check_table_sites():
    source = stack.compile_wat("indirect-source", """(module
      (type $sig (func (result i32)))
      (type $mv (func (param i32) (result i32 i64)))
      (table 1 1 funcref)
      (elem (i32.const 0) $leaf)
      (func $leaf (type $sig) i32.const 42)
      (func $boot nop)
      (start $boot)
      (func (export "go") (type $sig) i32.const 0 call_indirect (type $sig))
      (func $mv_fn (type $mv) local.get 0 i64.const 7))""")
    flags = (*FLAGS[:10], "--max-table-elements", 1)
    wasm, _, _ = instrument("indirect", source, flags)
    stack.run("indirect-site", wasm, stack.trap_check(stack.invoke("go"), 5, 6))

    source = stack.compile_wat("table-grow-source", """(module
      (table 1 externref)
      (func (export "go") (result i32) ref.null extern i32.const 1 table.grow 0))""")
    wasm, _, _ = instrument("table-grow", source, flags)
    stack.run("table-grow-site", wasm, stack.trap_check(stack.invoke("go"), 3, 4))


def check_span_proof(flags):
    source = stack.compile_wat("span-proof-source", '(module (func (export "go") nop nop nop))')
    wasm, _, doc = instrument("span-proof", source, flags)
    proof, = dataset.wasm_custom_sections(wasm, SPAN_SECTION)
    row = struct.pack("<iiiq", 0, 2, 3, 3)
    assert proof == hashlib.sha256(row).digest() + struct.pack("<i", 4)
    for label, old, new, message in (
        ("guard-weight", b"\x42\x03\x7d", b"\x42\x04\x7d", "do not match the Fuel v2 span proof"),
        # The local-coalescing pass emits a success-first if/else around this debit.
        ("guard-site", b"\x04\x40\x05\x41\x02\x10\x01\x0b",
         b"\x04\x40\x05\x41\x03\x10\x01\x0b",
         "do not match the Fuel v2 span proof"),
        ("final-site", proof, proof[:32] + struct.pack("<i", 3), "do not match the Fuel v2 span proof"),
        ("empty-proof", proof, hashlib.sha256(b"").digest() + bytes(4), "nonempty function has no Fuel v2 span bound"),
        ("missing-proof", SPAN_SECTION, b"x" * len(SPAN_SECTION), "missing or malformed Fuel v2 span proof"),
    ):
        reject_changed_wasm(wasm, doc, label, old, new, message)

    source = stack.compile_wat("cached-source", '''(module
      (func (export "go") (local i64) i32.const 1 if nop end nop))''')
    wasm, _, doc = instrument("cached", source, flags)
    reject_changed_wasm(wasm, doc, "wrong-cache-local",
                        b"\x20\x01\x42\x02\x7d\x22\x01", b"\x20\x00\x42\x02\x7d\x22\x00",
                        "malformed Wasm Fuel v2 metering guard")
    source = stack.compile_wat("empty-export-source", '(module (func (export "go")))')
    instrument("empty-export", source, flags)


def reject_changed_wasm(wasm, doc, label, old, new, message):
    data = wasm.read_bytes()
    assert data.count(old) == 1, label
    changed = OUT / f"{label}.wasm"
    changed.write_bytes(data.replace(old, new, 1))
    runtime.run(f"validate-{label}", ["wasm-tools", "validate", changed], runtime.ok)
    manifest = changed.with_suffix(".json")
    manifest.write_text(json.dumps(dict(doc, output_sha256=runtime.sha256(changed))), encoding="utf-8")
    runtime.run(f"reject-{label}", ["moonrun", TOOL, "verify", changed, "--report", manifest],
                lambda code, out, _err: code == 2 and message in out)


def main():
    global OUT, TOOL
    if not __debug__:
        raise SystemExit("Manifest verification requires Python assertions enabled")
    base = runtime.ROOT / "_build/s14"
    base.mkdir(parents=True, exist_ok=True)
    OUT = Path(tempfile.mkdtemp(dir=base, prefix="run-"))
    runtime.OUT = stack.OUT = OUT
    TOOL = runtime.ROOT / "_build/wasm/debug/build/cmd/instrument/instrument.wasm"
    runtime.run("build-tool", ["moon", "build", "--target", "wasm", "cmd/instrument"],
                runtime.ok, timeout=180)
    for tool, version in runtime.VERSIONS.items():
        runtime.run(f"version-{tool}", [tool, "--version"],
                    lambda code, out, _err: code == 0 and version in out)
    version = runtime.run("version-instrument", ["moonrun", "--", TOOL, "--version"], runtime.ok)
    source = stack.compile_wat("original", """(module
      (import "spectest" "print_i32" (func $print (param i32)))
      (import "spectest" "global_i32" (global i32))
      (memory 1) (table 1 externref)
      (export "host" (func $print))
      (func $leaf (param i32) (result i32) local.get 0 i32.const 0 i32.add)
      (func (export "go") (param i32) (result i32)
        local.get 0
        if (result i32) i32.const 1 memory.grow
        else i32.const 0 call $leaf end))""")

    # The omitted selectors and either explicit fuel-v2 selector produce identical bytes.
    default = FLAGS[:2] + FLAGS[4:]
    runs = [instrument(f"same-{i}", source, flags) for i, flags in enumerate((
        default, FLAGS, (*default, "--codegen", "fuel-v2"),
    ))]
    wasm, manifest, doc = runs[0]
    for other_wasm, other_manifest, _ in runs[1:]:
        assert other_wasm.read_bytes() == wasm.read_bytes()
        assert other_manifest.read_bytes() == manifest.read_bytes()
    assert instrument("without-report", source, report=False).read_bytes() == wasm.read_bytes()
    reordered = FLAGS[:-4] + FLAGS[-2:] + FLAGS[-4:-2] + FLAGS[-2:]
    _, reordered_report, _ = instrument("reordered-imports", source, reordered)
    assert reordered_report.read_bytes() == manifest.read_bytes()
    assert doc["tool_version"] == version and doc["schema"] == "fuelguard-manifest-v2"
    details = doc["instrumentation"]
    assert {key: value for key, value in details.items() if key != "config"} == {
        "profile": "production-v1", "fuel_model": "fuel-v2", "stack_model": "stack-v2",
        "growth_model": "growth-v1", "diagnostics_abi": "diagnostics-v1",
        "codegen": "fuel-v2-inline-v1",
    }
    config = details["config"].copy()
    allowed = config.pop("allowed_imports")
    assert sorted((entry["module"], entry["name"]) for entry in allowed) == [
        ("spectest", "global_i32"), ("spectest", "print_i32"),
    ]
    assert config == {
        "fuel": str(stack.MAX), "max_stack_units": "10000", "max_call_depth": "1",
        "max_memory_pages": 1, "max_table_elements": 1,
    }
    stack.run("growth-site", wasm, stack.trap_check(stack.invoke("go", 1), 2, 9))
    stack.run("depth-site", wasm, stack.trap_check(stack.invoke("go", 0), 5, 11))

    for label, change, diagnostic in (
        ("swapped-stack-model", {"stack_model": "stack-v1"}, "incomplete manifest"),
        ("overflow-stack-config", {"config": dict(details["config"], max_call_depth="2147483648")},
         "incomplete manifest"),
    ):
        tampered = OUT / f"{label}.json"
        tampered.write_text(json.dumps(dict(doc, instrumentation=dict(details, **change))), encoding="utf-8")
        runtime.run(label, ["moonrun", TOOL, "verify", wasm, "--report", tampered],
                    lambda code, out, _err: code == 2 and diagnostic in out)

    low_fuel = FLAGS[:5] + (1,) + FLAGS[6:]
    low, _, _ = instrument("low-fuel", source, low_fuel)
    stack.run("fuel-site", low, stack.trap_check(stack.invoke("go", 1), 1, 6))
    low_stack = FLAGS[:7] + (1,) + FLAGS[8:]
    low, _, _ = instrument("low-stack", source, low_stack)
    stack.run("entry-site", low, stack.trap_check(stack.invoke("go", 1), 4, 5))

    instrument("unknown-model", source, FLAGS[:3] + ("fuel-v3",) + FLAGS[4:], error="unknown --cost-model")
    instrument("unknown-profile", source, ("--profile", "production-v2", *FLAGS[2:]), error="unknown --profile")
    instrument("unknown-option", source, (*FLAGS, "--mystery"), error="unknown option")
    instrument("missing-report-value", source, (*FLAGS, "--report"), error="missing value for --report", report=False)
    instrument("report-option-value", source, (*FLAGS, "--report", "-bogus"),
               error="missing value for --report", report=False)
    instrument("duplicate-report", source, (*FLAGS, "--report", OUT / "extra.json"), error="duplicate --report")
    instrument("report-conflict", source, (*FLAGS, "--report", OUT / "report-conflict.wasm"),
               error="--report must differ", report=False)
    instrument("missing-memory", source, FLAGS[:10] + FLAGS[12:], error="requires --max-memory-pages")
    instrument("missing-table", source, FLAGS[:12] + FLAGS[14:], error="requires --max-table-elements")
    instrument("duplicate-model", source, (*FLAGS, "--cost-model", "fuel-v2"), error="duplicate --cost-model")
    for option, retired in (
        ("--codegen", ("p0", "P1", "p2", "p2-prefix", "join-span", "join-span-cached",
                       "join-span-compact", "join-span-compact-v2", "join-span-compact-next")),
        ("--cost-model", ("fuel-v1", "fuel-v1.2", "fuel-v1-experimental")),
    ):
        for value in retired:
            instrument(f"retired-{value}", source, (*default, option, value),
                       error=f"retired {option} '{value}'; use the default fuel-v2")
    instrument("ambiguous-import", source, (*FLAGS, "--allow-import", "a.b.c"), error="ambiguous allow-import")
    instrument("reinstrument", wasm, error="FuelGuard marker")

    hyphen_import = stack.compile_wat("hyphen-import", '(module (import "--env" "fn" (func)))')
    _, _, hyphen = instrument("allow-hyphen-import", hyphen_import,
                              (*FLAGS[:10], "--allow-import", "--env.fn"))
    assert hyphen["instrumentation"]["config"]["allowed_imports"] == [
        {"module": "--env", "name": "fn"},
    ]

    dotted_import = stack.compile_wat("dotted-import", '(module (import "a.b" "c" (func)))')
    _, _, dotted = instrument("allow-dotted-import", dotted_import,
                              (*FLAGS[:10], "--allow-import-pair", "a.b", "c"))
    assert dotted["instrumentation"]["config"]["allowed_imports"] == [
        {"module": "a.b", "name": "c"},
    ]
    instrument("reject-different-import-pair", dotted_import,
               (*FLAGS[:10], "--allow-import-pair", "a", "b.c"), error="import not allowed")

    _, _, compat = instrument("fuel-growth", source, ("--profile", "fuel-growth-v1", *FLAGS[4:6], *FLAGS[10:]))
    assert compat["instrumentation"]["config"]["max_call_depth"] is None
    assert compat["instrumentation"]["fuel_model"] == "fuel-v1"
    minimal = stack.compile_wat("minimal", "(module)")
    _, _, legacy = instrument("legacy", minimal, ("--profile", "legacy", "--fuel", 10))
    assert legacy["instrumentation"]["stack_model"] is None

    zero_source = stack.compile_wat("zero-source", '(module (memory 0) (table 0 0 funcref))')
    for option, other in (("--max-memory-pages", "--max-table-elements"),
                          ("--max-table-elements", "--max-memory-pages")):
        instrument(f"sign-only{option}", zero_source, (*FLAGS[:10], option, "-", other, 0),
                   error=f"missing value for {option}")
    _, _, zero = instrument("zero-limits", zero_source,
                            (*FLAGS[:10], "--max-memory-pages", 0, "--max-table-elements", 0))
    assert zero["instrumentation"]["config"]["max_memory_pages"] == 0
    assert zero["instrumentation"]["config"]["max_table_elements"] == 0
    check_table_sites()
    check_span_proof(default)
    print("Manifest, span proof, migration and diagnostic checks passed", flush=True)


if __name__ == "__main__":
    main()

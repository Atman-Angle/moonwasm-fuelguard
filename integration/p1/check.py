"""Check Fuel v2 WASI output boundaries, stack audit and rewritten references."""
import argparse
import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from integration.stack_pass import check as stack

runtime = stack.runtime
PREFIX = fr"""(module
  (import "wasi_snapshot_preview1" "fd_write" (func $write (param i32 i32 i32 i32) (result i32)))
  (memory (export "memory") 1 1)
  (data (i32.const 0) "\08\00\00\00\06\00\00\00ready\0a")
  (func (export "_start")
    block $after_write
      i32.const 1 i32.const 0 i32.const 1 i32.const 16 call $write drop br $after_write
    end
    {"nop " * 15}))"""


def build(source, label, fuel, flags=(), *, memory_pages=1, units=100000, depth=2):
    target = runtime.OUT / f"{label}.wasm"
    manifest = target.with_suffix(".json")
    summary = runtime.run(f"build-{label}", [
        "moonrun", stack.TOOL, source, "-o", target, "--report", manifest,
        "--fuel", fuel,
        "--max-stack-units", units, "--max-call-depth", depth,
        "--max-memory-pages", memory_pages, "--stack-layout", *flags,
    ], runtime.ok)
    runtime.run(f"validate-{label}", ["wasm-tools", "validate", target], runtime.ok)
    runtime.run(f"verify-{label}", [
        "moonrun", stack.TOOL, "verify", target, "--report", manifest], runtime.ok)
    doc = json.loads(manifest.read_bytes())
    assert doc["input_sha256"] == runtime.sha256(source)
    assert doc["output_sha256"] == runtime.sha256(target)
    assert doc["schema"] == "fuelguard-manifest-v2"
    assert doc["instrumentation"]["codegen"] == "fuel-v2-inline-v1"
    assert doc["instrumentation"]["fuel_model"] == "fuel-v2"
    runtime.artifact(label, target)
    runtime.artifact(f"{label}-manifest", manifest)
    rows = [tuple(map(int, items)) for items in re.findall(
        r"stack function=(\d+).*? auxiliary=(\d+).*? A=(\d+) C=(\d+)", summary)]
    assert rows and all(actual <= common for _, _, actual, common in rows)
    return target, doc, rows


def check_prefix():
    source = stack.compile_wat("prefix-source", PREFIX)
    flags = ("--allow-import", "wasi_snapshot_preview1.fd_write")
    for fuel in (9, 10, 24, 25, 26):
        label = f"wasi-prefix-{fuel}"
        product, _, _ = build(source, label, fuel, flags)
        for engine in ("wasmoon", "wasmtime"):
            name = f"{engine}-{label}"
            runtime.run(name, runtime.invoke(engine, product),
                        lambda rc, out, err: (rc == 0 and not err) if fuel >= 25 else
                        (rc != 0 and "unreachable" in err.lower()))
            expected = b"ready\n" if fuel >= 10 else b""
            assert (runtime.OUT / f"{name}.stdout").read_bytes() == expected
        # A registered host with a counter keeps the trapped instance available.
        shim = """(module $host
          (global $writes (export "writes") (mut i32) (i32.const 0))
          (func (export "fd_write") (param i32 i32 i32 i32) (result i32)
            global.get $writes i32.const 1 i32.add global.set $writes i32.const 0))
        (register "wasi_snapshot_preview1" $host)"""
        invocation = stack.invoke("_start")
        outcome = (stack.returns(invocation) if fuel >= 25 else
                   stack.trap_check(invocation, 1, 2 if fuel < 10 else 10))
        writes = stack.returns('(get $host "writes")', ("i32", int(fuel >= 10)))
        stack.wast(f"{label}-diagnostics",
                   "\n".join((shim, stack.wast_module(product), outcome, writes)),
                   1 + outcome.count("(assert_"))


def check_mixed_references():
    source = stack.compile_wat("mixed-references-source", f"""(module
      (type $result (func (result i32)))
      (import "spectest" "print" (func))
      (table 2 2 funcref)
      (global $ready (mut i32) (i32.const 0))
      (func $boot (export "boot") i32.const 17 global.set $ready)
      (func $read (type $result) {"nop " * 20} global.get $ready)
      (func $constant (type $result) i32.const 33)
      (func (export "read") (param i32) (result i32)
        local.get 0 call_indirect (type $result))
      (elem (i32.const 0) func $read $constant)
      (start $boot))""")
    flags = ("--max-table-elements", 2, "--allow-import", "spectest.print")
    checks = (stack.returns(stack.invoke("read", 0), ("i32", 17)),
              stack.returns(stack.invoke("read", 1), ("i32", 33)),
              stack.returns(stack.invoke("boot")))
    stack.run("mixed-references-original", source, *checks)
    product, _, rows = build(source, "mixed-references", 1000, flags)
    printed = stack.print_wasm("mixed-references", product)
    first_wrapper = 6  # Five original functions including the import, then Fuel failure.
    assert len(rows) == 11, rows
    assert f"(start {first_wrapper})" in printed
    assert f'(export "boot" (func {first_wrapper}))' in printed
    assert f'(export "read" (func {first_wrapper + 3}))' in printed
    assert re.search(rf"\(elem .*i32.const 0\) func {first_wrapper + 1} {first_wrapper + 2}\)", printed)
    stack.run("mixed-references-run", product, *checks)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    evidence = runtime.acceptance_directory()
    parser.add_argument("--out", type=Path, required=evidence is None, default=evidence)
    options = parser.parse_args()
    if not __debug__:
        parser.error("run Python without -O so assertions execute")
    runtime.OUT = stack.OUT = options.out.resolve()
    runtime.OUT.mkdir(parents=True, exist_ok=evidence == stack.OUT)
    stack.build_instrument("build-cli")
    check_prefix()
    check_mixed_references()


if __name__ == "__main__":
    main()

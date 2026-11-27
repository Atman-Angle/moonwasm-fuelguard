"""Run the fuel-v2 F0 and boundary cases on the pinned Linux engines."""

import argparse
import json
import platform
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from integration.stack_pass import check as stack

runtime = stack.runtime


def instrument(name, source, budget, *, units=100000, depth=128):
    wasm = stack.OUT / f"{name}.wasm"
    report = wasm.with_suffix(".json")
    runtime.run(f"instrument-{name}", [
        "moonrun", stack.TOOL, source, "-o", wasm, "--fuel", budget,
        "--max-stack-units", units, "--max-call-depth", depth,
        "--max-memory-pages", 64, "--max-table-elements", 64,
        "--allow-import", "wasi_snapshot_preview1.fd_write", "--report", report,
    ], runtime.ok)
    runtime.run(f"validate-{name}", ["wasm-tools", "validate", wasm], runtime.ok)
    runtime.run(f"verify-{name}", ["moonrun", stack.TOOL, "verify", wasm, "--report", report],
                runtime.ok)
    manifest = json.loads(report.read_text(encoding="utf-8"))
    details = manifest["instrumentation"]
    assert manifest["schema"] == "fuelguard-manifest-v2" and manifest["deterministic"] is True
    assert not {"sites", "fuel_spans", "appended", "features"} & details.keys()
    assert details["fuel_model"] == "fuel-v2"
    assert details["codegen"] == "fuel-v2-inline-v1"
    runtime.artifact(name, wasm)
    runtime.artifact(f"{name}-manifest", report)
    return wasm, details


def repeat_delivery(name, source, budget, **limits):
    first, details = instrument(name, source, budget, **limits)
    report = first.with_suffix(".json")
    for repeat in (2, 3):
        other, _ = instrument(f"{name}-repeat-{repeat}", source, budget, **limits)
        assert other.read_bytes() == first.read_bytes()
        assert other.with_suffix(".json").read_bytes() == report.read_bytes()
    return first, details


def resolve_site(name, source, product, site, expected, exit_code=0):
    runtime.run(name, [
        "moonrun", stack.TOOL, "resolve-site", source, product,
        "--report", product.with_suffix(".json"), site,
    ], lambda code, out, err: code == exit_code and out == expected and not err)


def hello():
    source = runtime.ROOT / runtime.FIXTURES["hello"][0]
    assert runtime.sha256(source) == runtime.BASELINE_HASHES["hello"]
    runtime.run("validate-f0-original", ["wasm-tools", "validate", source], runtime.ok)
    runtime.artifact("f0-original", source)
    enough, _ = repeat_delivery("f0-enough", source, 100000)
    low, _ = instrument("f0-low", source, 1)
    # F0 has 2368 charged instructions before function 43 and one _start
    # entry site. The first instruction of _start is i32.const 100.
    first = 2370
    for engine in ("wasmoon", "wasmtime"):
        original = f"{engine}-f0-original"
        protected = f"{engine}-f0-enough"
        for name, wasm in ((original, source), (protected, enough)):
            runtime.run(name, runtime.invoke(engine, wasm),
                        lambda code, out, _err: code == 0 and out == "5050\n111\n190")
        assert (stack.OUT / f"{original}.stdout").read_bytes() == (
            stack.OUT / f"{protected}.stdout"
        ).read_bytes()
        runtime.run(f"{engine}-f0-low-wasi", runtime.invoke(engine, low),
                    lambda code, out, err: code > 0 and not out and "unreachable" in err.lower())
    # The export traps before its first source instruction, so the import
    # is never called. Bind a WASI stub to retain the instance and inspect globals.
    host = """(module $host
      (func (export "fd_write") (param i32 i32 i32 i32) (result i32) unreachable))
    (register "wasi_snapshot_preview1" $host)"""
    stack.wast("f0-low-diagnostics", "\n".join([
        host, stack.wast_module(low), stack.trap_check(stack.invoke("_start"), 1, first),
    ]), 3)


def boundaries():
    source = stack.compile_wat("division", """(module (func (export "go") (result i32)
      i32.const 1 i32.const 0 i32.div_s))""")
    low, _ = instrument("division-low", source, 5)
    exact, _ = instrument("division-exact", source, 6)
    stack.run("division-static-first-site", low, stack.trap_check(stack.invoke("go"), 1, 2))
    resolve_site("locate-entry", source, low, 1, "site=1 function=0 entry=export-or-start")
    resolve_site("locate-prepaid-instruction", source, low, 2,
                 "site=2 function=0 instruction=0 opcode=i32.const")
    resolve_site("locate-unknown", source, low, 5,
                 "instrument: site 5 does not exist in the original Wasm", exit_code=2)
    stack.run("division-native-trap", exact,
              stack.trap_check(stack.invoke("go"), 0, 0, "integer divide by zero"))

    division = source
    division_product = low
    source = stack.compile_wat("grow", """(module (memory 1 2)
      (func (export "go") (param i32) (result i32)
        local.get 0 if i32.const 1 memory.grow drop end memory.size))""")
    # The taken path costs 2 + (1 + 8 + 1) + 64 + 2.
    exact, _ = instrument("grow-exact", source, 78)
    stack.run("grow-cache-exact", exact, stack.returns(stack.invoke("go", 1), ("i32", 2)))
    low, _ = instrument("grow-tail-low", source, 77)
    stack.run("grow-cache-reloads", low, stack.trap_check(stack.invoke("go", 1), 1, 7))
    low, _ = instrument("grow-charge-low", source, 75)
    stack.run("grow-dynamic-site", low, stack.trap_check(stack.invoke("go", 1), 1, 5))
    resolve_site("locate-dynamic-growth", source, low, 5,
                 "site=5 function=0 instruction=3 opcode=memory.grow")
    resolve_site("locate-mismatched-original", source, division_product, 2,
                 "instrument: original Wasm SHA-256 does not match manifest input_sha256", exit_code=2)

    source = stack.compile_wat("bulk-call", """(module (memory 1)
      (func $leaf (result i32) i32.const 3)
      (func (export "go") (param i32) (result i32)
        local.get 0 if
          i32.const 0 i32.const 42 i32.const 1 memory.fill
          call $leaf drop
        end
        i32.const 0 i32.load8_u))""")
    # The taken path costs 2 + 11 + 1 (fill surcharge) + 1 (callee) + 4.
    exact, _ = instrument("bulk-call-exact", source, 19)
    stack.run("bulk-call-cache-exact", exact, stack.returns(stack.invoke("go", 1), ("i32", 42)))
    low, _ = instrument("bulk-call-low", source, 18)
    stack.run("bulk-call-cache-reloads", low, stack.trap_check(stack.invoke("go", 1), 1, 11))
    untaken, _ = instrument("bulk-call-untaken", source, 6)
    stack.run("bulk-call-untaken-arm", untaken, stack.returns(stack.invoke("go", 0), ("i32", 0)))

    source = stack.compile_wat("loop", '(module (func (export "go") loop br 0 end))')
    metered, _ = instrument("loop-low", source, 4)
    stack.run("loop-backedge", metered, stack.trap_check(stack.invoke("go"), 1, 3))


def inline_leaf():
    source = stack.compile_wat("inline-leaf", """(module
      (func $leaf (param i32) (result i32) local.get 0 i32.const 1 i32.add)
      (func (export "go") (result i32) i32.const 7 call $leaf)
      (func (export "nan") (result f64) f64.const nan:0x1234))""")
    exact, _ = instrument("inline-leaf-exact", source, 7)
    wat = runtime.run("print-inline-leaf", ["wasm-tools", "print", exact], runtime.ok)
    assert "block (type " in wat and "local.set" in wat
    stack.run("inline-leaf-return", exact, stack.returns(stack.invoke("go"), ("i32", 8)))
    low, _ = instrument("inline-leaf-low", source, 6)
    stack.run("inline-leaf-fuel-site", low, stack.trap_check(stack.invoke("go"), 1, 1))
    shallow, _ = instrument("inline-leaf-shallow", source, 7, depth=1)
    stack.run("inline-leaf-depth-site", shallow, stack.trap_check(stack.invoke("go"), 5, 6))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    if not __debug__:
        raise SystemExit("Fuel v2 delivery verification requires Python assertions enabled")
    if (platform.system(), platform.machine()) != ("Linux", "x86_64"):
        raise SystemExit("S31 requires x86_64 Linux")
    stack.OUT = runtime.OUT = args.out.resolve()
    stack.OUT.mkdir(parents=True)
    for name, version in runtime.VERSIONS.items():
        runtime.run(f"version-{name}", [name, "--version"],
                    lambda code, out, _err: code == 0 and version in out)
    stack.build_instrument("build-instrument")
    hello()
    boundaries()
    inline_leaf()
    print("fuel-v2 F0 and boundary checks passed in both engines")


if __name__ == "__main__":
    main()

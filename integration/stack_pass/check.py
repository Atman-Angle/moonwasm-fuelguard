"""Run S11 against MoonBit-generated binaries in the two pinned Linux engines."""
import argparse
import json
import platform
import re
import resource
import shutil
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "runtime"))
sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
import check as runtime
from bench.dataset import DATASET_SHA256, MANIFEST
from integration.generated.recipes import JOIN_LAYOUTS

OUT = runtime.acceptance_directory() or runtime.ROOT / "_build/s11-stack"
BUILT_TOOL = runtime.ROOT / "_build/wasm/debug/build/cmd/instrument/instrument.wasm"
TOOL = BUILT_TOOL
MAX = (1 << 63) - 1
PACKED_MAX = (1 << 31) - 1
CODEGEN = "p0"


def charge_helper_offset():
    # The reference fixtures below contain charged, loop-free functions.
    if CODEGEN in ("join-span-compact", "join-span-compact-v2"):
        return 2
    return int(CODEGEN in ("p1", "fuel-v2", *JOIN_LAYOUTS))


def build_instrument(label):
    global TOOL
    runtime.run(label, ["moon", "build", "--target", "wasm", "--debug", "cmd/instrument"],
                runtime.ok, timeout=180)
    if runtime.acceptance_directory():
        TOOL = OUT / "instrument-tool.wasm"
        shutil.copyfile(BUILT_TOOL, TOOL)
    return runtime.artifact("instrument-cli", TOOL)


def compile_wat(name, wat):
    text = OUT / f"{name}.wat"
    text.write_text(wat, encoding="utf-8")
    target = text.with_suffix(".wasm")
    runtime.run(f"parse-{name}", ["wasm-tools", "parse", text, "-o", target], runtime.ok)
    runtime.run(f"validate-{name}", ["wasm-tools", "validate", target], runtime.ok)
    return runtime.artifact(name, target)


def instrument(name, source, units=PACKED_MAX, depth=PACKED_MAX, fuel=MAX, flags=()):
    target = OUT / f"{name}.wasm"
    target.unlink(missing_ok=True)
    note = runtime.run(f"instrument-{name}", [
        "moonrun", TOOL, source, "-o", target, "--fuel", fuel,
        "--max-stack-units", units, "--max-call-depth", depth, "--stack-layout",
        "--codegen", CODEGEN, *flags,
    ], runtime.ok)
    runtime.run(f"validate-{name}", ["wasm-tools", "validate", target], runtime.ok)
    caps = {}
    for index, actual, shared in re.findall(r"stack function=(\d+).*? A=(\d+) C=(\d+)", note):
        a, c = int(actual), int(shared)
        assert 0 < a <= c <= PACKED_MAX, note
        caps[int(index)] = c
    assert caps, note
    return runtime.artifact(name, target), caps


def print_wasm(name, path):
    return runtime.run(f"print-{name}", ["wasm-tools", "print", path], runtime.ok)


def packed_stack_initial(name, path):
    text = print_wasm(name, path)
    code = int(re.search(r'\(export "__moonwasm_trap_code" \(global (\d+)\)\)', text)[1])
    balance = code + 2
    match = re.search(
        rf'\(global \(;{balance};\) \(mut i64\) i64\.const (-?\d+)\)', text
    )
    assert match, text
    return int(match[1])


def wast_module(path):
    b = "".join(f"\\{byte:02x}" for byte in path.read_bytes())
    return f'(module binary "{b}")'


def wast(name, script, count):
    test = OUT / f"{name}.wast"
    test.write_text(script + "\n", encoding="ascii")
    for engine, command in (
        ("wasmtime", ["wasmtime", "wast", "-W", "max-wasm-stack=524288"]),
        ("wasmoon", ["wasmoon", "test", "--show-success"]),
    ):
        runtime.run(f"{engine}-{name}", [*command, test],
                    lambda code, out, _err: code == 0 and (engine == "wasmtime" or
                        (f"Passed:  {count}\n" in out and "Skipped: 0" in out)))


def run(name, path, *checks):
    wast(name, "\n".join([wast_module(path), *checks]),
         sum(check.count("(assert_") for check in checks))


def invoke(export, *values):
    return f'(invoke "{export}"' + "".join(f" (i32.const {n})" for n in values) + ")"


def returns(invocation, *expected):
    return f"(assert_return {invocation}" + "".join(
        f" ({kind}.const {value})" for kind, value in expected) + ")"


def trap_check(invocation, code, site, message="unreachable"):
    return f'''(assert_trap {invocation} "{message}")
(assert_return (get "__moonwasm_trap_code") (i32.const {code}))
(assert_return (get "__moonwasm_trap_site") (i32.const {site}))'''


def direct():
    large = "i64 " * 256
    original = compile_wat("direct-source", f"""(module
      (func $leaf (param i32) (result i32 i64)
        (local {large})
        local.get 0 i64.const 7 return)
      (func $run (export "run") (export "alias") (param i32) (result i32 i64)
        local.get 0 call $leaf))""")
    _, costs = instrument("direct-audit", original)
    assert costs[0] == 395 and costs[1] == 139, costs
    exact = costs[0] + costs[1]
    expected = (("i32", 42), ("i64", 7))
    run("direct-original", original, returns(invoke("run", 42), *expected))
    ok, _ = instrument("direct-exact", original, units=exact, depth=2, fuel=14)
    run("direct-restores-fuel-persists", ok,
        returns(invoke("run", 42), *expected),
        returns(invoke("alias", 7), ("i32", 7), ("i64", 7)),
        trap_check(invoke("run", 42), 1, 5))
    for name, units, depth, fuel, code, site in (
        ("stack-minus-one", exact - 1, 2, MAX, 4, 6),
        ("depth-minus-one", exact, 1, MAX, 5, 6),
        ("stack-before-depth", exact - 1, 1, MAX, 4, 6),
        ("call-fuel-first", exact - 1, 1, 3, 1, 5 if CODEGEN == "fuel-v2" else 6),
        ("export-before-fuel", costs[1] - 1, 2, 1, 4, 4),
    ):
        output, _ = instrument(f"direct-{name}", original, units, depth, fuel)
        run(f"direct-{name}", output, trap_check(invoke("run", 42), code, site))


def indirect():
    source = compile_wat("indirect-source", """(module
      (type $same (func (param i32) (result i32 i64)))
      (type $duplicate (func (param i32) (result i32 i64)))
      (type $wrong (func (result i64)))
      (table $fixed 6 6 funcref)
      (func $target (export "target") (type $same) local.get 0 i64.const 19 return)
      (export "alias" (func $target))
      (func $bad (type $wrong) i64.const 99)
      (func $ind (export "ind") (param i32 i32) (result i32 i64)
        local.get 0 local.get 1 call_indirect (type $duplicate))
      (elem (i32.const 0) func $target $bad)
      (elem (i32.const 3) funcref (ref.func $target) (ref.null func))
      (elem (table $fixed) (i32.const 5) funcref (ref.func $target)))""")
    flags = ["--max-table-elements", 6]
    _, costs = instrument("indirect-audit", source, flags=flags)
    exact = costs[0] + costs[2]
    output, _ = instrument("indirect-exact", source, exact, 2, flags=flags)
    wat = print_wasm("indirect-exact", output)
    offset = charge_helper_offset()
    assert f'(export "target" (func {3 + offset}))' in wat
    assert f'(export "alias" (func {3 + offset}))' in wat
    assert f'(export "ind" (func {6 + offset}))' in wat
    assert re.search(rf"\(elem .*i32.const 0\) func {4 + offset} {5 + offset}\)", wat), wat
    assert re.search(rf"\(elem .*i32.const 3\) funcref \(ref.func {4 + offset}\) \(ref.null func\)\)", wat), wat
    assert re.search(rf"\(elem .*i32.const 5\) funcref \(ref.func {4 + offset}\)\)", wat), wat
    assert '(table $fixed (;0;) 6 6 funcref)' in wat
    expected = (("i32", 17), ("i64", 19))
    for name, module in (("indirect-original", source), ("indirect-exact", output)):
        run(name, module, returns(invoke("ind", 17, 0), *expected),
            returns(invoke("ind", 17, 3), *expected),
            returns(invoke("ind", 17, 5), *expected),
            returns(invoke("alias", 17), *expected))
    low, _ = instrument("indirect-stack-low", source, exact - 1, 1, flags=flags)
    run("indirect-stack-low", low, trap_check(invoke("ind", 17, 0), 4, 9))
    deep, _ = instrument("indirect-depth-low", source, exact, 1, flags=flags)
    run("indirect-depth-low", deep, trap_check(invoke("ind", 17, 3), 5, 9))
    for name, slot, message in (("type", 1, "indirect call type mismatch"),
                                ("hole", 2, "uninitialized element"),
                                ("null", 4, "uninitialized element"),
                                ("bounds", 6, "undefined element")):
        # The budget could not enter any valid target. Invalid targets must trap
        # natively after Fuel and leave the diagnostic globals untouched.
        run(f"indirect-native-{name}", low, trap_check(invoke("ind", 17, slot), 0, 0, message))
    fuel_low, _ = instrument("indirect-fuel-first", source, exact - 1, 1, 6, flags)
    run("indirect-fuel-first", fuel_low,
        trap_check(invoke("ind", 17, 6), 1, 7 if CODEGEN == "fuel-v2" else 9))


def starts():
    source = compile_wat("start-source", """(module
      (global $ready (mut i32) (i32.const 0))
      (func $boot (export "boot") i32.const 42 global.set $ready)
      (start $boot)
      (func $peek (export "peek") (result i32) global.get $ready))""")
    _, costs = instrument("start-audit", source)
    output, _ = instrument("start-exact", source, max(costs[0], costs[1]), 1)
    wat = print_wasm("start-exact", output)
    wrapper = 2 + charge_helper_offset()
    assert f"(start {wrapper})" in wat and f'(export "boot" (func {wrapper}))' in wat, wat
    for name, module in (("start-original", source), ("start-exact", output)):
        run(name, module, returns(invoke("peek"), ("i32", 42)),
            returns(invoke("boot")), returns(invoke("peek"), ("i32", 42)))
    low, _ = instrument("start-stack-low", source, costs[0] - 1, 1)
    wast("start-stack-low", f'(assert_trap {wast_module(low)} "unreachable")', 1)


def reused_reservation():
    source = compile_wat("reuse-source", """(module
      (func $leaf (param i32) (result i32) local.get 0)
      (func (export "reuse") (param i32) (result i32)
        local.get 0 call $leaf drop
        local.get 0 call $leaf))""")
    _, costs = instrument("reuse-audit", source, units=1000, depth=2)
    summary = (OUT / "instrument-reuse-audit.stdout").read_text(encoding="utf-8")
    assert "stack audit: stack-v2" in summary, summary
    max_cost = max(1000, *costs.values())
    step = 1 << (max_cost.bit_length() + 1)
    assert packed_stack_initial("reuse-audit", OUT / "reuse-audit.wasm") == 1000 + 2 * step
    exact = costs[0] + costs[1]
    output, _ = instrument("reuse-exact", source, exact, 2)
    run("reuse-exact", output,
        returns(invoke("reuse", 19), ("i32", 19)),
        returns(invoke("reuse", 23), ("i32", 23)))


def imported():
    source = compile_wat("import-source", """(module
      (import "spectest" "print_i32" (func $host (param i32)))
      (export "host" (func $host))
      (func $run (export "run") (param i32) local.get 0 call $host))""")
    flags = ["--allow-import", "spectest.print_i32"]
    _, costs = instrument("import-audit", source, flags=flags)
    output, _ = instrument("import-exact", source, costs[0] + costs[1], 2, flags=flags)
    read_imports = lambda wat: re.findall(r"^\s*\(import .*$", wat, flags=re.MULTILINE)
    before, after = print_wasm("import-before", source), print_wasm("import-after", output)
    assert read_imports(before) == read_imports(after)
    wrapper = 2 + charge_helper_offset()
    assert f'(export "host" (func {wrapper}))' in after and 'call $host' in after
    run("import-exact", output, returns(invoke("host", 3)), returns(invoke("run", 11)),
        returns(invoke("host", 4)))
    low, _ = instrument("import-under", source, costs[0] + costs[1] - 1, 2, flags=flags)
    run("import-under", low, trap_check(invoke("run", 11), 4, 4))


def recursion():
    work = """(param i32) (result i32 i64)
      (local %s)
      local.get 0 i32.eqz
      if i32.const 77 i64.const 88 return end
      local.get 0 i32.const 1 i32.sub call $%s"""
    large = "i64 " * 192
    source = compile_wat("recursion-source", '(module (export "run" (func $a)) '
                         f'(func $a {work % (large, "b")}) (func $b {work % (large, "a")}))')
    _, costs = instrument("recursion-audit", source)
    exact = 9 * costs[0] + 8 * costs[1]
    expected = (("i32", 77), ("i64", 88))
    run("recursion-original", source, returns(invoke("run", 16), *expected))
    output, _ = instrument("recursion-safe", source, exact, 17)
    run("recursion-safe", output, returns(invoke("run", 16), *expected))
    low, _ = instrument("recursion-pressure", source, exact - 1, 17)
    # At these pinned engine stack settings, adversarial input is stopped by
    # the guest's controlled trap. A native stack overflow cannot pass.
    run("recursion-pressure", low, trap_check(invoke("run", 4096), 4, 21))


def imported_start_and_table():
    source = compile_wat("import-start-table-source", """(module
      (type $v (func))
      (import "spectest" "print" (func $init (type $v)))
      (table 1 1 funcref)
      (elem (i32.const 0) func $init)
      (start $init)
      (export "init" (func $init))
      (func (export "via_table") i32.const 0 call_indirect (type $v)))""")
    flags = ["--allow-import", "spectest.print", "--max-table-elements", 1]
    _, costs = instrument("import-start-table-audit", source, flags=flags)
    output, _ = instrument("import-start-table-exact", source, costs[0] + costs[1], 2,
                           flags=flags)
    wat = print_wasm("import-start-table-exact", output)
    wrapper = 2 + charge_helper_offset()
    assert f"(start {wrapper})" in wat and f'(export "init" (func {wrapper}))' in wat
    assert re.search(rf"\(elem .*i32.const 0\) func {wrapper + 1}\)", wat), wat
    for name, module in (("import-start-original", source), ("import-start-table-exact", output)):
        run(name, module, returns(invoke("init")), returns(invoke("via_table")))


def typed_growth():
    source = compile_wat("typed-growth-source", """(module
      (type $v (func (param i64) (result i64 i64)))
      (table 1 1 funcref)
      (memory 1 3)
      (elem (i32.const 0) func $wide)
      (func $wide (type $v) local.get 0 i64.const 2)
      (func (export "wide") (type $v)
        local.get 0 i32.const 0 call_indirect (type $v))
      (func (export "grow") (param i32) (result i32) local.get 0 memory.grow))""")
    flags = ["--max-table-elements", 1, "--max-memory-pages", 3]
    _, costs = instrument("typed-growth-audit", source, flags=flags)
    output, _ = instrument("typed-exact", source, costs[0] + costs[1], 2, flags=flags)
    expected = '(assert_return (invoke "wide" (i64.const 11)) (i64.const 11) (i64.const 2))'
    for name, module in (("typed-original", source), ("typed-exact", output)):
        run(name, module, expected)
    # A generated helper executes as part of the caller's reservation.
    grow, _ = instrument("growth-helper-depth-one", source, costs[2], 1, flags=flags)
    run("growth-helper-depth-one", grow, returns(invoke("grow", 1), ("i32", 1)),
        returns(invoke("grow", 1), ("i32", 2)))


def frozen_workloads():
    assert runtime.sha256(MANIFEST) == DATASET_SHA256
    doc = json.loads(MANIFEST.read_bytes())
    apps = {row["path"]: row for row in doc["entries"]
            if row["split"] == "tuning" and row["kind"] == "application"}
    for name, (path, expected) in runtime.FIXTURES.items():
        entry = apps[path]
        assert entry["stdout"] == expected + "\n"
        source = runtime.ROOT / path
        assert source.stat().st_size == entry["bytes"] and runtime.sha256(source) == entry["sha256"]
        yield name, source, expected, entry["stack_units"], entry["depth"]


def workloads():
    if not __debug__:
        raise RuntimeError("stack workload verification requires Python assertions enabled")
    flags = ("--allow-import", "wasi_snapshot_preview1.fd_write",
             "--max-memory-pages", 64, "--max-table-elements", 64)
    for name, source, expected, units, depth in frozen_workloads():
        pairs = []
        for repeat in range(3):
            label = f"workload-{name}" if repeat == 0 else f"workload-{name}-{repeat}"
            report = OUT / f"{label}.json"
            report.unlink(missing_ok=True)
            output, costs = instrument(label, source, units=units, depth=depth,
                                       flags=(*flags, "--report", report))
            runtime.run(f"verify-{label}", ["moonrun", TOOL, "verify", output, "--report", report],
                        runtime.ok)
            runtime.artifact(f"{label}-report", report)
            pairs.append((output, runtime.sha256(output), runtime.sha256(report)))
        output, wasm_hash, report_hash = pairs[0]
        assert all(pair[1:] == (wasm_hash, report_hash) for pair in pairs)
        max_cost = max(units, *costs.values())
        step = 1 << (max_cost.bit_length() + 1)
        assert packed_stack_initial(f"packed-workload-{name}", output) == units + depth * step
        for engine in ("wasmoon", "wasmtime"):
            runtime.run(f"{engine}-workload-{name}", runtime.invoke(engine, output),
                        lambda code, out, _err: code == 0 and out == expected)


def options():
    source = OUT / "direct-source.wasm"
    for name, args, message in (
        ("partial-limits", ["--max-stack-units", 1], "must be provided together"),
        ("zero-depth", ["--max-stack-units", 1, "--max-call-depth", 0], "must be positive"),
        ("legacy-stack", ["--max-stack-units", 1, "--max-call-depth", 1,
                           "--profile", "legacy"], "require production-v1"),
    ):
        reject_options(name, source, args, message)
    for bound in (PACKED_MAX + 1, MAX):
        for field, units, depth in (
            ("units", bound, 1),
            ("depth", 1, bound),
        ):
            reject_options(f"oversize-{field}-{bound}", source,
                           ["--max-stack-units", units, "--max-call-depth", depth],
                           "1..=2147483647")


def reject_options(name, source, args, message):
    output = OUT / f"{name}.wasm"
    report = output.with_suffix(".json")
    for path in (output, report):
        path.unlink(missing_ok=True)
    runtime.run(name, ["moonrun", TOOL, source, "-o", output, "--report", report,
                       "--fuel", 1000, *args],
                lambda code, out, err: code == 2 and message in out + err)
    if output.exists() or report.exists():
        raise RuntimeError(f"{name}: rejected stack configuration produced an artifact")


def main():
    global CODEGEN
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--codegen", choices=("p0", "p1", "p2", "fuel-v2", *JOIN_LAYOUTS),
                        default="fuel-v2")
    CODEGEN = parser.parse_args().codegen
    assert platform.system() == "Linux" and platform.machine() == "x86_64"
    runtime.OUT = OUT
    OUT.mkdir(parents=True, exist_ok=True)
    print(platform.platform(), platform.libc_ver(), "RLIMIT_STACK",
          resource.getrlimit(resource.RLIMIT_STACK))
    for tool, version in runtime.VERSIONS.items():
        runtime.run(f"version-{tool}", [tool, "--version"],
                    lambda code, out, err: code == 0 and version in out + err)
    runtime.run("version-moon", ["moon", "version"], runtime.ok)
    build_instrument("build-cli")
    direct()
    reused_reservation()
    indirect()
    starts()
    imported()
    recursion()
    imported_start_and_table()
    typed_growth()
    workloads()
    options()
    print("S11 A05-A08 instrumentation checks passed")


if __name__ == "__main__":
    main()

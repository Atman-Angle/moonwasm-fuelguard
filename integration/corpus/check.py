"""S16 named differential corpus and MoonBit demonstrations on Linux x86_64."""

import argparse
import json
import platform
import re
import resource
import shutil
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))

from integration.corpus.cases import CONTROL, STRICT, call, get, i32, trap
from integration.policy.check import HEADER, code_body, section
from integration.stack_pass import check as stack

runtime = stack.runtime
MAX = stack.MAX
FD_WRITE = "wasi_snapshot_preview1.fd_write"
WASI_FLAGS = ("--wasi", "--wasi-stdout", "--allow-import", FD_WRITE)
STAGES = ["FuelPass", "GrowthPass", "StackPass"]
SOURCE = Path(__file__).resolve().parent
CODEGEN = "fuel-v2"
LAYOUTS = {
    "fuel-v2": "fuel-v2-inline-v1",
    "p0": "inline-per-instruction-v1", "p1": "p1-helper-v1",
    "p2": "p2-hybrid-loop-inline-sites21-v1",
    "join-span": "join-span-debit-first-v1",
    "join-span-cached": "join-span-packed-cache-v1",
    "join-span-compact": "join-span-compact-v1",
    "join-span-compact-v2": "join-span-compact-v2",
}
JOIN_LAYOUTS = stack.JOIN_LAYOUTS


def cli(*args):
    return ["moonrun", stack.TOOL, *args]


def compile_source(name, path):
    return stack.compile_wat(name, path.read_text(encoding="utf-8"))


def imports(wat):
    # wasm-tools prints each complete import descriptor on one line.
    return re.findall(r"^\s*\(import .+$", wat, re.MULTILINE)


def instrument(name, source, *, fuel=MAX, units=100000, depth=64,
               memory=3, table=4, allowed=(), error=None, extra=()):
    output = runtime.OUT / f"{name}.wasm"
    report = runtime.OUT / f"{name}.json"
    assert source != output and not output.exists() and not report.exists()
    initial_hash = runtime.sha256(source)
    args = [source, "-o", output, "--report", report, "--fuel", fuel,
            "--max-stack-units", units, "--max-call-depth", depth,
            "--max-memory-pages", memory, "--max-table-elements", table]
    for name_ in allowed:
        args.extend(["--allow-import", name_])
    if "--codegen" not in extra:
        args.extend(["--codegen", CODEGEN])
    runtime.artifact(f"{name}-input", source)
    summary = runtime.run(f"instrument-{name}", cli(*args, *extra), lambda rc, out, err:
                rc == (2 if error else 0) and (error is None or error in out + err), timeout=120)
    assert runtime.sha256(source) == initial_hash
    if error:
        assert not output.exists() and not report.exists(), name
        return
    runtime.artifact(name, output)
    runtime.artifact(f"{name}-manifest", report)
    manifest = json.loads(report.read_bytes())
    assert f"passes: {', '.join(STAGES)}" in summary
    assert manifest["schema"] == "fuelguard-manifest-v2"
    assert manifest["input_sha256"] == initial_hash
    assert manifest["output_sha256"] == runtime.sha256(output)
    assert manifest["instrumentation"]["codegen"] == LAYOUTS[CODEGEN]
    runtime.run(f"verify-{name}", cli("verify", output, "--report", report), runtime.ok)
    runtime.run(f"validate-{name}", ["wasm-tools", "validate", output], runtime.ok)
    assert imports(stack.print_wasm(f"{name}-original", source)) == imports(
        stack.print_wasm(f"{name}-product", output)), name
    return output, manifest


def strict_cases(modules):
    assert len(STRICT) >= 60 and len(CONTROL) >= 20
    assert len({case.name for case in STRICT}) == len(STRICT)
    assert len({(case.fixture, case.checks) for case in STRICT}) == len(STRICT)
    products = {}
    for case in STRICT:
        if case.fixture not in products:
            products[case.fixture], _ = instrument(f"strict-{case.fixture}", modules[case.fixture])
        runtime.artifact(f"{case.name}-original", modules[case.fixture])
        runtime.artifact(f"{case.name}-product", products[case.fixture])
        stack.run(f"{case.name}-original", modules[case.fixture], *case.checks)
        stack.run(f"{case.name}-product", products[case.fixture], *case.checks)
    print(f"Strict cases passed: {len(STRICT)}, including {len(CONTROL)} control/stack cases")
    return products


def run_wasi(name, original, product, expected):
    for engine in ("wasmoon", "wasmtime"):
        for variant, module in (("original", original), ("product", product)):
            log = f"{name}-{engine}-{variant}"
            runtime.run(log, runtime.invoke(engine, module), lambda rc, out, _:
                        rc == 0 and out == expected)
            assert (runtime.OUT / f"{log}.stdout").read_bytes() == (expected + "\n").encode()


def build_runner():
    target = ROOT / "_build/s16/native"
    runtime.run("build-runner", ["bash", "-c",
                'cd "$1" && exec moon build --target native --release . --target-dir "$2"',
                "build", ROOT / "cmd/run", target], runtime.ok, timeout=600)
    binaries = list((target / "native/release/build").rglob("fuelguard-run.exe"))
    assert len(binaries) == 1
    runner = binaries[0]
    if runtime.acceptance_directory():
        runner = runtime.OUT / runner.name
        shutil.copy2(binaries[0], runner)
    runtime.artifact("product-runner", runner)
    runtime.run("runner-version", [runner, "--version"], lambda rc, out, _:
                rc == 0 and out == "FuelGuard run 0.2.2 (wasmoon 0.18.0)")
    return runner


def workloads(runner):
    for index, (name, source, expected, units, depth) in enumerate(stack.frozen_workloads()):
        case = f"F{index}-{name}"
        runtime.artifact(f"{case}-locked", source)
        runtime.run(f"validate-{case}-original", ["wasm-tools", "validate", source], runtime.ok)
        product, _ = instrument(case, source, units=units, depth=depth, memory=64,
                                table=64, allowed=(FD_WRITE,))
        run_wasi(case, source, product, expected)
        if name == "lisp_eval":
            # Change the workload input, keeping the published Wasm sections intact.
            data = source.read_bytes()
            original_count = "(count 400)".encode("utf-16le")
            assert data.count(original_count) == 1
            bounded_source = runtime.OUT / "F2-product-runner-input.wasm"
            bounded_source.write_bytes(data.replace(original_count, "(count 020)".encode("utf-16le")))
            runtime.artifact("F2-product-runner-input", bounded_source)
            runtime.run("validate-F2-runner-original",
                        ["wasm-tools", "validate", "--features=-simd", bounded_source], runtime.ok)
            bounded_product, _ = instrument("F2-product-runner", bounded_source,
                                            units=100000, depth=128, memory=64, table=64,
                                            allowed=(FD_WRITE,))
            run_wasi("F2-bounded", bounded_source, bounded_product, expected)
            runtime.run("F2-bounded-product-runner", [runner, bounded_product, *WASI_FLAGS],
                        lambda rc, out, err: rc == 0 and out == expected and not err)
            bounded, _ = instrument("F2-product-runner-depth-cap", source, units=100000,
                                    depth=128, memory=64, table=64, allowed=(FD_WRITE,))
            workload_depth_limit(runner, bounded)
        else:
            runtime.run(f"{case}-product-runner", [runner, product, *WASI_FLAGS],
                        lambda rc, out, err: rc == 0 and out == expected and not err)
        assert_no_simd(case, source)


def workload_depth_limit(runner, bounded):
    def unreachable(rc, out, err):
        return rc > 0 and out == "Number(2584)" and "unreachable" in err.lower()

    runtime.run("F2-limited-wasmoon", runtime.invoke("wasmoon", bounded), unreachable)
    core = runtime.OUT / "F2-limited.core.wasm"
    wasmtime = runtime.invoke("wasmtime", bounded)
    runtime.run("F2-limited-wasmtime", [*wasmtime[:-1], "-D", f"coredump={core}", bounded], unreachable)
    runtime.artifact("F2-limited-wasmtime-core", core)
    dump = stack.print_wasm("F2-limited-wasmtime-core", core)
    wat = (runtime.OUT / "print-F2-product-runner-depth-cap-product.stdout").read_text()
    assert len(imports(wat)) == 1 and "(func " in imports(wat)[0]
    trap_exports = {}
    for kind in ("code", "site"):
        export = re.search(rf'\(export "__moonwasm_trap_{kind}" \(global (\d+)\)\)', wat)
        assert export, kind
        trap_exports[kind] = export[1]
    # S25: freeze the trap code/site from the first runner observation and
    # assert identical values across engines and repeated runs (determinism).
    observed = {}

    def capture(rc, out, err):
        match = re.search(r"resource-trap code=(\d+) site=(\d+)", err)
        assert rc > 0 and out == "Number(2584)" and match, (rc, out, err)
        observed["pair"] = (match.group(1), match.group(2))
        return True

    runtime.run("F2-limited-product-runner", [runner, bounded, *WASI_FLAGS], capture)
    assert "pair" in observed, "runner did not report a resource trap"
    pair = observed["pair"]
    # S25: the coredump globals must agree with the runner-observed trap pair.
    def verify_globals(snapshot):
        for kind, value in zip(("code", "site"), pair):
            assert f"(global (;{trap_exports[kind]};) (mut i32) i32.const {value})" in snapshot, kind

    verify_globals(dump)

    def same_trap(rc, out, err):
        match = re.search(r"resource-trap code=(\d+) site=(\d+)", err)
        return rc > 0 and out == "Number(2584)" and match and (match.group(1), match.group(2)) == pair

    # Standalone engine CLIs report a native Wasm trap. The product runner
    # reads the live wasmoon instance, and Wasmtime exposes its globals in a dump.
    runtime.run("F2-limited-wasmoon-repeat", runtime.invoke("wasmoon", bounded), unreachable)
    runtime.run("F2-limited-product-runner-site-repeat", [runner, bounded, *WASI_FLAGS], same_trap)
    repeat_core = runtime.OUT / "F2-limited-repeat.core.wasm"
    runtime.run("F2-limited-wasmtime-site-repeat", [*wasmtime[:-1], "-D", f"coredump={repeat_core}", bounded],
                unreachable)
    verify_globals(stack.print_wasm("F2-limited-wasmtime-repeat-core", repeat_core))
    for label in ("wasmoon", "wasmtime", "product-runner"):
        assert (runtime.OUT / f"F2-limited-{label}.stdout").read_bytes() == b"Number(2584)\n"


def assert_no_simd(name, source):
    """S25: production-v1 refuses SIMD; the frozen corpus must contain none."""
    wat = stack.print_wasm(f"{name}-simd-audit", source)
    hits = re.findall(r"v128\.|i8x16\.|i16x8\.|i32x4\.|i64x2\.", wat)
    assert not hits, f"{name} contains SIMD instructions: {hits[:4]}"


def compile_probe(name, wat):
    source = stack.compile_wat(f"{name}-named", wat)
    original = runtime.OUT / f"{name}.wasm"
    # The pinned wasmoon CLI resolves named functions differently in its JIT.
    # Strip test-copy custom sections so both engines use the export binding.
    runtime.run(f"strip-{name}", ["wasm-tools", "strip", "--all", source, "-o", original], runtime.ok)
    runtime.run(f"validate-{name}", ["wasm-tools", "validate", original], runtime.ok)
    return runtime.artifact(name, original)


def test_categories(modules, products):
    excluded = [
        ("nan-category", "numeric", '(assert_return (invoke "nan") (f64.const nan:arithmetic))'),
        ("native-divide-zero", "numeric", trap("divide", "integer divide by zero", 7, 0)),
        ("native-arithmetic-overflow", "numeric", trap("divide", "integer overflow", -2147483648, -1)),
        ("native-indirect-type", "control", trap("indirect", "indirect call type mismatch", 1, 2)),
        ("native-indirect-null", "control", trap("indirect", "uninitialized element", 1, 3)),
        ("native-data-drop-bounds", "memory", "\n".join((
            call("drop_data"), trap("init", "out of bounds memory access", 0, 0, 1),
            i32("word", 0x64636261, 0)))),
    ]
    for name, fixture, check in excluded:
        stack.run(f"{name}-original", modules[fixture], check)
        diagnostic = () if name == "nan-category" else (
            get("__moonwasm_trap_code", 0), get("__moonwasm_trap_site", 0))
        stack.run(f"{name}-product", products[fixture], check, *diagnostic)
    source = stack.compile_wat("initialization-oob-source",
                               '(module (memory 1) (data (i32.const 65536) "x"))')
    product, _ = instrument("initialization-oob", source)
    for label, module in (("original", source), ("product", product)):
        stack.wast(f"initialization-oob-{label}",
                   f'(assert_trap {stack.wast_module(module)} "out of bounds memory access")', 1)


def reproducibility(source):
    results = [instrument(f"repro-v1-{number}", source) for number in range(1, 4)]
    outputs, manifests = zip(*results)
    assert len({runtime.sha256(path) for path in outputs}) == 1
    assert manifests[0] == manifests[1] == manifests[2]
    assert len({runtime.sha256(path.with_suffix(".json")) for path in outputs}) == 1
    model = CODEGEN if CODEGEN == "fuel-v2" else ("fuel-v1.2" if CODEGEN in JOIN_LAYOUTS else "fuel-v1")
    assert manifests[0]["instrumentation"]["fuel_model"] == model
    instrument("repro-unknown-model", source, extra=("--cost-model", "fuel-v99"),
               error="unknown --cost-model")
    if CODEGEN in JOIN_LAYOUTS:
        locked = next((source, units, depth) for name, source, _, units, depth
                      in stack.frozen_workloads() if name == "json_parse")
        app, units, depth = locked
        runs = [instrument(f"repro-f1-{number}", app, units=units, depth=depth,
                           memory=64, table=64, allowed=(FD_WRITE,)) for number in range(1, 4)]
        paths, reports = zip(*runs)
        assert len({runtime.sha256(p) for p in paths}) == 1
        assert len({runtime.sha256(p.with_suffix(".json")) for p in paths}) == 1
        assert reports[0]["instrumentation"]["fuel_model"] == "fuel-v1.2"
        for version in ("fuel-v1", "fuel-v1.2"):
            other = "p0" if version == "fuel-v1.2" else CODEGEN
            target = runtime.OUT / f"repro-f1-mismatch-{version}.wasm"
            runtime.run(f"reject-f1-model-{version}", cli(app, "-o", target, "--fuel", MAX,
                        "--codegen", other, "--cost-model", version, "--max-memory-pages", 64,
                        "--max-table-elements", 64, "--max-stack-units", units,
                        "--max-call-depth", depth, "--allow-import", FD_WRITE),
                        lambda rc, out, err: rc == 2 and "does not match" in out + err)
            assert not target.exists()
        old_wasm = runtime.OUT / "repro-f1-fuel-v1.wasm"
        old_manifest = old_wasm.with_suffix(".json")
        runtime.run("repro-f1-fuel-v1", cli(app, "-o", old_wasm, "--report", old_manifest,
                    "--fuel", MAX, "--cost-model", "fuel-v1", "--codegen", "p0",
                    "--max-memory-pages", 64, "--max-table-elements", 64,
                    "--max-stack-units", units, "--max-call-depth", depth, "--allow-import", FD_WRITE),
                    runtime.ok)
        runtime.run("verify-repro-f1-fuel-v1", cli("verify", old_wasm, "--report", old_manifest), runtime.ok)
        runtime.run("validate-repro-f1-fuel-v1", ["wasm-tools", "validate", old_wasm], runtime.ok)
        old = json.loads(old_manifest.read_bytes())
        assert old["instrumentation"]["fuel_model"] == "fuel-v1"
        assert old["input_sha256"] == reports[0]["input_sha256"]
        assert runtime.sha256(old_wasm) != runtime.sha256(paths[0])


def allocation_failure(runner):
    original = stack.compile_wat("allocation-source",
                                 '(module (memory 1 1) (func (export "_start")))')
    product, _ = instrument("allocation-product", original, memory=1)
    # Disable the compiler thread pool so host address pressure reaches the
    # engine's memory reservation at instantiation, rather than worker setup.
    wasmtime = ["wasmtime", "run", "-C", "parallel-compilation=n",
                "-W", "max-wasm-stack=524288"]
    limit = ["prlimit", "--as=1073741824", "--"]
    for label, module in (("original", original), ("product", product)):
        runtime.run(f"allocation-{label}-wasmtime-room", [*wasmtime, module],
                    lambda rc, out, err: rc == 0 and not (out or err))
        runtime.run(f"allocation-{label}-wasmtime-limited", [*limit, *wasmtime, module],
                    lambda rc, out, err: rc == 1 and not out and "failed to instantiate" in err
                    and "Cannot allocate memory" in err)
    runtime.run("allocation-runner-room", [runner, product],
                lambda rc, out, err: rc == 0 and not (out or err))
    runtime.run("allocation-runner-limited", [*limit, runner, product],
                lambda rc, out, err: rc == 1 and not out
                and err == "run: initialization-failure diagnostic-unavailable: out of memory")


def boundaries():
    source = stack.compile_wat("cost-three-source", """
        (module (func (export "answer") (result i32) i32.const 39 i32.const 3 i32.add))""")
    answer = i32("answer", 42)
    stack.run("cost-three-original", source, answer)
    for label, fuel in (("below", 2), ("exact", 3), ("above", 4), ("i64-max", MAX)):
        product, _ = instrument(f"cost-three-{label}", source, fuel=fuel)
        check = stack.trap_check(stack.invoke("answer"), 1, 2 if CODEGEN == "fuel-v2" else 4) if fuel == 2 else answer
        stack.run(f"cost-three-{label}", product, check)
    for label, fuel in (("zero", 0), ("i64-overflow", MAX + 1)):
        instrument(f"cost-{label}", source, fuel=fuel, error="--fuel")

    if CODEGEN == "fuel-v2":
        for name, limits in (("stack-units", {"units": 1 << 31}),
                             ("call-depth", {"depth": 1 << 31})):
            instrument(f"over-31-bit-{name}", source, **limits, error="1..=2147483647")
        instrument("unknown-cost-model", source, extra=("--cost-model", "fuel-v99"),
                   error="unknown --cost-model")
        instrument("unknown-codegen", source, extra=("--codegen", "fuel-v99"),
                   error="unknown --codegen")

    for name, data, error in (
        ("truncated-section", HEADER + b"\x01\x02\x01", "truncated"),
        ("unknown-opcode", code_body(b"\x00\xff\x0b"), "opcode 255"),
        ("module-size-over-limit", HEADER + bytes(4194305 - len(HEADER)), "module bytes 4194305"),
        ("nesting-over-limit", code_body(b"\x00" + b"\x02\x40" * 257 + b"\x0b" * 258),
         "structured nesting 257"),
    ):
        path = runtime.OUT / f"{name}-source.wasm"
        path.write_bytes(data)
        runtime.artifact(f"{name}-source", path)
        instrument(name, path, error=error)
    for name, wat, error, allowed in (
        ("non-allowlisted-simd", "(module (func v128.const i32x4 0 0 0 0 drop))",
         "outside production-v1 allowlist", ()),
        ("relaxed-simd", "(module (func (param v128 v128) local.get 0 local.get 1 i8x16.relaxed_swizzle drop))",
         "relaxed SIMD", ()),
        ("exported-call-table", '(module (table (export "t") 1 1 funcref))', "exported table", ()),
        ("mutate-call-table", "(module (table 1 1 funcref) (func i32.const 0 i32.const 0 i32.const 0 table.copy))",
         "requires an internal externref table", ()),
        ("escaping-funcref", "(module (func) (elem declare func 0) (func ref.func 0 drop))", "opcode 210", ()),
        ("import-memory-denied", '(module (import "host" "memory" (memory 1)))', "imported memory", ("host.memory",)),
        ("import-table-denied", '(module (import "host" "table" (table 1 externref)))', "imported table", ("host.table",)),
        ("import-f64-global-denied", '(module (import "host" "float" (global f64)))',
         "globals require i32 or i64", ("host.float",)),
        ("import-wrong-pair", '(module (import "spectest" "print" (func)))',
         "import not allowed", ("other.print",)),
        ("import-ambiguous-pair", '(module (import "host.mod" "run" (func)))',
         "ambiguous allow-import", ("host.mod.run",)),
    ):
        path = stack.compile_wat(f"{name}-source", wat)
        instrument(name, path, error=error, allowed=allowed)
    stub = stack.compile_wat("exact-import-source", """
        (module (import "spectest" "global_i32" (global $g i32))
                (import "spectest" "print_i32" (func $print (param i32)))
                (func (export "read") (result i32)
                  global.get $g call $print global.get $g))""")
    product, _ = instrument("exact-import", stub, allowed=("spectest.global_i32", "spectest.print_i32"))
    stack.run("exact-import-original", stub, i32("read", 666))
    stack.run("exact-import-product", product, i32("read", 666))

    product, _ = instrument("first-instrumentation", source)
    instrument("duplicate-instrumentation", product, error="already instrumented")
    marker = b"fuelguard.instrumented"
    unknown = runtime.OUT / "unknown-marker-source.wasm"
    unknown.write_bytes(source.read_bytes() + section(0, bytes([len(marker)]) + marker + b"v99"))
    instrument("unknown-artifact-marker", unknown, error="unknown FuelGuard marker")


def growth_boundaries():
    for label, fixture, export, size, code, site in (
        ("memory", "memory", "grow", "pages", 2, 34),
        ("table", "extern", "grow_null", "size", 3, 6),
    ):
        original = compile_source(f"boundary-{label}-source", SOURCE / f"{fixture}.wat")
        caps = {label: 0}
        resource_name = "memory pages" if label == "memory" else "table elements"
        instrument(f"initial-{label}-over-cap", original, **caps, error=f"initial {resource_name}")
        product, _ = instrument(f"{label}-growth-cap", original, memory=2, table=2)
        for variant, module in (("original", original), ("product", product)):
            stack.run(f"{label}-growth-exact-demo-{variant}", module,
                      i32(export, 1, 0), i32(export, 1, 1), i32(size, 2))
        for delta, name in ((2, "over-one"), (-1, "unsigned-max")):
            stack.run(f"{label}-growth-{name}-original", original,
                      i32(export, -1, delta), i32(size, 1))
            stack.run(f"{label}-growth-{name}-product", product,
                      stack.trap_check(stack.invoke(export, delta), code, site))


def repeat(name, product, *checks):
    unit = "\n".join((stack.wast_module(product), *checks))
    stack.wast(name, "\n".join([unit] * 20), 20 * sum(check.count("(assert_") for check in checks))


def nested_loop_budget():
    original = stack.compile_wat("nested-budget-source", """(module
      (global $ticks (export "ticks") (mut i32) (i32.const 0))
      (func (export "nested") (result i32) (local $outer i32) (local $inner i32)
        i32.const 2 local.set $outer
        loop $rows
          i32.const 3 local.set $inner
          loop $columns
            global.get $ticks i32.const 1 i32.add global.set $ticks
            local.get $inner i32.const 1 i32.sub local.tee $inner br_if $columns
          end
          local.get $outer i32.const 1 i32.sub local.tee $outer br_if $rows
        end
        global.get $ticks))""")
    checks = (i32("nested", 6), get("ticks", 6))
    repeat("nested-budget-original", original, *checks)
    # Setup 3, two rows at 3 + 3 * 10 + 5 each, then a final global.get.
    short, _ = instrument("nested-budget-short", original, fuel=79)
    repeat("nested-budget-short", short, stack.trap_check(stack.invoke("nested"), 1, 22), get("ticks", 6))
    exact, _ = instrument("nested-budget-exact", original, fuel=80)
    repeat("nested-budget-exact", exact, *checks)


def demo():
    target = runtime.OUT / "demo-build"
    # cwd cannot be passed through the shared logger. Use positional shell args.
    runtime.run("build-moonbit-demo", ["bash", "-c",
                'cd "$1" && exec moon build --target wasm --release --target-dir "$2"',
                "build", ROOT / "fixtures/demo", target], runtime.ok, timeout=180)
    module = runtime.artifact("moonbit-demo", target / "wasm/release/build/demo/demo.wasm")
    runtime.run("validate-moonbit-demo", ["wasm-tools", "validate", module], runtime.ok)
    short = i32("short_loop", 190, 20)
    long = i32("long_loop", 2494, 20)
    recurse = i32("recurse", 32, 32)
    stack.run("demo-original-finite", module, short, long, recurse)

    moderate, _ = instrument("demo-moderate-fuel", module, fuel=450, depth=64)
    repeat("demo-short-same-iterations", moderate, short)
    long_site = 33 if CODEGEN == "fuel-v2" else 52
    repeat("demo-long-same-iterations", moderate, stack.trap_check(stack.invoke("long_loop", 20), 1, long_site))
    high, _ = instrument("demo-higher-fuel", module, fuel=1000, depth=64)
    repeat("demo-long-with-higher-budget", high, long)
    for fuel in (15, 450, 1000):
        product, _ = instrument(f"demo-forever-{fuel}", module, fuel=fuel)
        repeat(f"demo-forever-{fuel}", product, stack.trap_check(stack.invoke("forever"), 1, 20))

    exact, _ = instrument("demo-depth-cap", module, depth=33)
    stack.run("demo-depth-exact", exact, recurse)
    stack.run("demo-depth-over-one-original", module, i32("recurse", 1, 33))
    stack.run("demo-depth-over-one", exact, stack.trap_check(stack.invoke("recurse", 33), 5, 11))

    # Keep all vector locals live across a single original call.
    # S25: SIMD valtypes are refused; keep the same stack-unit pressure with i64.
    count = 512
    locals_ = "i64 " * count
    loads = "\n".join(f"i32.const {8 * i} i64.load local.set {i}" for i in range(count))
    stores = "\n".join(f"i32.const {8 * i} local.get {i} i64.store" for i in range(count))
    frame = stack.compile_wat("wide-shallow-source", f"""(module (memory 1)
      (func $leaf (result i32) i32.const 42)
      (func (export "wide") (result i32) (local {locals_})
        {loads} call $leaf {stores}))""")
    stack.run("wide-shallow-original", frame, i32("wide", 42))
    # stack-v1 reservations: wide C=646 and leaf C=132 (S25 i64 conversion).
    accepted, _ = instrument("wide-shallow-room", frame, units=778, depth=2,
                             extra=("--stack-layout",))
    layout = (runtime.OUT / "instrument-wide-shallow-room.stdout").read_text()
    rows = re.findall(r"stack function=(\d+).*? C=(\d+)", layout)
    expected_rows = [("0", "132"), ("1", "646")]
    if CODEGEN in ("fuel-v2", "p1", "p2", *JOIN_LAYOUTS):
        expected_rows.append(("2", "64"))
    if CODEGEN in ("join-span-compact", "join-span-compact-v2"):
        expected_rows.append(("3", "64"))
    expected_rows.append((str(len(expected_rows)), "98"))
    if CODEGEN == "fuel-v2":
        expected_rows.append((str(len(expected_rows)), "64"))
    assert rows == expected_rows, rows
    stack.run("wide-shallow-room", accepted, i32("wide", 42))
    rejected, _ = instrument("wide-shallow-limit", frame, units=646, depth=2)
    stack.run("wide-shallow-limit", rejected, stack.trap_check(stack.invoke("wide"), 4, 1539))
    entry, _ = instrument("wide-shallow-entry-limit", frame, units=645, depth=2)
    stack.run("wide-shallow-entry-limit", entry, stack.trap_check(stack.invoke("wide"), 4, 2))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--group", choices=("strict", "workloads", "boundaries", "demo"))
    global CODEGEN
    parser.add_argument("--codegen", choices=LAYOUTS, default="fuel-v2")
    options = parser.parse_args()
    group, CODEGEN = options.group, options.codegen
    if platform.system() != "Linux" or platform.machine() != "x86_64":
        parser.error("use x86_64 Linux or WSL2")
    if not __debug__:
        parser.error("run Python without -O so assertions execute")
    resource.setrlimit(resource.RLIMIT_STACK, (8388608, resource.getrlimit(resource.RLIMIT_STACK)[1]))
    base = runtime.acceptance_directory() or ROOT / "_build/s16"
    base.mkdir(parents=True, exist_ok=True)
    runtime.OUT = stack.OUT = (base if runtime.acceptance_directory()
                               else Path(tempfile.mkdtemp(prefix="run-", dir=base)))
    print(f"Evidence directory: {runtime.OUT}", flush=True)
    print(platform.platform(), platform.libc_ver(), "RLIMIT_STACK", resource.getrlimit(resource.RLIMIT_STACK))
    for tool, version in runtime.VERSIONS.items():
        runtime.run(f"version-{tool}", [tool, "--version"], lambda rc, out, err:
                    rc == 0 and re.search(rf"(?<![\d.]){re.escape(version)}(?![\d.])", out + err))
    runtime.run("version-moon", ["moon", "version"], runtime.ok)
    stack.build_instrument("build-instrument")
    stack.CODEGEN = CODEGEN
    if group in (None, "strict"):
        modules = {name: compile_source(f"{name}-source", SOURCE / f"{name}.wat")
                   for name in ("control", "memory", "extern", "numeric")}
        products = strict_cases(modules)
        test_categories(modules, products)
        reproducibility(modules["control"])
    if group in (None, "workloads"):
        runner = build_runner()
        workloads(runner)
        allocation_failure(runner)
    if group in (None, "boundaries"):
        boundaries()
    if group in (None, "boundaries", "demo"):
        growth_boundaries()
    if group in (None, "demo"):
        nested_loop_budget()
        demo()
    print("S16 selected corpus checks passed", flush=True)


if __name__ == "__main__":
    main()

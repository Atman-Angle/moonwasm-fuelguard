"""S13 CLI and same-instance tests for the embedded Linux wasmoon runner."""
import argparse
import json
import platform
import resource
import select
import shutil
import signal
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from integration.generated.check import FUEL_V2_MARKER
from integration.policy.check import HEADER, section
from integration.stack_pass import check as stack

runtime = stack.runtime
BASE = runtime.ROOT / "_build/s13"
OUT = runtime.acceptance_directory() or BASE
MARKER_NAME = b"fuelguard.instrumented"
MARKER = (b"production-v1|fuel-v1|diagnostics-v1|metering=per-instruction"
          b"|growth=growth-v1|stack=stack-v2")
TRUST_REQUIREMENT = "Use only trusted artifacts from the built-in production-v1 pipeline."
FD_WRITE = "wasi_snapshot_preview1.fd_write"
WASI_WRITE = ("--wasi", "--allow-import", FD_WRITE, "--wasi-stdout")


def instrument(name, source, fuel=stack.MAX, units=100000, depth=128, flags=()):
    return stack.instrument(name, source, units, depth, fuel, flags)


def protected(name, wat, **limits):
    source = stack.compile_wat(f"{name}-source", wat)
    return instrument(name, source, **limits)[0]


def run(name, module, options=(), *, exit_code=0, output="", diagnostic="", prefix=()):
    return runtime.run(name, [*prefix, RUNNER, module, *options],
                       lambda code, out, err: code == exit_code and out == output
                       and (diagnostic in err if diagnostic else err == "")
                       and ("resource-trap" in diagnostic or "resource-trap" not in err))


def resource_traps():
    call = ("--invoke", "go")
    fuel = protected("fuel", '(module (func (export "go") (result i32) i32.const 20 i32.const 22 i32.add))',
                     fuel=2)
    site = 2 if stack.CODEGEN == "fuel-v2" else 4
    run("fuel-trap", fuel, call, exit_code=1, diagnostic=f"resource-trap code=1 site={site}")
    memory = protected("memory", '(module (memory 1 1) (func (export "go") (param i32) '
                       '(result i32) local.get 0 memory.grow))',
                       flags=("--max-memory-pages", 1))
    run("memory-trap", memory, (*call, "--arg", 1), exit_code=1,
        diagnostic="resource-trap code=2 site=3")
    native_limit = protected("memory-original-failure",
                             '(module (memory 1 1) (func (export "go") (result i32) i32.const 1 memory.grow))',
                             flags=("--max-memory-pages", 2))
    run("native-grow-failure", native_limit, call, output="-1")
    run("host-allocation-failure", native_limit, call, exit_code=1,
        diagnostic="initialization-failure diagnostic-unavailable: out of memory",
        prefix=("prlimit", "--as=1073741824"))
    table = protected("table", '(module (table 1 1 externref) (func (export "go") (param i32) '
                      '(result i32) ref.null extern local.get 0 table.grow))',
                      flags=("--max-table-elements", 1))
    run("table-trap", table, (*call, "--arg", -1), exit_code=1,
        diagnostic="resource-trap code=3 site=4")
    run("table-zero", table, (*call, "--arg", 0), output="1")

    source = stack.compile_wat("stack-depth-source", """(module
      (func $leaf (result i64) i64.const 9)
      (func (export "go") (result i64) call $leaf))""")
    exact, costs = instrument("stack-depth-audit", source)
    run("call-ok", exact, call, output="9")
    threshold = costs[0] + costs[1]
    for name, units, depth, code in (("stack", threshold - 1, 1, 4), ("depth", threshold, 1, 5)):
        module, _ = instrument(name, source, units=units, depth=depth)
        run(f"{name}-trap", module, call, exit_code=1,
            diagnostic=f"resource-trap code={code} site=3")


def first_entry_budget():
    source = stack.compile_wat("runner-first-entry-source", """(module
      (func $boot i32.const 1 if nop end)
      (start $boot)
      (func (export "go") (result i32) i32.const 1 if nop end i32.const 42))""")
    for name, fuel in (("first-entry-exact", 7), ("first-entry-low", 6)):
        product, _ = instrument(name, source, fuel=fuel, units=100000, depth=128)
        if fuel == 7:
            run(name, product, ("--invoke", "go"), output="42")
        else:
            run(name, product, ("--invoke", "go"), exit_code=1,
                diagnostic="resource-trap code=1 site=9")


def diagnostic_fixture(code, site, marker=None):
    # A test producer deliberately constructs diagnostic states that the
    # real instrumenter cannot emit. Diagnostic globals begin at zero.
    name = f"diagnostic-{code}-{site}"
    if marker is None:
        marker = FUEL_V2_MARKER if stack.CODEGEN == "fuel-v2" else MARKER
    raw = stack.compile_wat(name + "-raw", f"""(module
      (global (mut i64) (i64.const 5000))
      (global $code (export "__moonwasm_trap_code") (mut i32) (i32.const 0))
      (global $site (export "__moonwasm_trap_site") (mut i32) (i32.const 0))
      (global (mut i64) (i64.const 10000))
      (global (mut i64) (i64.const 2))
      (func (export "_start") i32.const {code} global.set $code
        i32.const {site} global.set $site unreachable))""")
    output = OUT / f"{name}.wasm"
    output.write_bytes(raw.read_bytes() + section(0, bytes([len(MARKER_NAME)]) + MARKER_NAME + marker))
    runtime.run(f"validate-{name}", ["wasm-tools", "validate", output], runtime.ok)
    return runtime.artifact(name, output)


def native_failures():
    trap = protected("native", '(module (func (export "_start") i32.const 1 i32.const 0 i32.div_s drop))')
    run("native-trap", trap, exit_code=1, diagnostic="native-trap code=0")
    fixed = protected("fixed-table", """(module
      (type $sig (func (result i32)))
      (table 2 2 funcref)
      (elem (i32.const 0) funcref (ref.func $leaf) (ref.null func))
      (func $leaf (type $sig) i32.const 42)
      (func (export "via_table") (param i32) (result i32)
        local.get 0 call_indirect (type $sig)))""", flags=("--max-table-elements", 2))
    run("fixed-table-call", fixed, ("--invoke", "via_table", "--arg", 0), output="42")
    run("fixed-table-null", fixed, ("--invoke", "via_table", "--arg", 1), exit_code=1,
        diagnostic="native-trap code=0")
    start_source = stack.compile_wat("initializing-source", """(module
      (func $start nop) (start $start) (func (export "_start") nop))""")
    start, _ = instrument("initializing", start_source, units=1)
    run("core-start-trap", start, exit_code=1,
        diagnostic="initialization-failure diagnostic-unavailable")
    bad_data = protected("invalid-data", '(module (memory 1) (data (i32.const 65536) "x") '
                         '(func (export "_start")))', flags=("--max-memory-pages", 1))
    run("initialization-data", bad_data, exit_code=1,
        diagnostic="initialization-failure diagnostic-unavailable")
    unknown = diagnostic_fixture(7, 1)
    run("unknown-diagnostic", unknown, exit_code=1, diagnostic="diagnostic-error: unknown code=7 site=1")
    mismatched = diagnostic_fixture(3, 0)
    run("inconsistent-diagnostic", mismatched, exit_code=1,
        diagnostic="diagnostic-error: inconsistent code=3 site=0")


def wasi_and_values():
    scalar = protected("scalar", """(module
      (global $state (mut i32) (i32.const 0))
      (func $boot i32.const 42 global.set $state) (start $boot)
      (func (export "read") (param i32 i64 f32 f64) (result i32 i64 f32 f64)
        local.get 0 global.get $state i32.add local.get 1 local.get 2 local.get 3)
      (func (export "nan") (result f64) f64.const nan)
      (func (export "_start") (result i32) global.get $state))""")
    run("default-start", scalar, output="42")
    run("named-values", scalar, ("--invoke", "read", "--arg", 5, "--arg", -9,
                               "--arg", "1.25", "--arg", "2.5"), output="47 -9 1.25 2.5")
    runtime.run("nan", [RUNNER, scalar, "--invoke", "nan"],
                lambda code, out, err: code == 0 and out.lower() == "nan" and not err)
    run("missing-export", scalar, ("--invoke", "absent"), exit_code=2, diagnostic="export not found")
    run("wrong-arity", scalar, ("--invoke", "read"), exit_code=2, diagnostic="expects 4 arguments")
    run("invalid-timeout", scalar, ("--timeout-ms", 0), exit_code=2, diagnostic="positive")
    run("rejected-host-stack", scalar, exit_code=2, diagnostic="stack soft limit",
        prefix=("prlimit", "--stack=4194304:4194304"))

    for status in (0, 7):
        module = protected(f"wasi-exit-{status}", f"""(module
          (import "wasi_snapshot_preview1" "proc_exit" (func $exit (param i32)))
          (func (export "_start") i32.const {status} call $exit unreachable))""",
                           flags=("--allow-import", "wasi_snapshot_preview1.proc_exit"))
        run(f"wasi-exit-{status}", module, ("--wasi", "--allow-import", "wasi_snapshot_preview1.proc_exit"),
            exit_code=int(status != 0), diagnostic="wasi-exit status=7" if status else "")
    for name, source, expected, units, depth in stack.frozen_workloads():
        if name not in ("hello", "json_parse", "sha256_hash"):
            continue
        flags = ("--allow-import", FD_WRITE, "--max-memory-pages", 64, "--max-table-elements", 64)
        product, _ = instrument(name, source, units=units, depth=depth, flags=flags)
        run(f"workload-{name}", product, WASI_WRITE, output=expected)
        if name == "hello":
            run("wasi-disabled", product, ("--allow-import", FD_WRITE), exit_code=2,
                diagnostic="WASI import requires --wasi")
            run("import-denied", product, ("--wasi",), exit_code=2, diagnostic="import is not allowed")
            run("stdio-disabled", product, ("--wasi", "--allow-import", FD_WRITE))
    wrong_type = protected("wrong-host-type",
                           '(module (import "wasi_snapshot_preview1" "fd_write" (func)) '
                           '(func (export "_start")))', flags=("--allow-import", FD_WRITE))
    run("wrong-import-type", wrong_type, WASI_WRITE, exit_code=2, diagnostic="linking imports")
    for capability, expected in (("env.service", "unsupported runner import"),
                                 ("wasi_snapshot_preview1.path_open", "unsupported WASI capability")):
        namespace, field = capability.split(".")
        blocked = protected(field, f'(module (import "{namespace}" "{field}" (func)) '
                            '(func (export "_start")))', flags=("--allow-import", capability))
        run(f"blocked-{field}", blocked, ("--wasi", "--allow-import", capability),
            exit_code=2, diagnostic=expected)
    args_import = "wasi_snapshot_preview1.args_sizes_get"
    wasi_args = protected("wasi-args", """(module
      (import "wasi_snapshot_preview1" "args_sizes_get" (func $sizes (param i32 i32) (result i32)))
      (memory 1)
      (func (export "_start") (result i32)
        i32.const 0 i32.const 4 call $sizes drop i32.const 0 i32.load))""",
                          flags=("--max-memory-pages", 1, "--allow-import", args_import))
    run("wasi-explicit-args", wasi_args, ("--wasi", "--allow-import", args_import, "--wasi-arg", "one"),
        output="2")
    return scalar


def stack_profile_and_marker(scalar):
    source = stack.compile_wat("profile-source", '(module (func (export "_start") nop))')
    for name, units, depth in (("outside-units", 100001, 128), ("outside-depth", 100000, 129)):
        output, _ = instrument(name, source, units=units, depth=depth)
        run(name, output, exit_code=2, diagnostic="budget outside the Linux wasmoon profile")
    run("raw-module", source, exit_code=2,
        diagnostic=f"missing FuelGuard production-v1 marker. {TRUST_REQUIREMENT}")
    different_name = b"\xef\xbb\xbf" + MARKER_NAME
    disguised = OUT / "different-marker-name.wasm"
    disguised.write_bytes(source.read_bytes() + section(0, bytes([len(different_name)])
                           + different_name + MARKER))
    run("different-marker-name", disguised, exit_code=2, diagnostic="missing FuelGuard production-v1 marker")
    unknown = diagnostic_fixture(7, 2, MARKER.replace(b"diagnostics-v1", b"diagnostics-v99"))
    run("unknown-abi", unknown, exit_code=2, diagnostic="unsupported FuelGuard profile/model/ABI")
    older = OUT / "compat.wasm"
    older.unlink(missing_ok=True)
    runtime.run("instrument-compat", ["moonrun", stack.TOOL, source, "-o", older, "--fuel", 100,
                "--profile", "fuel-growth-v1"], runtime.ok)
    run("compat-marker", older, exit_code=2, diagnostic="unsupported FuelGuard profile/model/ABI")
    duplicate = OUT / "duplicate-marker.wasm"
    marker = FUEL_V2_MARKER if stack.CODEGEN == "fuel-v2" else MARKER
    duplicate.write_bytes(scalar.read_bytes() + section(0, bytes([len(MARKER_NAME)]) + MARKER_NAME + marker))
    run("duplicate-marker", duplicate, exit_code=2, diagnostic="duplicate")
    malformed = OUT / "truncated.wasm"
    malformed.write_bytes(HEADER + b"\x01\x02\x01")
    run("malformed", malformed, exit_code=2, diagnostic="truncated")

    # S25: SIMD valtypes are refused; keep identical stack-unit pressure with i64.
    slots = 1024
    local_types = " ".join(["i64"] * slots)
    loads = "\n".join(f"i32.const {8 * i} i64.load local.set {i + 1}" for i in range(slots))
    stores = "\n".join(f"i32.const {8 * i} local.get {i + 1} i64.store" for i in range(slots))
    stress_source = stack.compile_wat("wide-frame-source", f"""(module (memory 1 1)
      (func $step (export "step") (param i32) (result i32) (local {local_types})
        local.get 0 i32.eqz if i32.const 1 return end
        {loads}
        local.get 0 i32.const 1 i32.sub call $step
        {stores}))""")
    pressure, costs = instrument("wide-frame", stress_source, flags=("--max-memory-pages", 1))
    step = ("--invoke", "step", "--arg")
    accepted_depth = 100000 // costs[0]
    assert accepted_depth == 86
    run("wide-frame-success", pressure, (*step, accepted_depth - 1), output="1")
    run("wide-frame-controlled", pressure, (*step, 4096), exit_code=1,
        diagnostic="resource-trap code=4")
    depth = protected("depth-boundary", """(module
      (func $step (export "step") (param i32) (result i32)
        local.get 0 i32.eqz if i32.const 1 return end
        local.get 0 i32.const 1 i32.sub call $step))""")
    run("depth-limit-success", depth, (*step, 127), output="1")
    run("depth-limit-controlled", depth, (*step, 128), exit_code=1,
        diagnostic="resource-trap code=5")


def execution_control():
    source = protected("long-run", """(module
      (import "wasi_snapshot_preview1" "fd_write" (func $write (param i32 i32 i32 i32) (result i32)))
      (memory 1 1)
      (data (i32.const 0) "\\08\\00\\00\\00\\06\\00\\00\\00ready\\0a")
      (func (export "_start")
        i32.const 1 i32.const 0 i32.const 1 i32.const 16 call $write drop
        loop br 0 end))""",
                       flags=("--max-memory-pages", 1, "--allow-import", FD_WRITE))
    run("timeout", source, (*WASI_WRITE, "--timeout-ms", 20), exit_code=1, output="ready",
        diagnostic="timeout phase=invoke")
    start = protected("long-core-start", '(module (func $s loop br 0 end) (start $s) '
                      '(func (export "_start") nop))')
    run("timeout-core-start", start, ("--timeout-ms", 20), exit_code=1,
        diagnostic="timeout phase=start")
    command = [str(RUNNER), str(source), *WASI_WRITE]
    with subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE) as process:
        try:
            assert select.select([process.stdout], [], [], 10)[0], "guest did not start"
            assert process.stdout.readline() == b"ready\n", "guest startup prefix"
            process.send_signal(signal.SIGINT)
            rest, err = process.communicate(timeout=10)
        finally:
            if process.poll() is None:
                process.kill()
        assert process.returncode == 1 and b"cancelled phase=invoke" in err, err
        assert b"resource-trap" not in err
        (OUT / "cancel.stdout").write_bytes(b"ready\n" + rest)
        (OUT / "cancel.stderr").write_bytes(err)
        print(json.dumps({"case": "cancel", "command": command, "signal": "SIGINT",
                          "exit": process.returncode, "stdout_sha256": runtime.sha256(OUT / "cancel.stdout"),
                          "stderr_sha256": runtime.sha256(OUT / "cancel.stderr")}), flush=True)


def main():
    global RUNNER
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--codegen", choices=("p0", "p1", "p2", "p2-prefix", *stack.JOIN_LAYOUTS,
                                             "fuel-v2"), default="fuel-v2")
    stack.CODEGEN = parser.parse_args().codegen
    assert platform.system() == "Linux" and platform.machine() == "x86_64"
    OUT.mkdir(parents=True, exist_ok=True)
    runtime.OUT = stack.OUT = OUT
    print(platform.platform(), platform.libc_ver(), "RLIMIT_STACK", resource.getrlimit(resource.RLIMIT_STACK))
    runtime.run("version-moon", ["moon", "version"], runtime.ok)
    runtime.run("version-validator", ["wasm-tools", "--version"],
                lambda code, out, err: code == 0 and "1.263.0" in out)
    runtime.run("instrument-dependencies", ["moon", "tree"],
                lambda code, out, err: code == 0 and "Milky2018" not in out and "fuelguard-codec@0.1.0" in out)
    runtime.run("runner-dependencies", ["bash", "-c", 'cd cmd/run && exec moon tree'],
                lambda code, out, err: code == 0 and "Milky2018/wasmoon@0.18.0" in out)
    stack.build_instrument("build-instrument")
    target = BASE / "native"
    runtime.run("build-runner", ["bash", "-c", 'cd cmd/run && exec moon build --target native --release . '
                '--target-dir "$1"', "build", target], runtime.ok, timeout=600)
    binaries = [p for p in (target / "native/release/build").rglob("*.exe") if p.is_file()]
    assert len(binaries) == 1, binaries
    binary = binaries[0]
    if runtime.acceptance_directory():
        binary = OUT / binary.name
        shutil.copy2(binaries[0], binary)
    RUNNER = runtime.artifact("fuelguard-run", binary)
    runtime.run("runner-version", [RUNNER, "--version"],
                lambda code, out, err: code == 0 and "wasmoon 0.18.0" in out)
    runtime.run("runner-help-trust", [RUNNER, "--help"],
                lambda code, out, err: code == 0 and err == "" and TRUST_REQUIREMENT in out
                and "The marker identifies the artifact format. The caller verifies provenance." in out)
    resource_traps()
    if stack.CODEGEN in (*stack.JOIN_LAYOUTS, "fuel-v2"):
        first_entry_budget()
    native_failures()
    scalar = wasi_and_values()
    stack_profile_and_marker(scalar)
    execution_control()
    runtime.run("life-tests", ["bash", "-c", 'cd cmd/run && exec moon test --target native --release . '
                '--target-dir "$1"', "test", target],
                lambda code, out, err: code == 0 and "passed: 3" in out, timeout=600)
    print("S13 wasmoon runner checks passed")


if __name__ == "__main__":
    main()

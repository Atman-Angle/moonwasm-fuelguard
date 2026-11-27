"""Run the fixed-shape S03 matrix on the S02 Linux toolchain."""

import platform
import re
import shutil
import sys
from pathlib import Path

from fixture import ENTRY, frame_cost, module

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "runtime"))
import check as runtime


def encode(name, path, depth, shape, budget=None, depth_limit=100000, lifecycle=False):
    wat = runtime.OUT / f"{name}.wat"
    wasm = wat.with_suffix(".wasm")
    wat.write_text(module(path, depth, *shape, budget, depth_limit, lifecycle), encoding="utf-8")
    runtime.run(f"parse-{name}", ["wasm-tools", "parse", wat, "-o", wasm], runtime.ok)
    runtime.run(f"validate-{name}", ["wasm-tools", "validate", wasm], runtime.ok)
    return runtime.artifact(name, wasm)


def normal(depth, shape):
    expected = [str(7 + depth * sum(shape)), "11"]
    return lambda code, out, _err: code == 0 and out.split() == expected


def controlled(marker, start=False):
    def accept(code, out, err):
        return (code > 0 and out == marker and "unreachable" in err.lower()
                and (not start or "instantiat" in err.lower()))
    return accept


def execute(engine, case, wasm, accept, export="check"):
    runtime.run(f"{engine}-{case}", runtime.invoke(engine, wasm, export), accept)


def references(case, wasm, guarded, start):
    wat = runtime.run(f"print-{case}", ["wasm-tools", "print", wasm], runtime.ok)
    entry, element, boot = ("wrap_entry", "wrap_b", "wrap_boot") if guarded else (
        "entry", "b", "boot"
    )
    patterns = [
        rf'\(export "entry" \(func \${entry}\)\)',
        rf'\(elem [^\n]*\(i32.const 0\) func \${element}\)',
        r'\(import "wasi_snapshot_preview1" "fd_write" \(func \$write',
        r'\(func \$a \(;1;\)', r'\(func \$b \(;2;\)',
        r'\(func \$entry \(;3;\)', r'\(func \$boot \(;4;\)',
        r'\(func \$check \(;5;\)', r'\(table \(;0;\) 1 1 funcref\)',
    ]
    if start:
        patterns.append(rf'\(start \${boot}\)')
    if not all(re.search(pattern, wat) for pattern in patterns) or wat.count("(import ") != 1:
        raise RuntimeError(f"{case}: binary reference map differs from plan")


def semantics():
    shape = (32, 24)
    cost = frame_cost(*shape)
    depth = 8
    exact = ENTRY + (depth + 1) * cost
    cases = []
    for path in ("direct", "indirect", "start"):
        for name, budget, expect in (
            ("original", None, normal(depth, shape)),
            ("exact", exact, normal(depth, shape)),
            ("over-one", exact - 1, controlled("stack:4", path == "start")),
        ):
            case = f"{path}-{name}"
            wasm = encode(case, path, depth, shape, budget)
            if name != "over-one":
                references(case, wasm, budget is not None, path == "start")
            cases.append((case, wasm, expect, "check"))
    cases.append(("export-entry-over", encode("export-entry-over", "direct", 0, shape, ENTRY - 1),
                  controlled("stack:4"), "entry"))
    cases.append(("start-entry-over", encode("start-entry-over", "start", 0, shape, ENTRY - 1),
                  controlled("stack:4", True), "check"))
    cases.append(("indirect-wrapper-over", encode("indirect-wrapper-over", "indirect", 1, shape,
                                                  ENTRY + cost),
                  controlled("stack:4"), "check"))
    cases.append(("depth-exact", encode("depth-exact", "direct", depth, shape, exact, depth + 2),
                  normal(depth, shape), "check"))
    cases.append(("depth-over", encode("depth-over", "direct", depth, shape, exact, depth + 1),
                  controlled("depth:5"), "check"))
    cases.append(("both-over", encode("both-over", "direct", depth, shape, exact - 1, depth + 1),
                  controlled("stack:4"), "check"))
    large = (256, 32)
    cost_large = frame_cost(*large)
    cases.append(("shallow-large", encode("shallow-large", "direct", 1, large, ENTRY + 2 * cost_large),
                  normal(1, large), "check"))
    cases.append(("shallow-large-over",
                  encode("shallow-large-over", "direct", 1, large, ENTRY + 2 * cost_large - 1),
                  controlled("stack:4"), "check"))
    for engine in ("wasmoon", "wasmtime"):
        for case, wasm, accept, export in cases:
            execute(engine, case, wasm, accept, export)


class ProbeSession:
    """Test-only host gate. The CLI process owns the instance lifetime."""

    def __init__(self):
        self.active = False
        self.discarded = False

    def invoke(self, operation):
        if self.discarded:
            raise RuntimeError("instance discarded")
        if self.active:
            raise RuntimeError("host reentry rejected")
        self.active = True
        try:
            if operation():
                self.discarded = True
        finally:
            self.active = False


def expect_rejection(operation, reason):
    try:
        operation()
    except RuntimeError as error:
        if str(error) == reason:
            return
        raise
    raise RuntimeError(f"expected host gate rejection: {reason}")


def lifecycle_checks():
    shape = (32, 24)
    depth = 2
    wasm = encode("lifecycle", "direct", depth, shape,
                  ENTRY + (depth + 1) * frame_cost(*shape), lifecycle=True)
    for engine in ("wasmoon", "wasmtime"):
        session = ProbeSession()

        def run_guest():
            # Simulate a host callback requesting reentry while an invocation is active.
            expect_rejection(lambda: session.invoke(None), "host reentry rejected")
            execute(engine, "lifecycle", wasm, controlled("ready:2\nstack:4"))
            return True  # The observed guest trap retires this session.

        session.invoke(run_guest)
        expect_rejection(lambda: session.invoke(None), "instance discarded")
        print(f"lifecycle {engine}: two same-instance calls, trap, reuse and simulated reentry rejected")


def pressure():
    # The reserve/release and wrapper templates remain active even during pressure.
    shape = (256, 32)
    cost = frame_cost(*shape)
    working_depth = 16
    budget = ENTRY + (working_depth + 1) * cost
    for path in ("direct", "indirect", "start"):
        working = encode(f"{path}-safe", path, working_depth, shape, budget)
        protected = encode(f"{path}-protected", path, 4096, shape, budget)
        ladder = [(depth, encode(f"{path}-stress-{depth}", path, depth, shape,
                                 ENTRY + (depth + 1) * cost))
                  for depth in (32, 64, 128, 256, 512, 1024, 2048, 4096)]
        for engine in ("wasmoon", "wasmtime"):
            execute(engine, f"{path}-safe", working, normal(working_depth, shape))
            execute(engine, f"{path}-protected", protected, controlled("stack:4", path == "start"))
            high = working_depth
            overflow = None
            for depth, wasm in ladder:
                exhausted = False

                def accept(code, out, err):
                    nonlocal exhausted
                    exhausted = (code > 0 and not out and re.search(
                        r"stack (?:overflow|exhausted)|call stack", err, re.IGNORECASE
                    ) is not None)
                    return exhausted or normal(depth, shape)(code, out, err)

                execute(engine, f"{path}-stress-{depth}", wasm, accept)
                if exhausted:
                    overflow = depth
                    break
                high = depth
            if overflow is None:
                raise RuntimeError(f"{engine} {path}: no engine overflow in pressure ladder")
            print(f"margin {engine} {path}: working={working_depth} last_success={high} "
                  f"first_tested_engine_exhaustion={overflow} extra_tested_levels={high - working_depth}")


def main():
    if platform.system() != "Linux" or platform.machine() != "x86_64":
        raise SystemExit("S03 requires x86_64 Linux or WSL2")
    import resource

    runtime.OUT = runtime.ROOT / "_build/s03-stack"
    runtime.OUT.mkdir(parents=True, exist_ok=True)
    print(platform.platform(), "RLIMIT_STACK", resource.getrlimit(resource.RLIMIT_STACK))
    for tool, version in runtime.VERSIONS.items():
        exe = shutil.which(tool)
        if not exe:
            raise SystemExit(f"missing {tool} {version}")
        runtime.artifact(tool, exe)
        runtime.run(f"version-{tool}", [exe, "--version"],
                    lambda code, out, err: code == 0 and version in out + err)
    semantics()
    lifecycle_checks()
    pressure()
    print("S03 stack probe passed")


if __name__ == "__main__":
    main()

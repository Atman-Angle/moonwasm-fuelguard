"""Validate A09/A10 against the actual output bytes of the MoonBit CLI."""

import platform
import re
import resource
import shutil
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "runtime"))
import check as runtime

OUT = runtime.ROOT / "_build/s08-growth"
MAX = (1 << 63) - 1


def encode(name, wat):
    source = OUT / f"{name}.wat"
    source.write_text(wat, encoding="utf-8")
    target = source.with_suffix(".wasm")
    runtime.run(f"encode-{name}", ["wasm-tools", "parse", source, "-o", target], runtime.ok)
    return target


def print_wasm(name, path):
    return runtime.run(f"print-{name}", ["wasm-tools", "print", path], runtime.ok)


def instrument(name, source, budget, flags, error=None):
    target = OUT / f"{name}.wasm"
    target.unlink(missing_ok=True)
    args = ["moon", "run", "cmd/instrument", "--target", "wasm", "--",
            source, "-o", target, "--fuel", budget, "--profile", "legacy", *flags]
    if error:
        runtime.run(f"instrument-{name}", args,
                    lambda code, out, err: code == 2 and error in out + err, timeout=180)
        if target.exists():
            raise RuntimeError(f"{name}: an output was written on rejection")
        return None
    runtime.run(f"instrument-{name}", args, runtime.ok, timeout=180)
    runtime.run(f"validate-{name}", ["wasm-tools", "validate", target], runtime.ok)
    return runtime.artifact(name, target)


def fixture(kind, maximum):
    if kind == "memory":
        resource_decl = f"(memory 1 {maximum})"
        inputs = '(param i32)'
        operands = 'local.get 0'
        grow = 'memory.grow'
        tail = ''
    else:
        resource_decl = f"(table 1 {maximum} externref)"
        inputs = '(param externref i32)'
        operands = 'local.get 0 local.get 1'
        grow = 'table.grow'
        tail = '(func (export "read_new") (result externref) i32.const 1 table.get 0)'
    return f"""(module
      (import "spectest" "print_i32" (func $unused (param i32)))
      {resource_decl}
      (func $run (export "run") {inputs} (result i32)
        {operands} {grow})
      (func $after (export "after") {inputs} (result i32)
        {operands} {grow} i32.const 87 drop)
      {tail})"""


def args(kind, delta):
    reference = '(ref.extern 7) ' if kind == "table" else ""
    return f'{reference}(i32.const {delta})'


def returns(kind, delta, previous, export="run"):
    return f'(assert_return (invoke "{export}" {args(kind, delta)}) (i32.const {previous}))'


def traps(kind, delta, code, site, export="run"):
    return f'''(assert_trap (invoke "{export}" {args(kind, delta)}) "unreachable")
(assert_return (get "__moonwasm_trap_code") (i32.const {code}))
(assert_return (get "__moonwasm_trap_site") (i32.const {site}))'''


def run_wast(name, module, checks):
    # Both WAST runners instantiate the exact bytes and read exported globals
    # after the trap without invoking the failed guest again.
    path = OUT / f"{name}.wast"
    binary = "".join(f"\\{byte:02x}" for byte in module.read_bytes())
    path.write_text(f'(module binary "{binary}")\n{checks}\n', encoding="ascii")
    for engine, command in (
        ("wasmtime", ["wasmtime", "wast", "-W", "max-wasm-stack=524288"]),
        ("wasmoon", ["wasmoon", "test", "--show-success"]),
    ):
        def passed(code, stdout, _stderr):
            if engine == "wasmtime":
                return code == 0
            expected = checks.count("(assert_")
            return (code == 0 and f"Passed:  {expected}\n" in stdout
                    and "Failed:  0" in stdout and "Skipped: 0" in stdout)

        runtime.run(f"{engine}-{name}", [*command, path], passed)


def verify_layout(original, target, kind):
    wat = print_wasm(target.stem, target)
    imports = lambda text: re.findall(r"^\s*\(import .*$", text, flags=re.MULTILINE)
    assert imports(wat) == imports(print_wasm(original.stem, original))
    expected_helper = 3 if kind == "memory" else 4
    assert re.search(r'\(export "run" \(func \$run\)\)', wat)
    assert re.search(r'\(func \$run \(;1;\)', wat)
    assert re.search(r'\(func \$after \(;2;\)', wat)
    assert len(re.findall(rf"^\s+call {expected_helper}$", wat, flags=re.MULTILINE)) == 2
    assert len(re.findall(rf"^\s+{kind}\.grow\b", wat, flags=re.MULTILINE)) == 1


def verify_growth(kind, flag, rate, code):
    original = encode(f"{kind}-original", fixture(kind, 3))
    declared = encode(f"{kind}-declared-max", fixture(kind, 1))
    for path in (original, declared):
        runtime.run(f"validate-{path.stem}", ["wasm-tools", "validate", path], runtime.ok)
        runtime.artifact(path.stem, path)
    # Function import at index 0 does not participate in source site numbering.
    operands = 1 if kind == "memory" else 2
    static = operands + 8
    grow_site = operands + 1
    after_site = 2 * grow_site + 1
    flags = [flag, "2"]

    run_wast(f"{kind}-original-zero", original, returns(kind, 0, 1))
    run_wast(f"{kind}-original-exact", original, returns(kind, 1, 1))
    run_wast(f"{kind}-original-plus-one", original, returns(kind, 2, 1))
    run_wast(f"{kind}-original-u32", original, returns(kind, -1, -1))
    run_wast(f"{kind}-original-minus-one", declared, returns(kind, 1, -1, "after"))

    exact_budget = instrument(f"{kind}-exact", original, static + rate, flags)
    verify_layout(original, exact_budget, kind)
    run_wast(f"{kind}-exact", exact_budget, returns(kind, 1, 1))
    zero = instrument(f"{kind}-zero", original, static, [flag, "1"])
    run_wast(f"{kind}-zero", zero, returns(kind, 0, 1))
    constrained = instrument(f"{kind}-both-fail", original, static, flags)
    run_wast(f"{kind}-both-fail", constrained, traps(kind, 2, code, grow_site))
    run_wast(f"{kind}-fuel-only", constrained, traps(kind, 1, 1, grow_site))
    run_wast(f"{kind}-unsigned", constrained, traps(kind, -1, code, grow_site))
    below = instrument(f"{kind}-static-first", original, static - 1, flags)
    run_wast(f"{kind}-static-first", below, traps(kind, 2, 1, grow_site))
    native_fail = instrument(f"{kind}-native-failure", declared, static + rate + 2, flags)
    run_wast(f"{kind}-native-failure", native_fail, returns(kind, 1, -1, "after"))
    no_refund = instrument(f"{kind}-no-refund", declared, static + rate, flags)
    run_wast(f"{kind}-no-refund", no_refund, traps(kind, 1, 1, after_site, "after"))
    enough = instrument(f"{kind}-large-budget", original, MAX, flags)
    run_wast(f"{kind}-over-by-one", enough, traps(kind, 2, code, grow_site))
    run_wast(f"{kind}-current-size", enough, returns(kind, 1, 1) +
             "\n" + returns(kind, 0, 2) + "\n" + traps(kind, 1, code, grow_site))
    run_wast(f"{kind}-unsigned-large-budget", enough, traps(kind, -1, code, grow_site))
    if kind == "table":
        run_wast("table-reference-identity", enough, returns(kind, 1, 1) +
                 '\n(assert_return (invoke "read_new") (ref.extern 7))')
    resource_name = "memory pages" if kind == "memory" else "table elements"
    instrument(f"{kind}-initial-over", original, MAX, [flag, "0"],
               f"initial {resource_name} 1 exceeds configured limit 0")
    instrument(f"{kind}-missing-limit", original, MAX, [], f"requires {flag}" if
               kind == "memory" else "requires a defined externref table")


def main():
    if platform.system() != "Linux" or platform.machine() != "x86_64":
        raise SystemExit("S08 verification requires x86_64 Linux or WSL2")
    runtime.OUT = OUT
    OUT.mkdir(parents=True, exist_ok=True)
    print(platform.platform(), platform.libc_ver(), "RLIMIT_STACK",
          resource.getrlimit(resource.RLIMIT_STACK))
    for tool, version in runtime.VERSIONS.items():
        path = shutil.which(tool)
        if path is None:
            raise SystemExit(f"missing {tool} {version}; see integration/runtime/README.md")
        runtime.artifact(tool, path)
        runtime.run(f"version-{tool}", [tool, "--version"],
                    lambda code, out, err: code == 0 and version in out + err)
    runtime.run("version-moon", ["moon", "version"], runtime.ok)
    verify_growth("memory", "--max-memory-pages", 64, 2)
    verify_growth("table", "--max-table-elements", 4, 3)
    funcref = encode("funcref-original", """(module (table 1 3 funcref)
      (func (export "run") (result i32) ref.null func i32.const 1 table.grow 0))""")
    instrument("funcref-rejected", funcref, MAX, ["--max-table-elements", "2"],
               "table.grow requires a defined externref table")
    both = encode("combined-original", """(module (memory 1 3) (table 1 3 externref)
      (func (export "run") (param externref) (result i32 i32)
        i32.const 1 memory.grow
        local.get 0 i32.const 1 table.grow)
      (func (export "fill") (param externref) (result externref)
        i32.const 0 local.get 0 i32.const 1 table.fill
        i32.const 0 table.get))""")
    combined = instrument("combined", both, 1000,
                          ["--max-memory-pages", "2", "--max-table-elements", "2"])
    for name, module in (("combined-original", both), ("combined", combined)):
        run_wast(name, module, """
(assert_return (invoke "run" (ref.extern 7)) (i32.const 1) (i32.const 1))
(assert_return (invoke "fill" (ref.extern 9)) (ref.extern 9))""")
    print("S08 A09/A10 passed")


if __name__ == "__main__":
    main()

"""Check Fuel v2 boundary traces in two engines."""

import argparse
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from integration.stack_pass import check as stack

MAX = (1 << 63) - 1
CODEGEN = "fuel-v2"


def balance(value):
    return stack.returns('(get "probe_fuel")', ("i64", value))


def inspect_balance(name, product):
    # Test observer only. The instrumentation ABI appends diagnostics directly
    # after the fuel global, including when original globals are present.
    text = stack.print_wasm(f"{name}-metered", product)
    diagnostics = re.search(r'\(export "__moonwasm_trap_code" \(global (\d+)\)\)', text)
    assert diagnostics is not None
    fuel_index = int(diagnostics[1]) - 1
    text = re.sub(r'^  \(@custom "fuelguard\.instrumented"[^\n]*\n', "", text, flags=re.M)
    end = text.rfind("\n)")
    assert end >= 0
    return stack.compile_wat(f"{name}-observer", text[:end] +
                             f'\n  (export "probe_fuel" (global {fuel_index}))' + text[end:])


def paired(name, source, checks, *, fuel=MAX, units=100000, depth=128, flags=()):
    product, _ = stack.instrument(name, source, units, depth, fuel, flags)
    stack.run(name, product, *(check for check in checks if '"probe_fuel"' not in check))
    stack.run(f"{name}-balance", inspect_balance(name, product), *checks)


def exit_paths():
    source = stack.compile_wat("branches", """(module
      (func (export "go") (param i32) (result i32)
        block i32.const 17 local.get 0 br_if 1 drop end i32.const 3)
      (func (export "early") (param i32) (result i32)
        local.get 0 if i32.const 23 return end i32.const 5)
      (func (export "table_exit") (param i32) (result i32)
        block (result i32) i32.const 19 local.get 0 br_table 1 0 end
        i32.const 1 i32.add))""")
    paired("branch-root", source, (
        stack.returns(stack.invoke("go", 1), ("i32", 17)), balance(6),
        stack.returns(stack.invoke("go", 0), ("i32", 3)), balance(0),
    ), fuel=10)
    paired("explicit-return", source, (
        stack.returns(stack.invoke("early", 1), ("i32", 23)), balance(6),
        stack.returns(stack.invoke("early", 0), ("i32", 5)), balance(3),
    ), fuel=10)
    paired("branch-table-root", source, (
        stack.returns(stack.invoke("table_exit", 0), ("i32", 19)), balance(7),
        stack.returns(stack.invoke("table_exit", 1), ("i32", 20)), balance(0),
    ), fuel=12)


def trap_and_dynamic():
    source = stack.compile_wat("division", """(module
      (func (export "go") (param i32) (result i32)
        local.get 0 if (result i32) i32.const 1 i32.const 0 i32.div_s
        else i32.const 42 end))""")
    paired("native-trap-prepay", source, (
        stack.trap_check(stack.invoke("go", 1), 0, 0, "integer divide by zero"), balance(2),
    ), fuel=10)
    paired("unaffordable-first-site", source, (
        stack.trap_check(stack.invoke("go", 1), 1, 4),
    ), fuel=5)
    source = stack.compile_wat("bulk-callee", """(module (memory 1 1)
      (func $fill i32.const 0 i32.const 65 i32.const 1 memory.fill)
      (func (export "go") (param i32) (result i32)
        local.get 0 if call $fill end i32.const 42))""")
    flags = ("--max-memory-pages", 1)
    paired("after-dynamic-call-exact", source, (
        stack.returns(stack.invoke("go", 1), ("i32", 42)), balance(0),
    ), fuel=14, flags=flags)
    paired("after-dynamic-call-low", source, (
        stack.trap_check(stack.invoke("go", 1), 1, 9),
    ), fuel=13, flags=flags)
    paired("dynamic-callee-low", source, (
        stack.trap_check(stack.invoke("go", 1), 1, 4), balance(0),
    ), fuel=12, flags=flags)


def stack_boundaries():
    source = stack.compile_wat("call-chain", """(module
      (func $leaf (result i32) i32.const 42)
      (func $middle (result i32) call $leaf)
      (func (export "go") (result i32) call $middle))""")
    _, costs = stack.instrument("shared-costs", source)
    exact = sum(costs[index] for index in range(3))
    invoke = stack.invoke("go")
    paired("exact-stack-and-fuel", source, (stack.returns(invoke, ("i32", 42)), balance(0)),
           fuel=7, units=exact, depth=3)
    for name, units, depth, code, site, remaining in (
        ("leaf-stack-first", exact - 1, 2, 4, 2, 1),
        ("leaf-depth", exact, 2, 5, 2, 1),
        ("nonleaf-stack-first", costs[2] + costs[1] - 1, 1, 4, 4, 4),
        ("nonleaf-depth", costs[2] + costs[1], 1, 5, 4, 4),
    ):
        paired(name, source, (stack.trap_check(invoke, code, site), balance(remaining)),
               fuel=7, units=units, depth=depth)
    paired("packed-counter-max", source, (
        stack.returns(invoke, ("i32", 42)), balance(MAX - 7),
        stack.returns(invoke, ("i32", 42)), balance(MAX - 14),
    ), units=stack.PACKED_MAX, depth=stack.PACKED_MAX)


def indirect():
    source = stack.compile_wat("indirect", """(module
      (type $sig (func (result i32)))
      (table 1 1 funcref)
      (func $target (type $sig) i32.const 41)
      (elem (i32.const 0) func $target)
      (func (export "go") (param i32) (result i32)
        local.get 0 if (result i32) i32.const 0 call_indirect (type $sig)
        else i32.const 50 end))""")
    paired("indirect-wrapper", source, (
        stack.returns(stack.invoke("go", 1), ("i32", 41)), balance(3),
        stack.returns(stack.invoke("go", 0), ("i32", 50)), balance(0),
    ), fuel=12, depth=2, flags=("--max-table-elements", 1))


def import_reentry():
    source = stack.compile_wat("reentry", """(module
      (import "bridge" "tick" (func $tick))
      (func (export "nested") nop nop)
      (func (export "go") (param i32) (result i32)
        local.get 0 if call $tick end i32.const 42))""")
    bridge = """(module $bridge
      (type $thunk (func))
      (table (export "slots") 1 funcref)
      (func (export "tick") i32.const 0 call_indirect (type $thunk)))
    (register "bridge" $bridge)"""
    connect = """(register "guest" $guest)
    (module
      (import "bridge" "slots" (table 1 funcref))
      (import "guest" "nested" (func $nested))
      (elem (i32.const 0) func $nested))"""
    from integration.fuel_oracle.join import Effect, Op, evaluate, spans

    plan = spans((Op("nop"), Op("nop")), 2) + spans(
        (Op("local.get"), Op("if", (Op("call"),)), Op("i32.const")), 5)
    for budget, depth in ((6, 3), (7, 3), (8, 3), (9, 3), (8, 2)):
        label = f"reentry-{budget}-{depth}"
        product, _ = stack.instrument(label, source, units=100000, depth=depth, fuel=budget,
                                      flags=("--allow-import", "bridge.tick"))
        effect = {7: Effect(callee=(2, 3))}
        if depth == 2:
            # The nested export's stack wrapper rejects before entering its Fuel span.
            expected = stack.trap_check(stack.invoke("go", 1), 5, 1)
            remaining = budget - 5
        else:
            wanted = evaluate(budget, plan, (5, 6, 7, 8), effect)
            expected = (stack.trap_check(stack.invoke("go", 1), wanted.failure, wanted.site)
                        if wanted.failure else stack.returns(stack.invoke("go", 1), ("i32", 42)))
            remaining = wanted.remaining
        runs = [(label, product, expected)]
        if remaining is not None:
            runs.append((f"{label}-balance", inspect_balance(label, product),
                         f"{expected}\n{balance(remaining)}"))
        for name, module, checks in runs:
            guest = stack.wast_module(module).replace("(module binary", "(module $guest binary", 1)
            checks = re.sub(r'\((invoke|get) "', r'(\1 $guest "', checks)
            stack.wast(name, "\n".join([bridge, guest, connect, checks]), checks.count("(assert_"))


def checked_stack_bound():
    source = stack.compile_wat("checked-stack-source", f"""(module
      (func $small (result i32) i32.const 7)
      (func $wide (result i32) (local {"i64 " * 24}) i32.const 4)
      (func $mid (result i32) call $small)
      (func (export "same_scope") (result i32)
        call $wide drop
        call $small drop
        call $mid)
      (func (export "one_arm") (param i32) (result i32)
        local.get 0 if call $wide drop end
        call $mid))""")
    _, caps = stack.instrument("checked-stack-audit", source, 100000, 4)
    assert max(caps[0], caps[2]) <= caps[1] < caps[2] + caps[0]
    go = stack.invoke("same_scope")
    exact = caps[3] + caps[2] + caps[0]
    for name, units, depth, expected in (
        ("exact", exact, 3, stack.returns(go, ("i32", 7))),
        ("first-units", caps[3] + caps[1] - 1, 3, stack.trap_check(go, 4, 5)),
        ("nested-units", caps[3] + caps[1], 3, stack.trap_check(go, 4, 3)),
        ("nested-depth", exact, 2, stack.trap_check(go, 5, 3)),
        ("skipped-arm", caps[4] + caps[2] - 1, 3,
         stack.trap_check(stack.invoke("one_arm", 0), 4, 15)),
    ):
        label = f"checked-stack-{name}"
        product, _ = stack.instrument(label, source, units, depth)
        stack.run(label, product, expected)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    evidence = stack.runtime.acceptance_directory()
    parser.add_argument("--out", type=Path, required=evidence is None, default=evidence)
    opts = parser.parse_args()
    if not __debug__:
        parser.error("run Python without -O so assertions execute")
    stack.OUT = stack.runtime.OUT = opts.out.resolve()
    stack.OUT.mkdir(parents=True, exist_ok=evidence == stack.OUT)
    stack.CODEGEN = CODEGEN
    stack.build_instrument("build-fuel-cache-tests")
    for check in (exit_paths, trap_and_dynamic, stack_boundaries, indirect, import_reentry,
                  checked_stack_bound):
        check()
    from integration.fuel_cache import oracle_cases
    oracle_cases.run()


if __name__ == "__main__":
    main()

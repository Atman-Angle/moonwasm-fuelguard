"""Verify the complete production-v1 pipeline in both pinned Linux engines."""
import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from integration.fuel_oracle.oracle import Site, evaluate
from integration.generated.check import FUEL_V2_MARKER, JOIN_MARKERS
from integration.policy.check import HEADER, code_body, section
from integration.stack_pass import check as stack

runtime = stack.runtime
OUT = runtime.acceptance_directory() or runtime.ROOT / "_build/s12"
ENGINES = ("wasmoon", "wasmtime")
MARKER = (b"production-v1|fuel-v1|diagnostics-v1|metering=per-instruction"
          b"|growth=growth-v1|stack=stack-v2")
MAX = stack.MAX


def instrument(name, source, **kwargs):
    original = runtime.sha256(source)
    target, caps = stack.instrument(name, source, **kwargs)
    summary = (OUT / f"instrument-{name}.stdout").read_text()
    assert "passes: FuelPass, GrowthPass, StackPass" in summary
    marker = (b"production-v1|fuel-v1.2|diagnostics-v1|metering=join-span"
              b"|growth=growth-v1|stack=stack-v2|codegen=" +
              JOIN_MARKERS[stack.CODEGEN]) if stack.CODEGEN in JOIN_MARKERS else MARKER
    if stack.CODEGEN == "fuel-v2":
        marker = FUEL_V2_MARKER
    assert "profile: production-v1" in summary and marker in target.read_bytes()
    assert runtime.sha256(source) == original
    return target, caps


def global_is(name, value):
    return stack.returns(f'(get "{name}")', ("i32", value))


def grow_call(memory, table):
    return f'(invoke "run" (i32.const {memory}) (ref.extern 7) (i32.const {table}))'


def grow_result(memory, table, old_memory, old_table):
    return stack.returns(grow_call(memory, table), ("i32", old_memory), ("i32", old_table))


def combined_growth():
    source = stack.compile_wat("combined-source", """(module
      (import "spectest" "global_i32" (global $seed i32))
      (import "spectest" "print_i32" (func $print (param i32)))
      (memory (export "memory") 1 2)
      (table 1 2 externref)
      (global $phase (export "phase") (mut i32) (i32.const 0))
      (data (i32.const 0) "Z")
      (func $boot global.get $seed global.set $phase)
      (start $boot)
      (func $work (param i32 externref i32) (result i32 i32)
        local.get 0 memory.grow
        local.get 1 local.get 2 table.grow)
      (func (export "run") (param i32 externref i32) (result i32 i32)
        local.get 0 local.get 1 local.get 2 call $work)
      (func (export "read_slot") (result externref) i32.const 1 table.get 0))""")
    common = ("--allow-import", "spectest.global_i32", "--allow-import", "spectest.print_i32")
    flags = (*common, "--max-memory-pages", 3, "--max-table-elements", 3)
    bounded = (*common, "--max-memory-pages", 2, "--max-table-elements", 2)
    complete, costs = instrument("combined-complete", source, units=10000, depth=2, flags=flags)
    checks = (
        global_is("phase", 666),
        grow_result(0, 0, 1, 1),
        grow_result(1, 1, 1, 1),
        '(assert_return (invoke "read_slot") (ref.extern 7))',
        grow_result(0, 0, 2, 2),
        grow_result(1, 1, -1, -1),
    )
    stack.run("combined-original", source, *checks)
    stack.run("combined-complete", complete, *checks)

    before = stack.print_wasm("combined-source", source)
    after = stack.print_wasm("combined-complete", complete)
    select_imports = lambda wat: [line.strip() for line in wat.splitlines() if '(import ' in line]
    assert len(select_imports(before)) == 2 and select_imports(before) == select_imports(after)
    offset = stack.charge_helper_offset()
    assert f'(start {7 + offset})' in after and f'(export "run" (func {8 + offset}))' in after
    assert '(export "memory" (memory 0))' in after and '(export "phase" (global $phase))' in after
    assert '(data (;0;) (i32.const 0) "Z")' in after
    assert after.count("\n    memory.grow") == 1 and after.count("\n    table.grow") == 1

    exact_units = costs[2] + costs[3]
    # start: 3. caller: 1+1+1+3. callee: 1+8+1+1+8.
    # For (1, 1), memory adds 64 and table adds 4.
    for name, fuel, expected in (("under", 95, (1, 8)), ("exact", 96, None),
                                 ("over", 97, None), ("max", MAX, None)):
        product, _ = instrument(f"combined-{name}", source, fuel=fuel,
                                units=exact_units, depth=2, flags=bounded)
        check = stack.trap_check(grow_call(1, 1), *expected) if expected else grow_result(1, 1, 1, 1)
        stack.run(f"combined-{name}", product, check)

    order_checks = (
        ("stack", MAX, exact_units - 1, 1, 0, 0, 4, 13),
        ("depth", MAX, exact_units, 1, 0, 0, 5, 13),
        ("fuel-before-call", 8, exact_units - 1, 1, 0, 0, 1, 13),
        ("memory-before-dynamic", 18, exact_units, 2, 2, 0, 2, 5),
        ("memory-unsigned", MAX, exact_units, 2, -1, 0, 2, 5),
        ("fuel-before-memory", 17, exact_units, 2, 2, 0, 1, 5),
        ("table-before-dynamic", 28, exact_units, 2, 0, 2, 3, 8),
        ("table-unsigned", MAX, exact_units, 2, 0, -1, 3, 8),
        ("fuel-before-table", 27, exact_units, 2, 0, 2, 1, 8),
    )
    if stack.CODEGEN == "fuel-v2":
        order_checks = (
            ("stack", MAX, exact_units - 1, 1, 0, 0, 4, 13),
            ("depth", MAX, exact_units, 1, 0, 0, 5, 13),
            ("fuel-before-call", 8, exact_units - 1, 1, 0, 0, 1, 10),
            ("memory-before-dynamic", 28, exact_units, 2, 2, 0, 2, 5),
            ("memory-unsigned", MAX, exact_units, 2, -1, 0, 2, 5),
            ("fuel-before-memory", 27, exact_units, 2, 2, 0, 1, 4),
            ("table-before-dynamic", 28, exact_units, 2, 0, 2, 3, 8),
            ("table-unsigned", MAX, exact_units, 2, 0, -1, 3, 8),
            ("fuel-before-table", 27, exact_units, 2, 0, 2, 1, 4),
        )
    for name, fuel, units, depth, memory, table, code, site in order_checks:
        product, _ = instrument(f"combined-{name}", source, fuel=fuel,
                                units=units, depth=depth, flags=bounded)
        stack.run(f"combined-{name}", product,
                  stack.trap_check(grow_call(memory, table), code, site))
    # At size 2, a third attempted page is within policy limit 3 but fails at
    # the original maximum. The cost of that failed grow is still spent.
    fuel_v2 = stack.CODEGEN == "fuel-v2"
    no_refund, _ = instrument("combined-no-refund", source, fuel=185 if fuel_v2 else 175,
                              units=exact_units, depth=2, flags=flags)
    after_first = (grow_result(1, 0, -1, 2), stack.trap_check(grow_call(0, 0), 1, 10)) if fuel_v2 else (
        stack.trap_check(grow_call(1, 0), 1, 6),)
    stack.run("combined-no-refund", no_refund, grow_result(1, 1, 1, 1), *after_first)
    table_no_refund, _ = instrument("combined-table-no-refund", source, fuel=125,
                                    units=exact_units, depth=2, flags=flags)
    stack.run("combined-table-no-refund", table_no_refund, grow_result(1, 1, 1, 1),
              grow_result(0, 1, 2, -1), stack.trap_check(grow_call(0, 0), 1, 10))
    return source, complete, flags


def bulk():
    source = stack.compile_wat("bulk-source", """(module
      (memory 1 1)
      (global $ticks (export "ticks") (mut i32) (i32.const 0))
      (func $length (param i32) (result i32)
        global.get $ticks i32.const 1 i32.add global.set $ticks local.get 0)
      (func (export "fill") (param i32) (result i32)
        i32.const 0 i32.const 65 local.get 0 call $length memory.fill
        i32.const 0 i32.load8_u))""")
    for length in (0, 1, 65536, -1):
        # The argument call and its body use 3 + 6, operand setup 3, fill base 4.
        # Then i32.const and the one-byte load cost 1 + 3.
        trace = [Site("before", 12), Site("fill", 4, dynamic=(4, 1, lambda: length & 0xffffffff)),
                 Site("load", 4)]
        budget = 20 + max(length, 0)
        oracle = evaluate(budget, trace)
        target, _ = instrument(f"bulk-{length}", source, fuel=budget, units=10000, depth=2,
                               flags=("--max-memory-pages", 1))
        invocation = stack.invoke("fill", length)
        expected = 0 if length == 0 else 65
        if length == -1:
            assert (oracle.failure, oracle.site) == (1, "fill")
            check = stack.trap_check(invocation, 1, 11)
        else:
            assert oracle.failure is None and oracle.remaining == 0
            check = stack.returns(invocation, ("i32", expected))
        stack.run(f"bulk-{length}", target, check, global_is("ticks", 1))


def repeat(name, product, *checks):
    unit = "\n".join((stack.wast_module(product), *checks))
    stack.wast(name, "\n".join([unit] * 20), 20 * sum(c.count("(assert_") for c in checks))


def control_flow():
    source = stack.compile_wat("control-source", """(module
      (global $trace (export "trace") (mut i32) (i32.const 0))
      (func (export "count") (param i32) (result i32)
        block
          loop
            local.get 0 i32.eqz br_if 1
            global.get $trace i32.const 1 i32.add global.set $trace
            local.get 0 i32.const 1 i32.sub local.set 0 br 0
          end
        end
        global.get $trace)
      (func (export "choose") (param i32) (result i32)
        block
          block
            local.get 0 br_table 0 1
          end
          i32.const 7 global.set $trace
        end
        global.get $trace)
      (func (export "forever")
        loop global.get $trace i32.const 1 i32.add global.set $trace br 0 end))""")
    for count in (1, 40):
        for offset in (-1, 0, 1):
            name = f"control-count-{count}-{offset + 1}"
            product, _ = instrument(name, source, fuel=6 + 13 * count + offset,
                                    units=10000, depth=1)
            call = stack.invoke("count", count)
            check = (stack.trap_check(call, 1, 16) if offset < 0 else
                     stack.returns(call, ("i32", count)))
            repeat(name, product, check, global_is("trace", count))
    for arm, fuel, expected in ((0, 9, 7), (1, 6, 0)):
        product, _ = instrument(f"control-arm-{arm}", source, fuel=fuel, units=10000, depth=1)
        repeat(f"control-arm-{arm}", product,
               stack.returns(stack.invoke("choose", arm), ("i32", expected)),
               global_is("trace", expected))
    product, _ = instrument("control-forever", source, fuel=13, units=10000, depth=1)
    repeat("control-forever", product,
           stack.trap_check(stack.invoke("forever"), 1, 27), global_is("trace", 2))


def refusal(name, source, flags, message, fuel=MAX):
    target = OUT / f"{name}.wasm"
    target.unlink(missing_ok=True)
    runtime.run(f"reject-{name}", ["moonrun", stack.TOOL, source, "-o", target, "--fuel", fuel, *flags],
                lambda code, out, err: code == 2 and message in out + err)
    assert not target.exists()


def migration_and_determinism(source, complete, flags):
    budgets = ("--max-stack-units", 10000, "--max-call-depth", 2)
    for rep in (2, 3):
        product, _ = instrument(f"combined-repeat-{rep}", source, units=10000, depth=2, flags=flags)
        assert runtime.sha256(product) == runtime.sha256(complete)
    refusal("missing-stack", source, flags, "production-v1 requires")
    refusal("missing-memory", source, (*budgets, *flags[:-4], *flags[-2:]), "requires --max-memory-pages")
    refusal("missing-table", source, (*budgets, *flags[:-2]), "requires --max-table-elements")
    refusal("initial-memory", source, (*budgets, *flags[:-4], "--max-memory-pages", 0, *flags[-2:]),
            "initial memory pages")
    refusal("initial-table", source, (*budgets, *flags[:-2], "--max-table-elements", 0),
            "initial table elements")
    refusal("duplicate", complete, (*budgets, *flags), "already instrumented")
    refusal("unknown-model", source, (*budgets, *flags, "--cost-model", "fuel-v99"), "unknown --cost-model")
    refusal("zero-fuel", source, (*budgets, *flags), "invalid --fuel", fuel=0)
    refusal("fuel-overflow", source, (*budgets, *flags), "--fuel", fuel=MAX + 1)
    refusal("missing-import", source, (*budgets, *flags[2:]), "import not allowed")
    refusal("ambiguous-import", source, (*budgets, *flags, "--allow-import", "a.b.c"), "ambiguous allow-import")

    def compat(name, input_path, profile, opts, marker):
        out = OUT / f"{name}.wasm"
        out.unlink(missing_ok=True)
        note = runtime.run(f"instrument-{name}", ["moonrun", stack.TOOL, input_path, "-o", out,
                           "--fuel", MAX, "--profile", profile, *opts], runtime.ok)
        assert "passes: FuelPass, GrowthPass\n" in note and marker in out.read_bytes()
        runtime.run(f"validate-{name}", ["wasm-tools", "validate", out], runtime.ok)
        runtime.artifact(name, out)
        return out

    migrated = compat("compatibility", source, "fuel-growth-v1", flags,
                      b"fuel-growth-v1|fuel-v1|diagnostics-v1")
    stack.run("compatibility", migrated, grow_result(1, 1, 1, 1))
    refusal("rejected-compatibility-artifact", migrated, (*budgets, *flags), "already instrumented")
    legacy_source = stack.compile_wat("legacy-source", '(module (func (export "answer") (result i32) i32.const 42))')
    legacy = compat("legacy", legacy_source, "legacy", (), b"legacy|fuel-v1|diagnostics-v1")
    stack.run("legacy", legacy, stack.returns(stack.invoke("answer"), ("i32", 42)))
    refusal("rejected-legacy-artifact", legacy, budgets, "already instrumented")
    tail_call = stack.compile_wat(
        "legacy-tail-call-source", '(module (func $loop (export "_start") return_call $loop))')
    refusal("legacy-zero-cost-tail-call", tail_call, ("--profile", "legacy"),
            "opcode outside fuel-v1 pricing allowlist", fuel=1)
    old = stack.compile_wat("old-diagnostics",
                            '(module (global (export "__moonwasm_trap_code") (mut i32) (i32.const 0)))')
    refusal("old-diagnostics-output", old, budgets, "export name already exists")


def invalid_input():
    budgets = ("--max-stack-units", 10000, "--max-call-depth", 2)
    imported_float = stack.compile_wat(
        "imported-f64-global-source", '(module (import "env" "float" (global f64)))')
    refusal("imported-f64-global", imported_float, (*budgets, "--allow-import", "env.float"),
            "globals require i32 or i64")
    raw_cases = (
        ("truncated", HEADER + b"\x01\x02\x01", "truncated"),
        ("over-limit", HEADER + section(3, b"\x81\x20"), "defined functions 4097"),
        ("unknown-opcode", code_body(b"\x00\xff\x0b"), "production-v1 opcode 255"),
        ("unknown-marker", HEADER + section(0, b"\x16fuelguard.instrumented|diagnostics-v99"),
         "unknown FuelGuard marker"),
    )
    for name, data, message in raw_cases:
        path = OUT / f"source-{name}.wasm"
        path.write_bytes(data)
        refusal(name, path, budgets, message)
    for name, wat, message in (
        ("relaxed", "(module (func (param v128 v128) local.get 0 local.get 1 i8x16.relaxed_swizzle drop))",
         "relaxed SIMD"),
        ("escaping-table", '(module (table (export "table") 1 1 funcref))', "exported table"),
        ("tail-call", "(module (func return_call 0))", "production-v1 opcode 18"),
    ):
        runtime_wat = OUT / f"source-{name}.wat"
        runtime_wat.write_text(wat, encoding="ascii")
        path = runtime_wat.with_suffix(".wasm")
        runtime.run(f"parse-{name}", ["wasm-tools", "parse", runtime_wat, "-o", path], runtime.ok)
        refusal(name, path, (*budgets, "--max-table-elements", 1), message)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--codegen", choices=("p0", "p1", "p2", *JOIN_MARKERS, "fuel-v2"),
                        default="fuel-v2")
    stack.CODEGEN = parser.parse_args().codegen
    runtime.OUT = stack.OUT = OUT
    OUT.mkdir(parents=True, exist_ok=True)
    assert stack.platform.system() == "Linux" and stack.platform.machine() == "x86_64"
    print(stack.platform.platform(), stack.platform.libc_ver(), "RLIMIT_STACK",
          stack.resource.getrlimit(stack.resource.RLIMIT_STACK))
    for tool, version in runtime.VERSIONS.items():
        runtime.run(f"version-{tool}", [tool, "--version"],
                    lambda code, out, err: code == 0 and version in out + err)
    runtime.run("version-moon", ["moon", "version"], runtime.ok)
    stack.build_instrument("build")
    source, complete, flags = combined_growth()
    bulk()
    if stack.CODEGEN not in JOIN_MARKERS:
        control_flow()
    else:
        from integration.fuel_cache.oracle_cases import structural
        structural()
    migration_and_determinism(source, complete, flags)
    invalid_input()
    stack.workloads()
    print("S12 complete production pipeline checks passed")


if __name__ == "__main__":
    main()

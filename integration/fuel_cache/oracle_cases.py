"""Exercise independently derived Fuel v2 spans in both engines."""

import hashlib
import struct
from itertools import chain, cycle

from bench.dataset import wasm_custom_sections
from integration.fuel_cache import check as cache
from integration.fuel_oracle.join import DYNAMIC, Effect, MAX, Op, evaluate, spans
from integration.p1.check import build
from integration.stack_pass import check as stack

runtime = stack.runtime


def flat(wat):
    """One source instruction per line. Immediates are irrelevant to pricing."""
    return tuple(Op(line.split()[0]) for line in wat.splitlines() if line.strip())


def assert_proof(product, plan, functions):
    rows = bytearray()
    ends = bytearray()
    previous_end = 0
    for function_index, last_site in functions:
        ends.extend(struct.pack("<i", last_site))
        for span in plan:
            first_site = span[0][0]
            if previous_end < first_site <= last_site:
                rows.extend(struct.pack("<iiiq", function_index, first_site, len(span),
                                        sum(op.weight for _, op in span)))
        previous_end = last_site or previous_end
    assert wasm_custom_sections(product, b"fuelguard.fuel-v2-spans-v1") == [
        hashlib.sha256(rows).digest() + ends
    ], product


def test_case(name, source, plan, path, budget, invoke, expected=(), effects=None,
              native_message=None, trace=False, flags=(), memory_pages=1,
              repetitions=1, functions=None):
    wanted = evaluate(budget, plan, path, effects)
    product, _, _ = build(source, name, budget, flags, memory_pages=memory_pages)
    if functions is None:
        functions = ((0, plan[-1][-1][0] if plan else 0),)
    assert_proof(product, plan, functions)
    if wanted.failure == "native":
        assert native_message is not None
        outcome = stack.trap_check(invoke, 0, 0, native_message)
    elif wanted.failure:
        outcome = stack.trap_check(invoke, wanted.failure, wanted.site)
    else:
        outcome = stack.returns(invoke, *expected)
    last_write = int(wanted.output.split()[-1]) if wanted.output else 0
    side_effects = (stack.returns('(get "trace")', ("i32", last_write)),) if trace else ()
    checks = (outcome, *side_effects)
    script = "\n".join((stack.wast_module(product), *checks))
    count = sum(check.count("(assert_") for check in checks)
    if wanted.remaining is not None:
        observer = cache.inspect_balance(name, product)
        script += "\n" + "\n".join((stack.wast_module(observer), *checks,
                                     cache.balance(wanted.remaining)))
        count = 2 * count + 1
    stack.wast(name, "\n".join([script] * repetitions), repetitions * count)


def barriers(test_case):
    wat = """
        i32.const 0
        i32.const 7
        i32.store
        i32.const 0
        i32.load
        global.set $trace
        call $leaf
        i32.const 18
        local.get 0
        i32.div_s
        drop
        local.get 0
    """
    source = stack.compile_wat("oracle-barrier-source", f"""(module
      (memory 1)
      (global $trace (export "trace") (mut i32) (i32.const 0))
      (func $leaf nop)
      (func (export "go") (param i32) (result i32)
        {wat} if nop end i32.const 42))""")
    plan = spans((Op("nop"),), 1) + spans(
        (*flat(wat), Op("if", (Op("nop"),)), Op("i32.const")), 3)
    first, last = tuple(range(3, 16)), (16, 17)
    effects = {8: Effect(output="7"), 9: Effect(callee=(1,))}
    cost = sum(op.weight for _, op in plan[1])
    stack.run("oracle-barrier-original", source,
              stack.returns(stack.invoke("go", 2), ("i32", 42)),
              stack.trap_check(stack.invoke("go", 0), 0, 0, "integer divide by zero").splitlines()[0])
    for budget in range(1, cost):
        test_case(f"barrier-unpaid-{budget}", source, plan, first, budget,
                  stack.invoke("go", 2), effects=effects, trace=True, functions=((0, 1), (1, 17)))
    for budget in (cost, cost + 2, cost + 3, cost + 4, MAX):
        test_case(f"barrier-return-{budget}", source, plan, first + last, budget,
                  stack.invoke("go", 2), (("i32", 42),), effects, trace=True, functions=((0, 1), (1, 17)))
    test_case("barrier-native-prepaid-suffix", source, plan, first, cost + 1,
              stack.invoke("go", 0), effects={**effects, 12: Effect(native=True)},
              native_message="integer divide by zero", trace=True, functions=((0, 1), (1, 17)))

    linear = "nop\n" * 128 + "i32.const 7\nglobal.set $trace\ni32.const 42"
    source = stack.compile_wat("oracle-long-span-source", f"""(module
      (global $trace (export "trace") (mut i32) (i32.const 0))
      (func (export "go") (result i32) {linear}))""")
    plan = spans(flat(linear), 2)
    for budget in (131, 132, 133, MAX):
        test_case(f"long-span-{budget}", source, plan, range(2, 133), budget,
                  stack.invoke("go"), (("i32", 42),), {131: Effect(output="7")}, trace=True)

    source = stack.compile_wat("native-suffix-source", """(module
      (global $trace (export "trace") (mut i32) (i32.const 0))
      (func (export "go") (param i32)
        i32.const 17 global.set $trace
        i32.const 1 local.get 0 i32.div_s drop
        i32.const 23 global.set $trace))""")
    ops = tuple(map(Op, ("i32.const", "global.set", "i32.const", "local.get",
                         "i32.div_s", "drop", "i32.const", "global.set")))
    plan = spans(ops, 2)
    for budget in (12, 13, 14, MAX):
        test_case(f"native-before-suffix-{budget}", source, plan, range(2, 10), budget,
                  stack.invoke("go", 0), effects={3: Effect(output="17 "), 6: Effect(native=True),
                                                 9: Effect(output="23")},
                  native_message="integer divide by zero", trace=True)


def structural():
    exercise = test_case
    dead_block = stack.compile_wat(
        "dead-block-lexical-source", '(module (func (export "go") block return nop end nop))')
    body = (Op("block", (Op("return"), Op("nop"))), Op("nop"))
    exercise("dead-block-lexical", dead_block, spans(body, 2), (2, 3), 3, stack.invoke("go"))

    source = stack.compile_wat("nested-if-source", """(module
      (func (export "go") (param i32 i32) (result i32)
        local.get 0 if (result i32)
          local.get 1 if (result i32) i32.const 40 else i32.const 41 end
        else i32.const 39 end
        i32.const 1 i32.add))""")
    inner = Op("if", (Op("i32.const"),), (Op("i32.const"),))
    outer = Op("if", (Op("local.get"), inner), (Op("i32.const"),))
    plan = spans((Op("local.get"), outer, Op("i32.const"), Op("i32.add")), 2)
    for choice, path, value in ((0, (2, 3, 8, 9, 10), 40),
                                (1, (2, 3, 4, 5, 7, 9, 10), 42)):
        for budget in (len(path) - 1, len(path), len(path) + 1):
            exercise(f"nested-if-{choice}-{budget}", source, plan, path, budget,
                     stack.invoke("go", choice, 0), (("i32", value),))

    for joined in (True, False):
        # Changing return to nop gives the continuation a second predecessor.
        then = "return" if joined else "nop"
        name = "unique-fallthrough" if joined else "multiple-predecessors"
        source = stack.compile_wat(f"{name}-source", f"""(module
          (global $trace (export "trace") (mut i32) (i32.const 0))
          (func (export "go") (param i32)
            local.get 0 if {then} else i32.const 17 global.set $trace end nop nop))""")
        plan = spans((Op("local.get"), Op("if", (Op(then),), (Op("i32.const"), Op("global.set"))),
                      Op("nop"), Op("nop")), 2)
        exercise(name, source, plan, (2, 3, 5, 6, 7, 8), 6, stack.invoke("go", 0),
                  effects={6: Effect(output="17")}, trace=True, repetitions=20)

    dead = stack.compile_wat("dead-then-tail-source", """(module
      (global $trace (export "trace") (mut i32) (i32.const 0))
      (func (export "go") (param i32)
        local.get 0 if return nop else i32.const 7 global.set $trace end nop))""")
    plan = spans((Op("local.get"), Op("if", (Op("return"), Op("nop")), (Op("i32.const"), Op("global.set"))),
                  Op("nop")), 2)
    exercise("dead-then-tail", dead, plan, (2, 3, 6, 7, 8), 5,
              stack.invoke("go", 0), effects={7: Effect(output="7")}, trace=True, repetitions=20)

    for label, then, then_ops, first_else in (
        ("dead-branch-exit", "block return br 0 end nop",
         (Op("block", (Op("return"), Op("br", labels=(0,)))), Op("nop")), 8),
        ("dead-conditional-fallthrough", "return i32.const 0 br_if 1",
         (Op("return"), Op("i32.const"), Op("br_if", labels=(1,))), 7),
    ):
        dead = stack.compile_wat(f"{label}-source", f"""(module
          (global $trace (export "trace") (mut i32) (i32.const 0))
          (func (export "go") (param i32)
            local.get 0 if {then} else i32.const 7 global.set $trace end nop))""")
        plan = spans((Op("local.get"), Op("if", then_ops, (Op("i32.const"), Op("global.set"))),
                      Op("nop")), 2)
        exercise(label, dead, plan, (2, 3, *range(first_else, first_else + 3)), 5,
                  stack.invoke("go", 0), effects={first_else + 1: Effect(output="7")},
                  trace=True, repetitions=20)

    for padding in (0, 32):
        decrement = """local.get 0
            i32.const 1
            i32.sub
            local.set 0"""
        loop = ("local.get 0\ni32.eqz\nbr_if 1\n" + "nop\n" * padding +
                decrement + "\nbr 0")
        ops = (Op("local.get"), Op("i32.eqz"), Op("br_if", labels=(1,)),
               *(Op("nop"),) * padding, *flat(decrement), Op("br", labels=(0,)))
        plan = spans((Op("block", (Op("loop", ops),)), Op("i32.const")), 2)
        source = stack.compile_wat(f"oracle-loop-{padding}-source", f"""(module
          (func (export "go") (param i32) (result i32)
            block loop {loop} end end i32.const 42))""")
        for iterations in (2, 40):
            path = (2, 3) + tuple(range(4, 12 + padding)) * iterations + (4, 5, 6, 12 + padding)
            total = 6 + (8 + padding) * iterations
            for budget in (total - 1, total, total + 1, MAX):
                exercise(f"loop-backedge-{padding}-{iterations}-{budget}", source, plan, path, budget,
                         stack.invoke("go", iterations), (("i32", 42),), repetitions=20)

    source = stack.compile_wat(
        "oracle-infinite-source", '(module (func (export "go") loop nop br 0 end))')
    plan = spans((Op("loop", (Op("nop"), Op("br", labels=(0,)))),), 2)
    exercise("loop-only-fuel-terminates", source, plan, chain((2,), cycle((3, 4))), 20,
              stack.invoke("go"), repetitions=20)

    source = stack.compile_wat("oracle-br-table-source", """(module
      (func (export "go") (param i32) (result i32)
        block (result i32)
          block (result i32) i32.const 19 local.get 0 br_table 1 0 end
          i32.const 1 i32.add
        end))""")
    inner = Op("block", (Op("i32.const"), Op("local.get"), Op("br_table", labels=(1, 0))))
    plan = spans((Op("block", (inner, Op("i32.const"), Op("i32.add"))),), 2)
    for branch, path, value in ((0, tuple(range(2, 7)), 19), (1, tuple(range(2, 9)), 20)):
        exercise(f"br-table-target-{branch}", source, plan, path, 9, stack.invoke("go", branch),
                  (("i32", value),), repetitions=20)


def dynamic(test_case):
    memory = "(memory 1 2) (data $data \"ab\")"
    table = "(table 1 2 externref) (elem $elem externref (ref.null extern))"
    for op, immediate, operands in (
        ("memory.copy", "", ("local.get 1", "i32.const 0")),
        ("memory.fill", "", ("local.get 1", "i32.const 7")),
        ("memory.init", " $data", ("local.get 1", "i32.const 0")),
        ("memory.grow", "", ()),
        ("table.copy", "", ("local.get 1", "i32.const 0")),
        ("table.fill", "", ("local.get 1", "ref.null extern")),
        ("table.init", " $elem", ("local.get 1", "i32.const 0")),
        ("table.grow", "", ("ref.null extern",)),
    ):
        _, rate, resource = DYNAMIC[op]
        operand_wat = "\n".join(("i32.const 17", "global.set $trace", *operands, "local.get 0"))
        tail = ("drop\n" if resource else "") + "i32.const 23\nglobal.set $trace"
        source = stack.compile_wat(f"{op}-source", f"""(module
          {table if op.startswith("table.") else memory}
          (global $trace (export "trace") (mut i32) (i32.const 0))
          (func (export "go") (param i32 i32)
            {operand_wat} {op}{immediate} {tail}))""")
        plan = spans((*flat(operand_wat), Op(op), *flat(tail)), 2)
        assert len(plan) == 1
        site = 2 + len(flat(operand_wat))
        path = tuple(site for span in plan for site, _ in span)
        static = sum(op.weight for _, op in plan[0])
        total = static + rate
        variants = [(total - 1, 1, 0, False), (total, 1, 0, False),
                    (total + 1, 1, 0, False), (static, 0, 0, False),
                    (MAX, 1, 0, False)]
        if resource:
            variants += [(static - 1, -1, 0, False),
                         (static, -1, 0, False), (MAX, -1, 0, False)]
        else:
            bad_index = 65536 if op.startswith("memory.") else 1
            variants += [(static, 1, bad_index, True),
                         (total, 1, bad_index, True),
                         (total, -1, 0, True), (MAX, -1, 0, True)]
        for index, (budget, count, dest, native) in enumerate(variants):
            test_case(f"dynamic-{op}-{index}", source, plan, path, budget,
                      stack.invoke("go", count, dest),
                      effects={3: Effect(output="17 "),
                               site: Effect(count=count, current=1, limit=2, native=native),
                               path[-1]: Effect(output="23")},
                      native_message=("out of bounds table access" if op.startswith("table.")
                                      else "out of bounds memory access"),
                      trace=True, memory_pages=2, flags=("--max-table-elements", 2))


def run():
    barriers(test_case)
    structural()
    dynamic(test_case)
    empty = stack.compile_wat("empty-span-source", '(module (func (export "go")))')
    test_case("empty-span", empty, (), (), 1, stack.invoke("go"))

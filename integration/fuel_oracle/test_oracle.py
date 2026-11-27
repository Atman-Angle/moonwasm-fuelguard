"""Hand-computed acceptance vectors. No production rules or analyzer imported."""

from itertools import repeat
import unittest

from oracle import MAX, Result, Site, evaluate


class FuelVectors(unittest.TestCase):
    def test_direct_call_boundary(self):
        # const + const + call = 5, callee get + get + mul + return = 5,
        # caller return = 1.
        trace = [Site("caller:0", 5, call="direct"), Site("callee:0", 5),
                 Site("caller:3", 1, output="42")]
        self.assertEqual(evaluate(10, trace), Result(0, "caller:3", 1))
        self.assertEqual(evaluate(11, trace), Result(0, output="42"))
        self.assertEqual(evaluate(12, trace), Result(1, output="42"))
        self.assertEqual(evaluate(MAX, trace), Result(MAX - 11, output="42"))
        for invalid in (0, -1, MAX + 1):
            with self.assertRaises(ValueError):
                evaluate(invalid, trace)

    def test_branch_loop_and_br_table(self):
        for selection, branch_cost in enumerate((2, 5, 3)):
            for iterations in (0, 2, 20):
                with self.subTest(selection=selection, iterations=iterations):
                    # const+if; selected arm; per-iteration loop, add and br_if;
                    # const+br_table; selected arm; final return.
                    trace = [Site("if:0", 2), Site(f"arm:{selection}", branch_cost)]
                    trace += [Site("loop:0", 3, output=".")] * iterations
                    trace += [Site("dispatch:0", 3),
                              Site(f"target:{selection}", 1, output=str(selection)),
                              Site("return:0", 1)]
                    cost = 7 + branch_cost + 3 * iterations
                    output = "." * iterations + str(selection)
                    for _ in range(20):
                        self.assertEqual(evaluate(cost - 1, trace), Result(0, "return:0", 1, output))
                    self.assertEqual(evaluate(cost, trace), Result(0, output=output))
                    self.assertEqual(evaluate(cost + 1, trace), Result(1, output=output))
                    lengths = [len(evaluate(budget, trace).output) for budget in range(1, cost + 2)]
                    self.assertEqual(lengths, sorted(lengths))

    def test_infinite_loop(self):
        # The loop header and unconditional br share one canonical block.
        loop = Site("loop:0", 2)
        for _ in range(20):
            self.assertEqual(evaluate(9, repeat(loop)), Result(1, "loop:0", 1))
            self.assertEqual(evaluate(10, repeat(loop)), Result(0, "loop:0", 1))

    def test_nested_loop_and_long_prefix(self):
        # Two outer visits; each executes an inner loop twice. The long prefix
        # comprises 32 unit-cost ops plus the final weight-three load barrier.
        outer = [Site("outer:0", 1)] + list(repeat(Site("inner:0", 2, output="."), 2))
        outer += [Site("outer:back", 1)]
        trace = outer * 2 + [Site("load:0", 35, output="x")]
        self.assertEqual(evaluate(46, trace), Result(34, "load:0", 1, "...."))
        self.assertEqual(evaluate(47, trace), Result(0, output="....x"))
        self.assertEqual(evaluate(48, trace), Result(1, output="....x"))

    def test_trap_ends_prepaid_block(self):
        trace = [Site("load:0", 4, native_trap=True), Site("suffix:1", 9, output="lost")]
        self.assertEqual(evaluate(3, trace), Result(3, "load:0", 1))
        self.assertEqual(evaluate(4, trace), Result(0, "load:0", "native"))

    def test_dynamic_vectors_and_single_evaluation(self):
        vectors = [
            (4, 1, 0, 4), (4, 1, 1, 5), (4, 1, 0xffffffff, 4_294_967_299),
            (4, 2, 0xffffffff, 8_589_934_594), (8, 4, 1, 12),
            (8, 64, 65_536, 4_194_312), (8, 64, 0xffffffff, 274_877_906_888),
        ]
        for base, rate, length, cost in vectors:
            with self.subTest(base=base, rate=rate, length=length):
                calls = []

                def operand():
                    calls.append(length)
                    return length

                site = Site("bulk:0", base, dynamic=(base, rate, operand), output="done")
                self.assertEqual(evaluate(cost - 1, [site]), Result(
                    cost - 1 if length == 0 else cost - 1 - base, "bulk:0", 1))
                self.assertEqual(evaluate(cost, [site]), Result(0, output="done"))
                self.assertEqual(evaluate(cost + 1, [site]), Result(1, output="done"))
                self.assertEqual(len(calls), 2 if length == 0 else 3)

    def test_dynamic_math_overflow_and_growth_order(self):
        count = lambda: (1 << 32) - 1
        # Synthetic coefficients exercise the overflow path even though the
        # largest frozen fuel-v1 coefficient is only 64.
        rate = (1 << 31) + 1
        self.assertEqual(1 + rate * count(), MAX + (1 << 31) + 1)
        for resource in (2, 3):
            blocked = Site("grow:7", 1, resource_code=resource, dynamic=(1, rate, count))
            self.assertEqual(evaluate(MAX, [blocked]), Result(MAX - 1, "grow:7", resource))
        self.assertEqual(evaluate(1, [Site("grow:7", 8, resource_code=2)]),
                         Result(1, "grow:7", 1))
        overflow = Site("grow:7", 1, dynamic=(1, rate, count))
        self.assertEqual(evaluate(MAX, [overflow]), Result(MAX - 1, "grow:7", 1))
        at_max = Site("grow:7", 1, dynamic=(1, MAX - 1, lambda: 1))
        self.assertEqual(evaluate(MAX, [at_max]), Result(0))
        grow_failed = Site("grow:7", 8, dynamic=(8, 64, lambda: 1), output="-1")
        self.assertEqual(evaluate(72, [grow_failed]), Result(0, output="-1"))
        native = Site("bulk:7", 4, dynamic=(4, 1, lambda: 3), native_trap=True)
        self.assertEqual(evaluate(7, [native]), Result(0, "bulk:7", "native"))

    def test_call_order(self):
        for kind in ("direct", "indirect", "external"):
            static = {"direct": 3, "indirect": 5, "external": 1}[kind]
            blocked = Site("call:0", static, call=kind, stack_ok=False, depth_ok=False)
            expected = 9 if kind == "external" else 9 - static
            self.assertEqual(evaluate(9, [blocked]), Result(expected, "call:0", 4))
            depth = Site("call:0", static, call=kind, depth_ok=False)
            self.assertEqual(evaluate(9, [depth]), Result(expected, "call:0", 5))
        invalid = Site("call:0", 5, call="indirect", bad_target=True, stack_ok=False)
        self.assertEqual(evaluate(4, [invalid]), Result(4, "call:0", 1))
        self.assertEqual(evaluate(5, [invalid]), Result(0, "call:0", "native"))


if __name__ == "__main__":
    unittest.main()

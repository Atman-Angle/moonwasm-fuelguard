"""Manually calculated examples for the independent Fuel v2 oracle."""

import unittest

from integration.fuel_oracle.join import Effect, MAX, Op, Result, dynamic_extra, evaluate, spans


class JoinVectors(unittest.TestCase):
    def test_prepaid_native_suffix(self):
        plan = spans(tuple(map(Op, ("i32.const", "i32.load", "global.set", "nop"))), 2)
        path = range(2, 6)
        native = {3: Effect(native=True)}
        self.assertEqual(evaluate(3, plan, path, native), Result(None, 1, 2))
        self.assertEqual(evaluate(6, plan, path, native), Result(None, 1, 2))
        self.assertEqual(evaluate(7, plan, path, native), Result(0, "native", 3))
        self.assertEqual(evaluate(MAX, plan, path, native), Result(MAX - 7, "native", 3))

    def test_control_flow_and_span_length(self):
        linear = (Op("nop"),) * 20
        self.assertEqual([len(s) for s in spans(linear)], [20])
        choice = Op("if", (Op("return"),), (Op("nop"),))
        plan = spans((Op("i32.const"), choice, Op("nop")))
        self.assertEqual([len(s) for s in plan], [2, 1, 2])
        self.assertEqual(evaluate(3, plan, (1, 2, 4, 5)), Result(None, 1, 4))
        target = Op("if", (Op("br", labels=(0,)),), (Op("nop"),))
        self.assertEqual([len(s) for s in spans((Op("i32.const"), target, Op("nop")))],
                         [2, 1, 1, 1])

    def test_resource_before_dynamic_fee_and_native(self):
        plan = spans((Op("memory.grow"),))
        blocked = {1: Effect(count=-1, current=1, limit=2, native=True)}
        self.assertEqual(evaluate(7, plan, (1,), blocked), Result(None, 1, 1))
        self.assertEqual(evaluate(8, plan, (1,), blocked), Result(0, 2, 1))
        self.assertEqual(evaluate(71, plan, (1,), {1: Effect(count=1)}), Result(63, 1, 1))
        self.assertEqual(evaluate(72, plan, (1,), {1: Effect(count=1)}), Result(0))

    def test_dead_then_tail_cannot_split_the_live_else(self):
        choice = Op("if", (Op("return"), Op("nop")), (Op("i32.const"), Op("global.set")))
        plan = spans((Op("local.get"), choice, Op("nop")), 2)
        self.assertEqual([len(s) for s in plan], [2, 1, 1, 3])
        self.assertEqual(evaluate(5, plan, (2, 3, 6, 7, 8), {7: Effect(output="7")}),
                         Result(None, 1, 6))

    def test_relative_arm_reachability_and_dead_transfers(self):
        tails = (
            (Op("return"), Op("nop")),
            (Op("return"), Op("i32.const"), Op("br_if", labels=(1,))),
            (Op("block", (Op("return"), Op("br", labels=(0,)))), Op("nop")),
            (Op("return"), Op("memory.fill")),
        )
        # The whole if may be lexically dead and still needs a correct table.
        for tail in tails:
            choice = Op("if", tail, (Op("i32.const"), Op("global.set")))
            for prologue in ((Op("i32.const"),), (Op("return"), Op("i32.const"))):
                with self.subTest(tail=tail, prologue=prologue):
                    plan = spans((*prologue, choice, Op("nop")))
                    self.assertEqual([op.key for _, op in plan[-1]],
                                     ["i32.const", "global.set", "nop"])

    def test_dead_lexical_block_continuation(self):
        block = Op("block", (Op("return"), Op("nop")))
        plan = spans((block, Op("nop")))
        self.assertEqual([len(span) for span in plan], [2, 2])

    def test_mathematical_i64_bound(self):
        self.assertEqual(dynamic_extra(8, MAX - 8, 1, MAX - 8), MAX - 8)
        self.assertIsNone(dynamic_extra(8, MAX - 7, 1, MAX - 8))
        self.assertIsNone(dynamic_extra(8, MAX - 8, 1, MAX - 9))
        for invalid in (0, -1, MAX + 1):
            with self.assertRaises(ValueError):
                evaluate(invalid, (), ())

    def test_callee_preserves_outer_predebit(self):
        caller = spans((Op("call"), Op("nop")), 2)
        callee = spans((Op("i32.const"), Op("i32.load")), 4)
        effects = {2: Effect(callee=(4, 5)), 5: Effect(native=True)}
        self.assertEqual(evaluate(7, caller + callee, (2, 3), effects), Result(None, 1, 4))
        self.assertEqual(evaluate(8, caller + callee, (2, 3), effects), Result(0, "native", 5))

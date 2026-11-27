"""Named deterministic scenarios. Expected values are declared as WAST assertions."""

from dataclasses import dataclass

from integration.stack_pass.check import invoke, returns


@dataclass(frozen=True)
class Case:
    name: str
    fixture: str
    checks: tuple[str, ...]


def i32(export, value, *args):
    return returns(invoke(export, *args), ("i32", value))


def get(export, value):
    return returns(f'(get "{export}")', ("i32", value))


def call(export, *args):
    return returns(invoke(export, *args))


def trap(export, message, *args):
    return f'(assert_trap {invoke(export, *args)} "{message}")'


def refs(export, operands, *expected):
    return returns(f'(invoke "{export}" {operands})', *expected)


def group(fixture, rows):
    return tuple(Case(name, fixture, tuple(checks)) for name, *checks in rows)


CONTROL = group("control", [
    ("core-start-writes-state", get("trace", 42)),
    ("if-zero-selects-else", i32("branch", 11, 0)),
    ("if-positive-selects-then", i32("branch", 7, 1)),
    ("if-negative-is-true", i32("branch", 7, -1)),
    ("br-table-first", i32("switch", 10, 0)),
    ("br-table-second", i32("switch", 20, 1)),
    ("br-table-default", i32("switch", 30, 2)),
    ("br-table-unsigned-default", i32("switch", 30, -1)),
    ("nested-skip-outer", i32("nested", 0, 0, 3)),
    ("nested-skip-inner", i32("nested", 0, 3, 0)),
    ("nested-single-backedge", i32("nested", 1, 1, 1)),
    ("nested-independent-indices", i32("nested", 30, 3, 4)),
    ("recursion-even-base", i32("even", 1, 0)),
    ("recursion-odd-base", i32("odd", 0, 0)),
    ("recursion-even-two-frames", i32("even", 0, 1)),
    ("recursion-odd-deep", i32("odd", 1, 31)),
    ("indirect-even-slot", i32("indirect", 1, 4, 0)),
    ("indirect-odd-slot", i32("indirect", 1, 3, 1)),
    ("pair-early-return", returns(invoke("pair", -3), ("i32", -3), ("i64", -7))),
    ("pair-export-alias", returns(invoke("pair_alias", 4), ("i32", 4), ("i64", -7))),
    ("pair-direct-call", returns(invoke("call_pair", 8), ("i32", 8), ("i64", -7))),
    ("typed-branch-fallthrough", returns(invoke("typed_branch", 0), ("i32", 23), ("i64", 29))),
    ("typed-branch-taken", returns(invoke("typed_branch", 1), ("i32", 17), ("i64", 19))),
    ("sequential-wrapper-restores-budget",
     i32("even", 1, 30), i32("odd", 1, 31), i32("indirect", 1, 30, 0)),
])

MEMORY = group("memory", [
    ("active-data-first-byte", i32("read", 97, 0)),
    ("active-data-little-endian", i32("word", 0x64636261, 0)),
    ("uninitialized-memory-is-zero", i32("read", 0, 4)),
    ("fill-zero-at-end", call("fill", 65536, 90, 0), get("evaluations", 1), i32("read", 97, 0)),
    ("fill-one-byte-once", call("fill", 2, 90, 1), get("evaluations", 1), i32("word", 0x645A6261, 0)),
    ("fill-masks-to-byte", call("fill", 0, 0x141, 4), i32("word", 0x41414141, 0)),
    ("fill-last-byte", call("fill", 65535, 81, 1), i32("read", 81, 65535)),
    ("fill-entire-page", call("fill", 0, 63, 65536), i32("read", 63, 0), i32("read", 63, 65535)),
    ("copy-overlap-right", call("copy", 1, 0, 3), i32("word", 0x63626161, 0)),
    ("copy-overlap-left", call("copy", 0, 1, 3), i32("word", 0x64646362, 0)),
    ("copy-zero-at-end", call("copy", 65536, 65536, 0), i32("word", 0x64636261, 0)),
    ("init-passive-entire", call("init", 0, 0, 4), i32("word", 0x53525150, 0)),
    ("init-passive-subrange", call("init", 2, 1, 2), i32("word", 0x52516261, 0)),
    ("init-zero-at-segment-end", call("init", 0, 4, 0), i32("word", 0x64636261, 0)),
    ("drop-passive-idempotent", call("drop_data"), call("drop_data"), call("init", 0, 0, 0)),
    ("memory-size-initial", i32("pages", 1)),
    ("memory-grow-zero", i32("grow", 1, 0), i32("pages", 1)),
    ("memory-grow-exact", i32("grow", 1, 1), i32("pages", 2), i32("read", 0, 65536)),
    ("memory-grow-declared-max", i32("grow", -1, 2), i32("pages", 1)),
])

EXTERN = group("extern", [
    ("table-size-initial", i32("size", 1)),
    ("table-default-null", i32("null_at", 1, 0)),
    ("table-grow-zero", i32("grow_null", 1, 0), i32("size", 1)),
    ("table-grow-exact-null", i32("grow_null", 1, 1), i32("null_at", 1, 1)),
    ("table-grow-exact-reference", refs("grow_value", "(ref.extern 7) (i32.const 1)", ("i32", 1)),
     '(assert_return (invoke "get" (i32.const 1)) (ref.extern 7))'),
    ("table-grow-declared-max", i32("grow_null", -1, 2), i32("size", 1)),
    ("table-set-read-reference", refs("set", "(i32.const 0) (ref.extern 11)"),
     '(assert_return (invoke "get" (i32.const 0)) (ref.extern 11))'),
    ("table-set-back-to-null", refs("set", "(i32.const 0) (ref.extern 11)"),
     refs("set", "(i32.const 0) (ref.null extern)"), i32("null_at", 1, 0)),
    ("ref-is-null", refs("is_null", "(ref.null extern)", ("i32", 1))),
    ("ref-is-not-null", refs("is_null", "(ref.extern 5)", ("i32", 0))),
    ("table-fill-reference", refs("fill", "(i32.const 0) (ref.extern 8) (i32.const 1)"),
     '(assert_return (invoke "get" (i32.const 0)) (ref.extern 8))'),
    ("table-fill-zero-at-end", refs("fill", "(i32.const 1) (ref.extern 8) (i32.const 0)"),
     i32("null_at", 1, 0)),
    ("table-copy-reference", i32("grow_null", 1, 1),
     refs("set", "(i32.const 0) (ref.extern 8)"), call("copy", 1, 0, 1),
     '(assert_return (invoke "get" (i32.const 1)) (ref.extern 8))'),
    ("table-init-passive", refs("set", "(i32.const 0) (ref.extern 8)"),
     call("init", 0, 0, 1), i32("null_at", 1, 0)),
    ("table-drop-passive", call("drop_element"), call("drop_element"), call("init", 0, 0, 0)),
])

NUMERIC = group("numeric", [
    ("add-wraps-i32", i32("add32", -2147483648, 2147483647, 1)),
    ("divide-rounds-toward-zero", i32("divide", -2, -7, 3)),
    ("shift-i64-masks-count", refs("shift64", "(i64.const -1) (i64.const 65)", ("i64", 9223372036854775807))),
    ("nearest-even-lower", refs("nearest", "(f32.const 2.5)", ("f32", 2))),
    ("nearest-even-upper", refs("nearest", "(f32.const 3.5)", ("f32", 4))),
    ("defined-f64-negative-zero", returns(invoke("global_bits"), ("i64", -9223372036854775808))),
    ("defined-f64-literal-bits", returns(invoke("literal_bits"), ("i64", -2251799813685182))),
    ("defined-f64-set-get", refs("global_add", "(f64.const -2)", ("f64", -0.5)),
     returns(invoke("global_bits"), ("i64", -4620693217682128896))),
    ("select-zero", i32("choose", 20, 10, 20, 0)),
    ("select-nonzero", i32("choose", 10, 10, 20, -1)),
    ("sign-extend-byte", i32("signed_byte", -128, 0x180)),
])

STRICT = CONTROL + MEMORY + EXTERN + NUMERIC

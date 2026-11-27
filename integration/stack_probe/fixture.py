"""Generate a fixed-shape stack probe and its unguarded reference."""

FRAME_BASE = 128
SLOT = 16
ENTRY = 512
WRAPPER = 128
HELPER = 128


def frame_cost(locals_count, peak):
    # Include the live wrapper, a pending wrapper, the cold helper chain and scratch.
    return FRAME_BASE + SLOT * (locals_count + peak + 6) + 2 * WRAPPER + 3 * HELPER


def module(path, depth, locals_count, peak, budget=None, depth_limit=100000, lifecycle=False):
    guarded = budget is not None
    indirect = path == "indirect"
    start = path == "start"
    cost = frame_cost(locals_count, peak)
    table_target = "$wrap_b" if guarded else "$b"
    start_target = "$wrap_boot" if guarded else "$boot"
    export_target = "$wrap_entry" if guarded else "$entry"

    def reserve(amount):
        return f"i64.const {amount} call $reserve" if guarded else ""

    def release(amount):
        return f"i64.const {amount} call $release" if guarded else ""

    def call_other(name):
        if indirect and name == "b":
            return "i32.const 0 call_indirect (type $pair)"
        return f"{reserve(cost)} call ${name} {release(cost)}"

    def body(name, other):
        declarations = " ".join(f"(local $v{i} i64)" for i in range(locals_count))
        initialize = " ".join(
            f"i32.const {256 + 8 * i} i64.load local.set $v{i}"
            for i in range(locals_count)
        )
        park = " ".join(f"i32.const {64 + 4 * i} i32.load" for i in range(peak))
        sum_locals = " ".join(
            f"local.get $v{i} i32.wrap_i64 i32.add" for i in range(locals_count)
        )
        return f"""
          (func ${name} (type $pair) (param $n i32) (result i32 i32)
            (local $first i32) (local $second i32) {declarations}
            {"global.get $visits i32.const 1 i32.add global.set $visits" if lifecycle else ""}
            {initialize}
            local.get $n i32.eqz
            if i32.const 7 i32.const 11 return end
            {park}
            local.get $n i32.const 1 i32.sub {call_other(other)}
            local.set $second local.set $first
            local.get $first {"i32.add " * peak} {sum_locals}
            local.get $second)
        """

    wrappers = ""
    if guarded:
        wrappers = f"""
          (func $wrap_entry (result i32 i32)
            {reserve(ENTRY)} call $entry {release(ENTRY)})
          (func $wrap_boot
            {reserve(ENTRY)} call $boot {release(ENTRY)})
          (func $wrap_b (type $pair) (param $n i32) (result i32 i32)
            local.get $n {reserve(cost)} call $b {release(cost)})
          (func $emit (param $address i32)
            i32.const 0 local.get $address i32.store
            i32.const 4 i32.const 8 i32.store
            i32.const 1 i32.const 0 i32.const 1 i32.const 8 call $write drop)
          (func $fail (param $code i32) (param $address i32)
            local.get $code global.set $diagnostic
            local.get $address call $emit
            unreachable)
          (func $reserve (param $cost i64)
            local.get $cost global.get $remaining i64.gt_u
            if i32.const 4 i32.const 16 call $fail end
            global.get $active i32.const {depth_limit} i32.ge_u
            if i32.const 5 i32.const 24 call $fail end
            global.get $remaining local.get $cost i64.sub global.set $remaining
            global.get $active i32.const 1 i32.add global.set $active)
          (func $release (param $cost i64)
            global.get $remaining local.get $cost i64.add global.set $remaining
            global.get $active i32.const 1 i32.sub global.set $active)
        """
    root_call = f"i32.const {depth} {reserve(cost)} call $a {release(cost)}"
    # Two calls in one instance make a leaked reservation observable.
    entry_call = f"{root_call} drop drop {root_call}" if not start else (
        "global.get $first_result global.get $second_result"
    )
    if lifecycle:
        # In the same instance, prove both calls returned before attempting a third.
        entry_call += f"""
          drop drop
          global.get $visits i32.const {2 * (depth + 1)} i32.ne
          global.get $remaining i64.const {budget - ENTRY} i64.ne i32.or
          global.get $active i32.const 1 i32.ne i32.or
          if unreachable end
          i32.const 32 call $emit
          i32.const {depth + 1} {reserve(cost)} call $a {release(cost)}
        """
    data = r"\01\00\00\00" * peak
    # S25: i64 locals load 8-byte strides; each slot must read 1 for the per-local sum.
    vector_data = (r"\01" + r"\00" * 7) * locals_count
    markers = r"stack:4\0adepth:5\0aready:2\0a"
    return f"""
      (module
        (type $pair (func (param i32) (result i32 i32)))
        (import "wasi_snapshot_preview1" "fd_write" (func $write
          (param i32 i32 i32 i32) (result i32)))
        (memory (export "memory") 2)
        (table 1 1 funcref)
        (elem (i32.const 0) {table_target})
        (global $remaining (mut i64) (i64.const {budget or 0}))
        (global $active (mut i32) (i32.const 0))
        (global $diagnostic (export "__moonwasm_trap_code") (mut i32) (i32.const 0))
        (global $first_result (mut i32) (i32.const 0))
        (global $second_result (mut i32) (i32.const 0))
        (global $visits (mut i32) (i32.const 0))
        (data (i32.const 16) "{markers}")
        (data (i32.const 64) "{data}")
        (data (i32.const 256) "{vector_data}")
        {body("a", "b")}
        {body("b", "a")}
        (func $entry (result i32 i32) {entry_call})
        (func $boot {root_call}
          global.set $second_result global.set $first_result)
        (func $check (export "check") (result i32 i32)
          call {export_target}
          global.get $remaining i64.const {budget or 0} i64.ne
          global.get $active i32.or global.get $diagnostic i32.or
          if unreachable end)
        {wrappers}
        (export "entry" (func {export_target}))
        {f"(start {start_target})" if start else ""}
      )
    """

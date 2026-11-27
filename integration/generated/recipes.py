"""Deterministic, typed WebAssembly recipes and independent expected behavior."""

import hashlib
from dataclasses import dataclass, replace

VERSION = "fuelguard-generated-v1"
SEED = 170026
JOIN_VERSION = "fuelguard-generated-v2"
JOIN_SEED = 270019
JOIN_LAYOUTS = ("join-span", "join-span-cached", "join-span-compact", "join-span-compact-v2")
FUEL_V2 = "fuel-v2"
SPAN_LAYOUTS = (*JOIN_LAYOUTS, FUEL_V2)
COUNT = 10_000
CAPS = {"stack_units": 100_000, "call_depth": 64, "memory_pages": 2, "table_elements": 2}
FUEL = 100_000


@dataclass(frozen=True)
class Trial:
    wat: str
    values: tuple[tuple[str, int], ...]
    fuel: int = FUEL
    code: int | None = None
    site: int | None = None
    prefix: int | None = None
    protected_prefix: int | None = None


def signed32(value):
    return (value + (1 << 31)) % (1 << 32) - (1 << 31)


def scalar(salt, n, mutated):
    ops = ("i32.mul i32.const 7 i32.xor" if mutated else "i32.add")
    value = salt
    for i in range(1, n + 1):
        value = (value * i) ^ 7 if mutated else value + i
    body = "\n".join(f"i32.const {i} {ops}" for i in range(1, n + 1))
    return Trial(f'(module (func (export "run") (result i32) i32.const {salt} {body}))',
                 (("i32", signed32(value)),))


def branch(salt, n, mutated):
    flag = n % 2
    a, b = (salt + n, salt - n) if mutated else (salt - n, salt + n)
    return Trial(f"""(module (func (export "run") (result i32 i64)
        i32.const {flag} if (result i32 i64)
          i32.const {a} i64.const {n}
        else
          i32.const {b} i64.const {-n}
        end))""", (("i32", signed32(a if flag else b)), ("i64", n if flag else -n)))


def loop(salt, n, mutated):
    stride = 2 if mutated else 1
    return Trial(f"""(module (func (export "run") (result i32) (local $n i32) (local $acc i32)
        i32.const {n} local.set $n
        i32.const {salt} local.set $acc
        block $done
          loop $again
            local.get $n i32.eqz br_if $done
            local.get $acc local.get $n i32.const {stride} i32.mul i32.add local.set $acc
            local.get $n i32.const 1 i32.sub local.set $n br $again
          end
        end
        local.get $acc))""", (("i32", signed32(salt + stride * n * (n + 1) // 2)),))


def direct(salt, n, mutated):
    step = 3 if mutated else 1
    return Trial(f"""(module
      (func $rec (param i32) (result i32)
        local.get 0 i32.eqz if i32.const {salt} return end
        local.get 0 i32.const 1 i32.sub call $rec i32.const {step} i32.add)
      (func (export "run") (result i32) i32.const {n} call $rec))""",
                 (("i32", signed32(salt + step * n)),))


def indirect(salt, n, mutated):
    slot = 1 if mutated else 0
    elements = "$left $right" if mutated else "$right $left"
    return Trial(f"""(module
      (type $t (func (param i32) (result i32)))
      (table 2 2 funcref)
      (elem (i32.const 0) func {elements})
      (func $left (type $t) local.get 0 i32.const {-n} i32.add)
      (func $right (type $t) local.get 0 i32.const {n} i32.add)
      (func (export "run") (result i32)
        i32.const {salt} i32.const {slot} call_indirect (type $t)))""",
                 (("i32", signed32(salt + n)),))


def bulk(salt, n, mutated):
    # Copy overlapping bytes in opposite directions after passive initialization.
    dest, source = (0, 1) if mutated else (1, 0)
    byte = 65 + n
    return Trial(f"""(module (memory 1 2) (data $bytes "abcdefghi")
      (func (export "run") (result i32)
        i32.const 0 i32.const 0 i32.const 9 memory.init $bytes data.drop $bytes
        i32.const {dest} i32.const {source} i32.const {n} memory.copy
        i32.const 20 i32.const {byte} i32.const {n} memory.fill
        i32.const {salt} i32.const {dest} i32.load8_u i32.xor
        i32.const 20 i32.load8_u i32.add))""",
                 (("i32", signed32((salt ^ (97 + source)) + byte)),))


def extern(salt, n, mutated):
    copy = "i32.const 1 i32.const 0 i32.const 1 table.copy" if mutated else ""
    index = 1 if mutated else 0
    return Trial(f"""(module (table 1 2 externref)
      (func (export "run") (result i32)
        ref.null extern i32.const 1 table.grow drop
        {copy}
        i32.const {index} table.get ref.is_null i32.const {salt} i32.xor))""",
                 (("i32", signed32(salt ^ 1)),))


def simd(salt, n, mutated):
    lane = n % 4
    vector = "v128.load i32.const 1 i16x8.splat v128.or" if mutated else "v128.load"
    data = "".join(f"\\{byte:02x}" for i in range(4)
                   for byte in ((salt + i) % (1 << 32)).to_bytes(4, "little"))
    value = salt + lane
    if mutated:
        value |= 0x00010001
    return Trial(f"""(module (memory 1 1) (data (i32.const 0) "{data}")
      (func (export "run") (result i32)
        i32.const 0 {vector} i32x4.extract_lane {lane}))""",
                 (("i32", signed32(value)),))


def fuel_limit(salt, n, mutated):
    op = "i32.xor" if mutated else "i32.add"
    expected = salt ^ n if mutated else salt + n
    return Trial(f"""(module (global $trace (export "trace") (mut i32) (i32.const 0))
      (func (export "run") (result i32)
        i32.const {salt} global.set $trace
        i32.const {salt} i32.const {n} {op}))""",
                 (("i32", signed32(expected)),), fuel=3, code=1, site=4, prefix=salt)


def joined_barriers(salt, n, mutated):
    # The store and global write must both be suppressed when the final
    # load cannot be paid. Vary the address and whether the budget is exact.
    cost = 12
    return Trial(f"""(module (memory 1 2)
      (global $trace (export "trace") (mut i32) (i32.const 0))
      (func (export "run") (result i32)
        i32.const {salt} global.set $trace
        i32.const {n} i32.const {salt} i32.store align=1
        i32.const {n} i32.load align=1))""",
                 (("i32", salt),), fuel=cost if mutated else cost - 1,
                 code=None if mutated else 1, site=None if mutated else 8,
                 prefix=salt)


def joined_else(salt, n, mutated):
    # Then terminates. Only the explicit else can fall through to i32.add.
    return Trial(f"""(module
      (func (export "run") (result i32)
        i32.const {int(mutated)}
        if (result i32) i32.const {salt} return
        else i32.const {salt + n} end
        i32.const {n} i32.add))""",
                 (("i32", salt if mutated else salt + 2 * n),), fuel=4,
                 code=None if mutated else 1, site=None if mutated else 8)


def memory_limit(salt, n, mutated):
    delta = -1 if mutated else 2 + n
    return Trial(f"""(module (memory 1 2) (global $trace (export "trace") (mut i32) (i32.const 0))
      (func (export "run") (result i32)
        i32.const {salt} global.set $trace i32.const {delta} memory.grow))""",
                 (("i32", -1),), code=2, site=5, prefix=salt)


def table_limit(salt, n, mutated):
    delta = -1 if mutated else 2 + n
    return Trial(f"""(module (table 1 2 externref)
      (global $trace (export "trace") (mut i32) (i32.const 0))
      (func (export "run") (result i32)
        i32.const {salt} global.set $trace ref.null extern i32.const {delta} table.grow))""",
                 (("i32", -1),), code=3, site=6, prefix=salt)


# S25: the simd family moved to rejection cases (production-v1 refuses SIMD).
FAMILIES = (scalar, branch, loop, direct, indirect, bulk, extern, fuel_limit,
            memory_limit, table_limit)
JOIN_FAMILIES = FAMILIES + (joined_barriers, joined_else)


@dataclass(frozen=True)
class Recipe:
    seed: int
    index: int
    family: str
    salt: int
    size: int
    mutated: bool

    @property
    def case_id(self):
        return f"g{self.index:05d}"

    def trial(self, codegen="p0"):
        trial = next(fn for fn in JOIN_FAMILIES if fn.__name__ == self.family)(
            self.salt, self.size, self.mutated)
        if codegen == FUEL_V2 and trial.code == 1:
            first_site = 6 if self.family == "joined_else" else 2
            return replace(trial, site=first_site,
                           protected_prefix=0 if trial.prefix is not None else None)
        if codegen in JOIN_LAYOUTS and self.family in ("fuel_limit", "joined_barriers"):
            # An unaffordable span executes no source side effects.
            return replace(trial, protected_prefix=0 if trial.code else trial.prefix)
        return trial


def generate(seed, index, codegen="p0"):
    if not 0 <= index < COUNT:
        raise ValueError(f"index must be in [0, {COUNT})")
    seed_bytes = str(seed).encode("ascii")
    key = int.from_bytes(hashlib.sha256(seed_bytes).digest()[:4], "little") & 0x3fffffff
    salt = key ^ (index * 65537)
    shape = hashlib.sha256(f"{seed}:{index}".encode("ascii")).digest()[0]
    families = JOIN_FAMILIES if codegen in SPAN_LAYOUTS else FAMILIES
    return Recipe(seed, index, families[index % len(families)].__name__,
                  salt, 2 + shape % 6, bool(index // len(families) % 2))

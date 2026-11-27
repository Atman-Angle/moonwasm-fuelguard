"""Independent evaluator for hand-authored canonical site traces."""

from dataclasses import dataclass
from typing import Callable, Iterable

MAX = (1 << 63) - 1


@dataclass(frozen=True)
class Site:
    site: str
    static: int
    # None, direct, indirect, or external. External entry precedes static debit.
    call: str | None = None
    bad_target: bool = False
    stack_ok: bool = True
    depth_ok: bool = True
    resource_code: int = 0
    dynamic: tuple[int, int, Callable[[], int]] | None = None
    native_trap: bool = False
    output: str = ""


@dataclass(frozen=True)
class Result:
    remaining: int
    site: str | None = None
    failure: int | str | None = None
    output: str = ""


def evaluate(budget: int, trace: Iterable[Site]) -> Result:
    if not 1 <= budget <= MAX:
        raise ValueError("invalid i64 fuel budget")
    prefix = []
    for event in trace:
        def failure(reason):
            return Result(budget, event.site, reason, "".join(prefix))

        def reserve():
            if not event.stack_ok:
                return failure(4)
            if not event.depth_ok:
                return failure(5)
            return None

        if event.call == "external" and (error := reserve()):
            return error
        if event.static > budget:
            return failure(1)
        budget -= event.static
        if event.call == "indirect" and event.bad_target:
            return failure("native")
        if event.call in ("direct", "indirect") and (error := reserve()):
            return error
        # Source argument evaluation happens before the guard. Its value is saved.
        count = event.dynamic[2]() if event.dynamic else 0
        if event.resource_code:
            return failure(event.resource_code)
        if event.dynamic:
            base, per_unit, _ = event.dynamic
            total = base + per_unit * count  # Unbounded arithmetic is intentional.
            extra = total - base
            if total > MAX or extra > budget:
                return failure(1)
            budget -= extra
        if event.native_trap:
            return failure("native")
        prefix.append(event.output)
    return Result(budget, output="".join(prefix))

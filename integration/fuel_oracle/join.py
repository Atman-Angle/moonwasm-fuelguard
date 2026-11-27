"""Fuel v2 oracle for structured source traces.

Source fixtures supply branch choices and observable effects. The oracle
derives source sites, builds the control-flow graph and computes prepayment
without reading MoonBit rules, profile words, Wasm output or its manifest.
"""

from collections import defaultdict
from dataclasses import dataclass

from integration.fuel_oracle.oracle import MAX


# Contract weights for the opcodes used by the independent fixtures.
WEIGHTS = {
    **dict.fromkeys(("nop", "drop", "i32.const", "i64.const", "local.get",
                     "local.set", "i32.add", "i32.sub", "i32.eqz", "global.get",
                     "ref.null", "block", "loop", "if", "br", "br_if",
                     "return", "unreachable"), 1),
    **dict.fromkeys(("br_table", "global.set", "data.drop", "elem.drop",
                     "memory.size", "table.size"), 2),
    **dict.fromkeys(("call", "i32.load", "i32.store", "i32.load8_u", "table.get"), 3),
    "i32.div_s": 4,
    "call_indirect": 5,
}
# (static base, unit rate, resource diagnostic)
DYNAMIC = {
    **dict.fromkeys(("memory.copy", "memory.fill", "memory.init"), (4, 1, 0)),
    **dict.fromkeys(("table.copy", "table.fill", "table.init"), (4, 2, 0)),
    "memory.grow": (8, 64, 2),
    "table.grow": (8, 4, 3),
}
END_SPAN = {"if", "loop", "br", "br_if", "br_table", "return", "unreachable"}


@dataclass(frozen=True)
class Op:
    key: str
    body: tuple = ()
    otherwise: tuple | None = None
    labels: tuple[int, ...] = ()

    @property
    def weight(self):
        return DYNAMIC[self.key][0] if self.key in DYNAMIC else WEIGHTS[self.key]


def spans(body, first=1):
    """Partition numbered source operations along linear control-flow edges."""
    source = {}
    edges = defaultdict(set)
    target_sites = set()
    ends = {}
    joins = []

    def number(nodes):
        numbered = []
        for node in nodes:
            site = first + len(source)
            source[site] = node
            numbered.append((site, number(node.body), number(node.otherwise or ())))
            ends[site] = first + len(source)
        return numbered

    def wire(nodes, after, labels):
        for i, (site, body, other) in enumerate(nodes):
            successor = nodes[i + 1][0] if i + 1 < len(nodes) else after
            child = body[0][0] if body else successor
            key = source[site].key
            if key in ("br", "br_if", "br_table"):
                targets = {labels[-1 - depth] for depth in source[site].labels}
                edges[site].update(targets)
                for _, owner in targets:
                    if owner is not None and source[owner].key in ("block", "if"):
                        target_sites.add(ends[owner])
                if key == "br_if":
                    edges[site].add((successor, None))
            elif key in ("return", "unreachable"):
                continue
            elif key in ("block", "loop", "if"):
                edges[site].add((child, None))
                if key == "if":
                    edges[site].add((other[0][0] if other else successor, None))
                    if body and other:
                        joins.append((range(body[0][0], ends[body[-1][0]]), successor, ends[site]))
                    else:
                        target_sites.add(ends[site])
                label = (child if key == "loop" else successor, site)
                wire(body, successor, (*labels, label))
                wire(other, successor, (*labels, label))
            else:
                edges[site].add((successor, None))

    wire(number(body), None, ((None, None),))
    # Distinct lexical labels may resolve to the same first executed site.
    # A branch to an enclosing label does not fall through the then arm.
    for arm, successor, boundary in joins:
        visited = set()
        work = [arm.start]
        while work:
            site = work.pop()
            if site == successor:
                target_sites.add(boundary)
                break
            if site not in arm or site in visited:
                continue
            visited.add(site)
            work.extend(target for target, owner in edges[site] if owner is None or owner in arm)

    result = []
    for site, node in source.items():
        previous = site - 1
        if (not result or site in target_sites or
                source[previous].key in END_SPAN or
                {target for target, _ in edges[previous]} != {site}):
            result.append([])
        result[-1].append((site, node))
    return tuple(tuple(span) for span in result)


@dataclass(frozen=True)
class Effect:
    count: int = 0
    current: int = 0
    limit: int | None = None
    native: bool = False
    stack: bool = True
    depth: bool = True
    output: str = ""
    callee: tuple[int, ...] = ()


@dataclass(frozen=True)
class Result:
    remaining: int | None
    failure: int | str | None = None
    site: int | None = None
    output: str = ""


def dynamic_extra(base, rate, count, remaining):
    extra = rate * count
    return extra if base + extra <= MAX and extra <= remaining else None


def evaluate(budget, plan, path, effects=None):
    """Evaluate the selected instruction path, including repeated span entries."""
    if not 1 <= budget <= MAX:
        raise ValueError("invalid i64 fuel budget")
    return execute(budget, {span[0][0]: span for span in plan}, path, effects or {})


def execute(budget, starts, path, effects):
    output = ""
    pending = []
    for site in path:
        if not pending:
            span = starts[site]
            charge = sum(node.weight for _, node in span)
            if charge > budget:
                # The trap ABI exposes the site, not the cached failed debit.
                return Result(None, 1, span[0][0], output)
            budget -= charge
            pending = list(reversed(span))
        expected, node = pending.pop()
        if site != expected:
            raise ValueError(f"path left a prepaid span before site {expected}")
        effect = effects.get(site, Effect())
        if node.key == "call_indirect" and effect.native:
            return Result(budget, "native", site, output)
        if node.key in ("call", "call_indirect"):
            if not effect.stack:
                return Result(budget, 4, site, output)
            if not effect.depth:
                return Result(budget, 5, site, output)
        if node.key in DYNAMIC:
            base, rate, resource = DYNAMIC[node.key]
            count = effect.count & 0xffffffff
            if resource and effect.limit is not None and effect.current + count > effect.limit:
                return Result(budget, resource, site, output)
            extra = dynamic_extra(base, rate, count, budget)
            if extra is None:
                return Result(budget, 1, site, output)
            budget -= extra
        if effect.native or node.key == "unreachable":
            return Result(budget, "native", site, output)
        output += effect.output
        if effect.callee:
            called = execute(budget, starts, effect.callee, effects)
            budget = called.remaining
            output += called.output
            if called.failure is not None:
                return Result(budget, called.failure, called.site, output)
    if pending:
        raise ValueError("trace ended inside a prepaid span")
    return Result(budget, output=output)

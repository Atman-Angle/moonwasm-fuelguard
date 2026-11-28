# FuelGuard acceptance

This entry runs the correctness, generated and rejection checks for the
production Fuel v2 layout. The production criteria and current evidence are
in the [v4 specification](../../docs/14_FuelGuard生产规格_v4.md) and [S35](../../docs/evidence/S35.md).

Use an x86_64 Linux checkout with Python 3.10+, the MoonBit toolchain, and the
pinned [runtime tools](../runtime/README.md). On WSL2, put the checkout and its
build directory on the Linux filesystem. The correctness group also builds the
native runner and uses `cc` and `prlimit`. The delivery group runs real
EACCES/ENOSPC tests as root in a private mount namespace using util-linux.

```bash
python3 -B integration/acceptance/check.py
python3 -B integration/acceptance/check.py --group correctness --group generated --group rejections
```

The default selects all gate groups and uses the Fuel v2 layout. Select groups
with repeated `--group` arguments. The gate IDs below are retained for evidence
lookup. For archived layouts use the source in the [S29 archive](../../docs/evidence/S29.md).

| Group | Gates |
| --- | --- |
| `correctness` | A01–A13, A16, A23 |
| `generated` | A14 |
| `rejections` | A15 |
| `delivery` | A21 |
| `performance` | The unified checker leaves these IDs pending. Use the [benchmark runner](../../bench/README.md#fuel-v2-tuning-and-independent-acceptance) for A17/A19 and the separate A20 diagnostic. |
| `release` | A22 and A24, pending packaging and final independent replay |

Each run creates a directory below `_build/s17/`. Use `--out` with a new
directory to choose its location. `report.json` has the candidate source
hashes, tool versions, gate results, commands, exit codes, and evidence digests.
Checks with raw artifacts receive their own directories inside the report run,
so later runs retain the earlier case files.
The top-level `status` and exit code refer to the selected groups. `overall`
refers to all 24 gates. Exit 0 means every selected gate passed, exit 1 means a
selected check failed, and exit 2 means setup blocked execution or a selected
gate is pending. Failures take precedence over blocked and pending gates.

## Generated corpus

A14 uses the frozen seed `270019`, with recipes
`g00000`–`g09999`. Generated and mutated
recipes cover arithmetic, multi-value branches, loops, recursion, fixed-table
indirect calls, passive data and bulk memory, externref tables, and
deliberate Fuel/growth limits. Each mutation changes a guest operand, operation,
or table/control-flow arrangement. The recipes compute expected values and trap
coordinates in Python. The MoonBit worker uses the same decode, built-in
production pipeline, and encode APIs as the CLI. A15 exercises the actual file
CLI, including its no-publication contract and the SIMD refusals.
The low-budget barrier and unique-fallthrough families check the first site
of the prepaid span and the output prefix. Each validated artifact must carry
the Fuel v2 marker. The frozen input-set SHA-256 must match.

Each accepted recipe must have a distinct encoded input SHA-256. Both original
and protected binaries are independently validated by wasm-tools and exercised
in wasmoon and Wasmtime. The WAST assertions check deterministic results,
controlled code/site and state prefix where applicable. Timeout prevents a pass.
A failed shard retains its script and streams. For a failure with a usable case
coordinate, the runner replays and attempts grammar reduction of that case.

`generated/cases.jsonl` maps each input hash to its recipe, output hash,
expected/verified observations, and raw artifacts. `generated/summary.json`
gives independent stage totals and a stable digest of the sorted input hashes.
The shard command ledger records the actual batched worker argv. Per-case worker
argv in `cases.jsonl` is the equivalent individual replay. A15 evidence lives in
`rejected/` and has its own counts.

```bash
# Recreate one input and execute both versions in both engines.
python3 -B integration/generated/check.py replay --seed 270019 --index 19

# Reproduce and shrink a failing recipe. View reduction.json and the probe WASTs.
python3 -B integration/generated/check.py minimize --seed 270019 --index 19
python3 -B integration/generated/check.py replay --recipe path/to/recipe.json
```

The standalone `run --limit N` command can smoke-test fewer than 10,000
inputs. A passing short run reports `NOT_RUN` for A14 and exits 2. The unified
entry tests its failure path with `--group generated --inject-failure`, which
executes a one-case negative control and deliberately changes the protected
result assertion. That run cannot satisfy A14.

Run `python3 -B integration/acceptance/self_test.py` to exercise the successful
group, failed assertion, missing tool and pending-gate exit paths, then replay
the reduced counterexample with and without the injected expectation. The
self-test also verifies that an outer timeout cleans up a nested subprocess.

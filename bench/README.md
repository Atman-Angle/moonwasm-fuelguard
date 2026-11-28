# FuelGuard tuning benchmarks

These commands reproduce prototype layout comparisons. The current production
acceptance criteria are in [FuelGuard production specification v4](../docs/14_FuelGuard生产规格_v4.md).
Use the historical checkout recorded by each comparison to rebuild its layouts.
The current production CLI generates Fuel v2.

The frozen [dataset](dataset.json) contains the S01 application inputs F0–F3,
two tuning microbenchmarks, three construction scales, and five independent
holdout binaries for S21. The holdout applications vary the inputs or job sizes
of the same workload families. The runner checks their size and SHA-256 when
it reads the manifest. It only constructs and runs entries marked `tuning`.
The application workloads determine the geometric means. The arithmetic
microbenchmarks exercise core start without an export and a repeatable scalar
export. Their timing results are reported separately.

## Run on Linux x86_64

Use MoonBit `0.1.20261104 (940aa18)`, Python 3.12 with NumPy 1.26.4, GCC 13.3,
wasm-tools 1.263.0 and the Wasmtime 50.0.0 CLI and C API distribution.
The wasmoon worker compiles against the Mooncakes 0.18.0 libraries. Use the
[Wasmtime v50 release](https://github.com/bytecodealliance/wasmtime/releases/tag/v50.0.0)
archive `wasmtime-v50.0.0-x86_64-linux-c-api.tar.xz`, SHA-256
`631643d8be5dac2a1abe026528f0ca18a515bce275bcfa7eb9731c9468a592f1`.
The runner checks the shared library hash. It copies the actual workers and
library into the run directory. The Windows host record is a JSON object
with an `ac` Boolean and current `scheme` string from `powercfg /getactivescheme`,
plus the OS build and CPU topology. The reference setup is in the
[S18 evidence](../docs/evidence/S18.md).

```bash
LC_ALL=C python3 -B bench/run.py --out _build/s18-baseline \
  --host-record _build/s18-host.json \
  --wasmtime-c-api /path/to/wasmtime-v50.0.0-x86_64-linux-c-api
python3 -B bench/summarize.py _build/s18-baseline --out _build/s18-report.json
```

Add `--smoke` to a separate run for a short, non-gating trial. If a formal
interval straddles a threshold, use a new sibling output directory with
`--append-to _build/s18-baseline` and summarize the initial and appended
directories in order. This adds three groups to every cell. For an individual borderline interval,
add `--cell ENGINE CASE WINDOW` for each affected cell. Both forms retain
all prior samples. A remaining interval that straddles a threshold fails
the candidate gate.

Use `--build-only` to collect new construction evidence without running
workloads. Pass its directory as `--detailed-build` to the summarizer. This
requires an identical frozen environment and byte-identical variants and
sidecars. The original runtime evidence stays in the baseline directory.

`dataset.py` documents how the supplied bytes were produced. It requires a
fresh output directory and refuses to overwrite the frozen manifest. Keep
the original manifest and bytes for downstream slices. The maximum build
input has 4 MiB, 4,096 functions and 1,048,576 body instructions. It uses
straight-line const/drop pairs and a padding custom section, so the three
scales change all three size dimensions. This measures the named recipe,
including validation and encoding of the padding.

## S19 P0/P1 comparison

Pass `--compare-p1` to interleave original, P0 and P1 in the same independent
processes using the existing frozen schedules, windows and budgets. The
command generates full protection for both candidates and verifies that the
CLI and phased builder produce the same artifact for each candidate. The
report includes paired P1/P0 ratios and the P1 gates against the original.
The S18 original/Fuel-only/P0 invocation remains available.

```bash
LC_ALL=C python3 -B bench/run.py --compare-p1 --out _build/s19-benchmark   --host-record _build/host.json   --wasmtime-c-api /path/to/wasmtime-v50.0.0-x86_64-linux-c-api
python3 -B bench/summarize.py _build/s19-benchmark --out _build/s19-report.json
```

## S20 layout comparison

Use `--compare-layouts` to interleave the original, Fuel-only P0 and full P0,
P1 and P2 in every process. All construction and timing use the frozen tuning
split. The report gives each full layout its own A17, A19 and A20 result.
`performance_eligible` lists layouts that pass all three of those gates.
Default selection also requires A16/A18 correctness evidence. See
[S20](../docs/evidence/S20.md) for the frozen rule and selection record.

```bash
LC_ALL=C python3 -B bench/run.py --compare-layouts --out _build/s20-benchmark \
  --host-record _build/host.json --wasmtime-c-api /path/to/wasmtime-v50.0.0-x86_64-linux-c-api
python3 -B bench/summarize.py _build/s20-benchmark --out _build/s20-report.json
```

`--compare-prefix` runs a tuning pilot interleaving the original, P2 and
`p2-prefix` with 30 timed samples per process. It retains the three processes,
five warm-ups, frozen cases, budgets and windows. The replay report marks the
pilot and does not use it for default selection.

## S26 join-span pilot

`--compare-join-span` interleaves `original`, `p2-prefix`, and `join-span`
on the S25 SIMD-free corpus with the same 30 × 3 protocol. The report includes
the F1 wasmoon hot median ratio and a span-length distribution for each
application and source function. Its S26 threshold is 2.2×.
See the [fuel-v1.2 boundary table](../docs/implementation/fuel-v1.2.md).

```bash
LC_ALL=C python3 -B bench/run.py --compare-join-span --out _build/s26-pilot \
  --host-record _build/host.json --wasmtime-c-api /path/to/wasmtime-v50.0.0-x86_64-linux-c-api
python3 -B bench/summarize.py _build/s26-pilot --out _build/s26-report.json
```

`--compare-join-cached` uses the same tuning corpus, 30 × 3 sampling, and
threshold, with `join-span-cached` added alongside the original, `p2-prefix`,
and the frozen `join-span`. Archive it separately from the S26 baseline.
During replay the two fuel-v1.2 layouts must have identical instruction sites
and span boundaries.

## S28 compact layout pilot

`--compare-join-compact` compares the compact layout, `join-span-cached`
and the original on the same tuning inputs. Add `--build-only` to record the
three construction scales, validate the encoded bytes and verify the manifests
before running a separate timing comparison. S28 interleaves consecutive
construction snapshots so each step has same-process before/after samples.

```bash
LC_ALL=C python3 -B bench/s28.py _build/s28/step2 _build/s28/step3 \
  --host-record _build/host-live.json --out _build/s28/new-pair > _build/s28/new-pair-report.json
LC_ALL=C python3 -B bench/s28.py _build/s28/step2 _build/s28/step3 \
  --out _build/s28/new-pair --replay > _build/s28/new-pair-replay.json
```

For the first step, select the left-hand control with `--before-layout
join-span-cached`. The script checks both construction ledgers, freezes the
workers and exact artifact bytes for each pair, and replays the schedules and
transcripts. Capture the Windows host record immediately before live timing.
The paired run records and checks the host, Linux CPU and clock, affinity and
stack limit. Replay keeps the archived directory names. The report records
lifecycle and hot medians and p95s. An application hot median ratio whose
paired 95% lower bound exceeds 1.02 is a detected rollback signal. An interval
that spans 1.02 is inconclusive. Formal A17 remains a separate gate.

Pass `--frozen-workers /path/to/archived-run` to run with the exact engine
binaries from its ledger. The corpus and Wasmtime library must match. The
archive's environment record and each worker hash are verified during replay.

`--compare-join-compact-v2` interleaves the original, `join-span-compact`
and `join-span-compact-v2` using the same tuning inputs and 30 × 3 pilot.
It records the three construction scales and reports A19 and A20 for both
layouts. The [archived v3 acceptance plan](../docs/09_验证与验收计划.md)
documents the A17 and default-selection procedure used for these comparisons.

## S29 formal layout comparison

`--compare-s29` interleaves the original, Fuel-only P0, full P0/P1/P2,
`p2-prefix`, and all three join-span layouts in every process. It uses the
S25 tuning corpus, the S26 environment lock and the formal 300 × 3 protocol.
The two workers are rebuilt with nine-module capacity. Supplemental runs
reuse the initial run's exact binaries and Wasm artifacts.
Run the following commands from the frozen source snapshot in the [S29 archive](../docs/evidence/S29.md#数据和复现).

```bash
python3 -B bench/run.py --compare-s29 --out _build/s29/initial \
  --s26-environment /path/to/s26-pilot-final/environment.json \
  --host-record _build/host-live.json --wasmtime-c-api /path/to/wasmtime-c-api
python3 -B bench/summarize.py _build/s29/initial --out _build/s29/initial-report.json
```

For a supplemental run, pass `--append-to INITIAL [SUPPLEMENT ...]` with the
previous directories in order. It measures the preceding report's
`borderline_cells`, including every application in any borderline
geometric-mean window. If passing explicit `--cell ENGINE CASE WINDOW` flags,
cover that whole list. Replay the run directories in order to include every
observation. The report includes A17–A20 by layout and retains the A16 checks
and the two model-specific A18 boundary suites.
See [S29](../docs/evidence/S29.md) for the selection decision and archive hashes.

## Fuel v2 tuning and independent acceptance

`--compare-fuel-v2` defaults to tuning. It interleaves original, Fuel-only and
complete protection and emits `tuning_results`. In a tuning report, both
`final_acceptance` entries and `performance_verdict` are `NOT_RUN`, even
when every tuning result passes. [S41](../docs/evidence/S41.md) corrects the
scope of the S37 archive.

After selecting the candidate, use the summarizer to freeze a completed
Fuel v2 tuning run. The freeze binds the proposal, source, layout, actual
CLI/build/runtime binaries, toolchain, dataset and configuration digests.
The instrument CLI's implicit production layout must produce the same Wasm
as the measured builder. Holdout reuses those frozen binaries and verifies
the freeze before selecting the holdout inputs. The report records the test
input hashes and binds the evidence files to the run.

```bash
python3 -B bench/run.py --compare-fuel-v2 --out _build/perf-tuning \
  --host-record _build/host.json \
  --wasmtime-c-api /path/to/wasmtime-v50.0.0-x86_64-linux-c-api
python3 -B bench/summarize.py _build/perf-tuning --out _build/perf-tuning.json \
  --freeze-candidate _build/perf-freeze.json
python3 -B bench/run.py --compare-fuel-v2 --holdout \
  --candidate-run _build/perf-tuning --candidate-lock _build/perf-freeze.json \
  --out _build/perf-holdout --host-record _build/host.json \
  --wasmtime-c-api /path/to/wasmtime-v50.0.0-x86_64-linux-c-api
python3 -B bench/summarize.py _build/perf-holdout --out _build/perf-holdout.json
```

The report applies A17 and A19 to the representative applications. Micros,
compile and construction timings, RSS, Fuel-only and sidecar sizes are
diagnostic measurements. The historical A20 construction limits appear
under `engineering_checks`. `FINAL_PASS` certifies A17 and A19 on holdout.

The historical S55 holdout contains representative applications at or above 10
KiB. For the separate small-size tier, build the production instrumenter and then
run `python3 -B bench/check-small-size.py <instrument.wasm> <new-evidence-dir>`
with the MoonBit 1.0 RC toolchain. The script checks the frozen hash of the
independent scalar MoonBit demo, validates both binaries, verifies the sidecar,
and reports size and byte hashes. Combine both size tiers for proposal sign-off.

For Fuel v2 the 95% percentile intervals resample whole paired processes,
keeping their ordered cycles and all variants together. Tuning retains the
three-process screening design. Holdout uses a fixed 20 processes per
engine/case/window, each with five warm-ups and 300 measured cycles, and
10,000 bootstrap draws. A crossing interval fails to establish the
threshold. The fixed sample size avoids deciding whether to collect more
data after seeing the interval. Coverage is approximate and depends on
the independence of worker processes.

## Windows and statistics

The wasmoon worker reuses a verified native artifact. Wasmtime reuses
a compiled module. A lifecycle observation starts before creating the
instance/store, includes core start execution, and ends at business entry
completion. The workers record instance plus start and entry separately.
The fresh instance closes after each observation. A hot worker initializes
separate instances before timing and retains each instance across its samples.
The timers use Linux `CLOCK_MONOTONIC`. Each short-workload sample is a
fixed-size batch, with reports in ns per lifecycle or call. Exact stdout bytes,
scalar return values, and success/trap status are checked on every sample.
The pure start microbenchmark also asserts its checksum in guest code.
WASI output is captured in process. The Wasmtime C API compile phase includes
its decoding and validation, and wasmoon reports read/parse/validate,
native compilation, and native artifact verification separately.

Each independent process loads every variant in the selected comparison and
runs one seed-permuted order per cycle. Workload, engine, window and process
job order is also seeded. CPU pinning is inherited by every child and workers
execute serially. All measured observations are retained.
`summarize.py` computes pooled medians and p95s using linear interpolation and
takes the ratios of matching quantiles. The geometric mean uses one median
ratio per representative application within an engine and window. The
historical pre-v2 comparisons keep their original replay method, which also
resampled individual interleaved cycles within each drawn process.

Full P0 uses the built-in `inline-per-instruction-v1` path. The phased
native builder and ordinary Wasm CLI must produce the same bytes. The
Fuel-only ablation uses the same static and dynamic charges, including grow
surcharges, and lets the original engine enforce the original Wasm limits
and return the native grow result. Its artifact carries no production marker.
CLI process wall time and RSS include output publication. Application and
microbenchmark CLI runs also write and verify the manifest sidecar.
CLI runs of the construction scales time the Wasm publication path.
P0 construction gate results use the existing 10 s and 512 MiB limits.

## Evidence layout

- `dataset.json`, `environment.json`, `finished.json` identify the inputs,
  environment, exact source and binary SHA-256s, and raw sample digest.
- `commands.jsonl` records exact argv, working directory, exit status, PID,
  wall ns, Linux peak RSS in KiB, faults, context switches, and log names.
- `samples.jsonl` has `compile` and `sample` rows keyed by workload, engine,
  window, process group and variant. Sample rows include warm-up status,
  schedule position, cycle, batch count, phase ns, and total ns.
- `builds.json` holds one row per construction process with stage durations
  and output SHA-256. `volumes.json` has Wasm and sidecar sizes.
- Per-workload directories retain the exact original, Fuel-only and P0 Wasm,
  expected stdout, and the representative P0 manifest. Each worker's
  binary schedule and raw stdout/stderr are saved beside the JSON data.

S18 evaluates the measured P0 candidate. The S21 final A17–A20 status
remains `NOT_RUN`.

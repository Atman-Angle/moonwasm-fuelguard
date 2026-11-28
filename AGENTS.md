# Project Agents.md Guide

This is a [MoonBit](https://docs.moonbitlang.com) project.

## MoonWasm Instrument rules

- Use [FuelGuard production specification v4](docs/14_FuelGuard生产规格_v4.md) as the sole implementation and acceptance specification. It derives from the project proposal in docs 04 and awaits implementation and revalidation. Docs 05, 06, 07, 09, 12 and 13 are archived history as described in v4 §6.
- Implement FuelGuard analysis and code generation in MoonBit. Docs 10 is reference-only. Do not delegate production metering, stack or growth rewriting to wasm-instrument, Binaryen or another external backend. Declared codec/validator dependencies and independent test tools remain allowed.
- Keep the instrumentation core independent from every host runtime. `cmd/instrument` remains wasm/moonx-compatible; `cmd/run` is Linux native and owns the wasmoon adapter.
- Wasmtime is required as an independent test runtime, not a second product runner. Windows native, wasm5, browsers, GC, component model and multiple memories/tables are out of scope.
- Apply the feature scope in v4 §1. Unsupported instructions and mutable/escaping funcref tables must fail explicitly, even when the decoder accepts them.
- Instrumentation must not add imports. Preserve existing numeric indexes; planned export/start/element target rewrites for stack wrappers require reference coverage tests.
- The target pipeline is analysis/plan -> Fuel -> Growth -> Stack. Validate every pass output and validate again before encoding; independently validate encoded bytes in integration tests.
- Fuel v2 uses versioned weighted metered spans and checked i64 dynamic costs. Never trade away charging semantics, overflow checks or validation for benchmark results.
- Stack checks reserve shared versioned costs C before original calls. Statically audit A <= C for the default layout, including generated locals, helpers and wrappers. Covered helpers and wrappers incur no extra budget events. Discard instances after traps.
- Use the single default layout specified in v4 §2.5. The prior layout comparisons are frozen history. Apply the v4 §3–4 gates on both engines and measure full protection including lifecycle/start work and applicable hot calls, with fuel-only data reported separately.
- Treat third-party Pass combinations as experimental. Do not silently attach production guarantees to them.
- State v4 implementation, runtime and performance status according to the evidence. Model/ABI changes require versioning, migration notes and reproducible evidence.

You can browse and install extra skills here:
<https://github.com/moonbitlang/skills>

## Task slices

- Derive each v4 task slice, its dependencies and acceptance checks from docs 14. Preserve existing work and verify prerequisites against the code and evidence.
- Start new v4 evidence pages at [S30](docs/evidence/S30.md), one numbered `docs/evidence/Sxx.md` per slice. Record results, reproduction details and blockers there, then update the task status. Mark a slice done only when its acceptance conditions are met.
- Use PowerShell on Windows and run Linux checks in a confirmed Linux environment. Commits, pushes, releases, and submissions require a separate request.

## Project Structure

- MoonBit packages are organized per directory; each directory contains a
  `moon.pkg` file listing its dependencies. Each package has its files and
  blackbox test files (ending in `_test.mbt`) and whitebox test files (ending in
  `_wbtest.mbt`).

- In the toplevel directory, there is a `moon.mod` file listing module
  metadata.

## Coding convention

- MoonBit code is organized in block style, each block is separated by `///|`,
  the order of each block is irrelevant. In some refactorings, you can process
  block by block independently.

- Try to keep deprecated blocks in file called `deprecated.mbt` in each
  directory.

## Tooling

- `moon fmt` is used to format your code properly.

- `moon ide` provides project navigation helpers like `peek-def`, `outline`, and
  `find-references`. See $moonbit-agent-guide for details.

- `moon info` is used to update the generated interface of the package, each
  package has a generated interface file `.mbti`, it is a brief formal
  description of the package. If nothing in `.mbti` changes, this means your
  change does not bring the visible changes to the external package users, it is
  typically a safe refactoring.

- In the last step, run `moon info && moon fmt` to update the interface and
  format the code. Check the diffs of `.mbti` file to see if the changes are
  expected.

- Run `moon test` to check tests pass. MoonBit supports snapshot testing; when
  changes affect outputs, run `moon test --update` to refresh snapshots.

- Prefer `assert_eq` or `assert_true(pattern is Pattern(...))` for results that
  are stable or very unlikely to change. For snapshot tests that record
  structured debugging output, derive `Debug` and use `debug_inspect`, rather
  than deriving `Show` for debugging. For solid, well-defined results (e.g.
  scientific computations), prefer assertion tests. You can use
  `moon coverage analyze > uncovered.log` to see which parts of your code are
  not covered by tests.

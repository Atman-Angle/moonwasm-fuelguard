# FuelGuard named differential corpus

From a checkout on an x86_64 Linux filesystem, run the corpus with the tools
and versions in the [runtime setup guide](../runtime/README.md). The suite also
uses the native compiler toolchain for `cmd/run` and `prlimit` from util-linux.
On WSL2, use a checkout on the Linux filesystem so Moonrun can publish the
Wasm/manifest pairs.

```bash
python3 -B integration/corpus/check.py
```

The driver builds the production instrumenter and native runner, assembles the
named WAT modules, and compiles an exportable MoonBit demo from
[source](../../fixtures/demo/demo/work.mbt). Use `--group strict`,
`--group workloads`, `--group boundaries`, or `--group demo` to run one group.
The Fuel v2 demo's exact span sites are checked against the Linux toolchain
used for the [S35 evidence](../../docs/evidence/S35.md).

The driver prints every command, exit status and SHA-256 of stdout/stderr.
Generated Wasm, manifests, replayable WAST, and raw streams go in a fresh
`_build/s16/run-*` directory. Each row of [cases.py](cases.py) names a case,
its inputs, and its expected memory, globals, references or return values.
Each original and protected module runs with the same assertions in both
engines. Re-run an individual case with its logged WAST commands.

The strict comparison uses deterministic Wasm values and state. The fixed
`spectest` import stubs are checked separately. See the S16 evidence for the
WASI output contract, NaN class, runtime allocation failure, native traps
and initialization failure. The four frozen MoonBit workloads are checked
against their locked SHA-256 digests before execution. The suite also confirms
their source binaries use the supported SIMD-free instruction set.

The [S16 coverage matrix](../../docs/evidence/S16.md#覆盖矩阵) lists the
additional package, lifecycle, oracle and delivery checks.

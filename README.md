# MoonWasm FuelGuard

Build-time fuel metering and resource guards for MoonBit WebAssembly modules.

- Product name: MoonWasm Instrument
- Repository: `moonwasm-fuelguard`
- License: Apache-2.0
- Status: fuel-only build-time instrumentation; GuardPass and the wasmoon adapter are not implemented yet

MoonWasm FuelGuard is designed to make a standard MoonBit `--target wasm` module carry its own execution budget. Instrumentation adds no imports, writes a fixed fuel budget at build time, traps deterministically when fuel or resource limits are exhausted, and exposes a readable trap code through `__moonwasm_trap_code`.

## Project status

| Area | Status |
| --- | --- |
| Core API and package boundaries | Implemented |
| Input policy | Multiple memories/tables, GC types, and reserved exports rejected |
| Pass pipeline | Fixed Fuel → Guard order, validation after every pass |
| Decode / validate / encode | Implemented with staged errors |
| FuelPass | Implemented: entry and loop body charges, deterministic fuel trap |
| GuardPass | Disabled by default; configured guards are rejected as not implemented |
| `cmd/instrument` | Fuel-only file pipeline, moonx-compatible wasm entry |
| `cmd/run` | Scaffold, Linux-native entry only |
| wasmoon adapter | Not implemented |
| Differential corpus and benchmarks | Not started |

This repository is honest about its state: instrumentation meters fuel only, and no runtime execution has been validated through wasmoon.

## Fuel-only usage

```text
moon run cmd/instrument --target wasm -- <in.wasm> -o <out.wasm> --fuel <N> \
  [--max-memory-pages <N>] [--max-table-elements <N>] [--allow-import <module.name>]...
```

Current behavior:

- Reads and decodes the input, runs the input policy, then applies `FuelPass`.
- Charges 1 unit at every defined function entry and every loop body start.
- Appends a mutable `i32` fuel global and a mutable `i32` trap code global, exporting the latter as `__moonwasm_trap_code`.
- Traps with code `1` when the remaining fuel becomes negative.
- Validates after each pass and again before encoding; the output file is written only after encoding succeeds.
- Exits `2` without writing a file on decode, policy, validation, encode, or option errors.
- Rejects any guard option (`--max-memory-pages`, `--max-table-elements`, `--allow-import`) with a not-implemented error.

Not implemented yet: memory/table growth guards, import allowlists, the native `run` adapter, runtime trap execution, differential corpus, and benchmarks.

## CLI split

`moonx` runs wasm packages, while wasmoon is native-only. A single moonx CLI therefore cannot provide both `instrument` and `run`.

- `cmd/instrument` is the wasm-compatible, moonx-distributed instrumentation entry.
- `cmd/run` is a native Linux entry that will own the wasmoon adapter.
- Both entries share the host-independent core package.

Local entry points:

```text
moon run cmd/instrument --target wasm -- --help
moon run cmd/run --target native -- --help
```

The `run` entry requires a Linux environment; Windows native builds are out of scope. After publishing, the instrumentation entry is intended to run as:

```text
moonx Atman-Angle/moonwasm-fuelguard/cmd/instrument --help
```

## Repository layout

```text
.
├── cmd/
│   ├── instrument/        # wasm + moonx entry (cli, file pipeline)
│   └── run/               # native Linux entry
├── runner/                # trap diagnosis and future wasmoon adapter
├── fixtures/hello/        # real MoonBit wasm fixture and build script
├── scripts/               # end-to-end and failure-path checks
├── docs/                  # requirements and architecture
├── config.mbt             # typed instrumentation configuration
├── instrument_error.mbt   # staged errors
├── pass.mbt               # public Pass and PassResult
├── pipeline.mbt           # fixed validation pipeline
├── policy.mbt             # input rejection rules
├── codec.mbt              # decode / validate / encode wrappers
├── ast.mbt                # private AST traversal helpers
├── fuel_state.mbt         # fuel and trap code globals
├── fuel_pass.mbt          # fuel metering pass
├── builtin_passes.mbt     # FuelPass and GuardPass wiring
└── trap.mbt               # trap code model
```

## Development

Prerequisites:

- MoonBit `0.1.20261016` or compatible
- starshine `0.3.0`
- Linux or WSL for the native `run` adapter

Check and test the portable core:

```bash
moon check --target wasm --deny-warn
moon test --target wasm
```

Format and refresh interfaces after changes:

```bash
moon info
moon fmt
```

End-to-end checks against the real MoonBit fixture:

```bash
bash scripts/check-e2e.sh
bash scripts/check-cli-failures.sh
```

`fixtures/hello` is an independent MoonBit module; rebuild its wasm with `bash fixtures/hello/build.sh`. The e2e script rebuilds it, instruments it twice, and asserts identical output bytes plus the presence of the trap code export. The failure-path script covers missing input, missing `--fuel`, invalid limits, undecodable input, rejected guard configuration, and output preservation on failure.

Windows native tests are not supported: starshine's native trace backend uses `gettimeofday`, which is unavailable in the current MSVC environment.

## Limitations

- Only fuel metering is implemented. Memory/table growth guards and import allowlists are rejected, not silently ignored.
- No runtime execution is verified: the wasmoon runner is not implemented, so fuel traps have not been observed at runtime.
- Windows native, wasm-gc, component model, multiple memories/tables, and multiple modules are out of scope; such inputs are rejected.
- There is no differential corpus, performance benchmark, or mooncakes release yet.

## Next steps

1. Implement GuardPass for memory/table growth and import allowlists.
2. Add the Linux wasmoon runner and verify fuel trap code `1` at runtime.
3. Build the deterministic differential corpus and the three fuel-only benchmarks.
4. Publish to mooncakes and validate the moonx entry.

## Architecture

The authoritative design is [docs/06_架构设计_MoonWasm_Instrument.md](docs/06_架构设计_MoonWasm_Instrument.md), including component, pipeline, fuel, guard, and run-flow diagrams.

Key invariants:

- Instrumentation adds no imports.
- Every pass is followed by starshine validation.
- Encoding validates again.
- FuelPass runs before GuardPass.
- The diagnostic export name is reserved.
- wasm-gc, component model, and multiple memories/tables are rejected.
- Windows native and wasm5 are out of scope.

## Roadmap

1. ~~Implement FuelPass and its unit tests.~~ (fuel-only instrumentation implemented)
2. Implement GuardPass and import allowlisting.
3. Add the Linux wasmoon adapter and CI trap demo.
4. Add the deterministic differential corpus and performance benchmark.
5. Publish to mooncakes and tag the first functional release.

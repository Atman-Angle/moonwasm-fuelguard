# MoonWasm FuelGuard

Build-time fuel metering and resource guards for MoonBit WebAssembly modules.

- Product name: MoonWasm Instrument
- Repository: `moonwasm-fuelguard`
- License: Apache-2.0
- Status: bootstrap scaffold; FuelPass, GuardPass, and the wasmoon adapter are not implemented yet

MoonWasm FuelGuard is designed to make a standard MoonBit `--target wasm` module carry its own execution budget. Instrumentation adds no imports, writes a fixed fuel budget at build time, traps deterministically when fuel or resource limits are exhausted, and exposes a readable trap code through `__moonwasm_trap_code`.

## Project status

| Area | Status |
| --- | --- |
| Core API and package boundaries | Scaffolded |
| Input policy | Basic filters implemented |
| Pass pipeline | Closed loop implemented; built-in passes return `NotImplemented` |
| Decode / validate / encode | Wrapped with staged errors |
| FuelPass | Not implemented |
| GuardPass | Not implemented |
| `cmd/instrument` | Scaffold, moonx-compatible wasm entry |
| `cmd/run` | Scaffold, Linux-native entry only |
| wasmoon adapter | Not implemented |
| Differential corpus and benchmarks | Not started |

This repository is intentionally honest about its scaffold state. It does not yet meter or guard any module.

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
│   ├── instrument/        # wasm + moonx entry
│   └── run/               # native Linux entry
├── runner/                # trap diagnosis and future wasmoon adapter
├── docs/                  # requirements and architecture
├── config.mbt             # typed instrumentation configuration
├── instrument_error.mbt   # staged errors
├── pass.mbt               # public Pass and PassResult
├── pipeline.mbt           # fixed validation pipeline
├── policy.mbt             # input rejection rules
├── codec.mbt              # decode / validate / encode wrappers
├── builtin_passes.mbt     # FuelPass and GuardPass scaffolds
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

Windows native tests are not supported: starshine's native trace backend uses `gettimeofday`, which is unavailable in the current MSVC environment.

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

1. Implement FuelPass and its unit tests.
2. Implement GuardPass and import allowlisting.
3. Add the Linux wasmoon adapter and CI trap demo.
4. Add the deterministic differential corpus and performance benchmark.
5. Publish to mooncakes and tag the first functional release.

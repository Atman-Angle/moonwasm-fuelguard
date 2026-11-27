# MoonWasm FuelGuard

FuelGuard adds build-time resource budgets to supported MoonBit WebAssembly modules. A single pass pipeline applies weighted instruction metering, call-stack limits, and memory or table growth limits. The instrumented module uses its existing imports. A resource failure traps and reports a code and site.

## Quick start

Use MoonBit 1.0 RC and a Linux x86-64 shell. The installed instrumenter accepts a supported original Wasm file and creates a separate protected file. For a small reproducible input, build the scalar MoonBit demo.

```sh
(cd fixtures/demo && moon build --target wasm --release)
mkdir -p _build/demo
fuelguard-instrument fixtures/demo/_build/wasm/release/build/demo/demo.wasm \
  -o _build/demo/protected.wasm --fuel 100000 \
  --max-stack-units 100000 --max-call-depth 128 \
  --max-memory-pages 64 --max-table-elements 64 --report _build/demo/protected.json
fuelguard-run _build/demo/protected.wasm --invoke short_loop --arg 10
```

The demo returns `45`. Use a fresh output path on each invocation.

- Install the Wasm instrumenter and Linux runner or migrate historical artifacts. [Installation and migration](docs/install.md)
- Set resource limits, verify a Wasm and manifest pair, and look up the original instruction behind a trap. [CLI reference](docs/cli.md)
- Check supported Wasm features and Linux runtime constraints. [Support](docs/support.md)
- Inspect prices, span accounting, stack units, or the manifest ABI. [Fuel weights](docs/implementation/fuel-v1.md) · [Fuel v2](docs/implementation/fuel-v2.md) · [Stack v2](docs/implementation/stack-v2.md) · [Manifest v2](docs/implementation/manifest-v2.md)
- Review timing and size measurements and reproduce the results from source. [Performance report](docs/performance.md) · [Reproduction](docs/reproduce.md)

The library exposes the same production planning and instrumentation through `Pipeline::plan`, `Pipeline::run`, and `resolve_production_site`.

## License

Apache-2.0. [License](LICENSE) · [Notice](NOTICE) · [Third-party dependencies](THIRD_PARTY.md)

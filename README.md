# MoonWasm FuelGuard

FuelGuard adds build-time resource budgets to supported MoonBit WebAssembly modules. Its MoonBit pipeline applies weighted Fuel metering, stack and depth checks, and memory or table growth limits without adding imports.

Fuel is a deterministic compute quota, not CPU time. FuelGuard is not a security sandbox and does not limit host imports, filesystem or network access, or wall-clock time.

For a scalar MoonBit demo, build and instrument a real module, then run it with the Linux runner:

```sh
(cd fixtures/demo && moon build --target wasm --release)
mkdir -p _build/demo
fuelguard-instrument fixtures/demo/_build/wasm/release/build/demo/demo.wasm \
  -o _build/demo/protected.wasm --fuel 100000 \
  --max-stack-units 100000 --max-call-depth 128 \
  --max-memory-pages 64 --max-table-elements 64 --report _build/demo/protected.json
fuelguard-run _build/demo/protected.wasm --invoke short_loop --arg 10
```

The demo returns `45`. Use a new output path for each instrumentation run.

- [Installation and migration](docs/install.md)
- [CLI reference](docs/cli.md)
- [Supported inputs and runtime limits](docs/support.md)
- [Fuel weights](docs/implementation/fuel-v1.md), [Fuel v2](docs/implementation/fuel-v2.md), [Stack v2](docs/implementation/stack-v2.md), and [manifest v2](docs/implementation/manifest-v2.md)
- [Performance report](docs/performance.md) and [reproduction guide](docs/reproduce.md)

The library exposes planning and instrumentation through `Pipeline::plan`, `Pipeline::run`, and `resolve_production_site`.

## License

Apache-2.0. See [LICENSE](LICENSE), [NOTICE](NOTICE), and [THIRD_PARTY.md](THIRD_PARTY.md).

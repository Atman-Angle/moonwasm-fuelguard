# CLI reference

## Instrument

```sh
fuelguard-instrument input.wasm -o protected.wasm --fuel 100000 \
  --max-stack-units 100000 --max-call-depth 128 \
  --max-memory-pages 64 --max-table-elements 64 --report protected.json
```

The default `production-v1` profile requires positive Fuel, stack units and call depth. Set the memory or table limit for each corresponding resource present in the input. The tool rejects an initial size beyond the configured limit. Within that limit, the original grow instruction can still return `-1` under the module's original maximum. Charged dynamic fees are retained.

Imports match exact module and field pairs. Pass `--allow-import module.field` for ordinary names, or repeat `--allow-import-pair <module> <field>` for names that contain dots. `--stack-layout` displays per-function abstract stack costs. Historical `fuel-growth-v1` and `legacy` profiles retain older Fuel and Growth behavior without runtime stack budgets.

The instrumenter writes new files and refuses existing output paths. Use a filesystem with no-replace rename support. Under WSL, use the Linux filesystem for destinations. On a failed operation, check the exit code and any reported delivery error before reusing an output path.

## Verify and resolve a trap

```sh
fuelguard-instrument verify protected.wasm --report protected.json
fuelguard-instrument resolve-site input.wasm protected.wasm --report protected.json 33
```

`verify` checks the artifact hash, format and the Fuel v2 span proof. `resolve-site` also checks the original hash and prints the original function index, zero-based instruction ordinal and opcode. A wrapper entry resolves to `entry=export-or-start`. Keep the original, protected Wasm and manifest together.

## Run

```sh
ulimit -s 8192
fuelguard-run protected.wasm --invoke short_loop --arg 10
```

The default export is `_start`. Use `--invoke` for a named export and repeat `--arg` for scalar parameters. WASI Preview 1 imports require `--wasi` and an explicit `--allow-import` for each function. Flags such as `--wasi-stdout` enable individual streams. `--timeout-ms` applies a cooperative deadline to each guest call, including core start.

The Linux runner uses wasmoon. It disposes of trapped instances. Resource codes 1 through 5 indicate Fuel, memory growth, table growth, stack units and logical depth, respectively. A native trap has code 0. Initialization failures can report `diagnostic-unavailable`. Exit 1 indicates an execution failure. Exit 2 indicates a usage, input, or environment failure. Use artifacts from a trusted instrumentation pipeline. [Supported inputs](support.md)

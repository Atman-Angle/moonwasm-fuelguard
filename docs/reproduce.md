# Reproduce FuelGuard 0.2.0 checks

Use an x86-64 Linux checkout. The reference tools were MoonBit 1.0 RC, wasmoon 0.18.0, Wasmtime CLI and C API 50.0.0, wasm-tools 1.263.0, Python 3.12 and NumPy 1.26.4. Put the engine executables on `PATH`. Prepare dependencies with the pinned compatibility script. [Installation](install.md)

```sh
python3 -B scripts/prepare-dependencies.py . cmd/run bench/native integration/generated/worker
moon check --frozen --target wasm --deny-warn
moon test --frozen --target wasm
bash scripts/check-e2e.sh
python3 -B integration/manifest/check.py
python3 -B integration/acceptance/check.py --group correctness --group generated --group rejections
```

The generated test uses seed `270019` and runs 10,000 inputs in both runtimes. Its report separates the selected checks from overall release status. To independently exercise Linux file-system failure cases, run the same acceptance entry with `--group delivery` as root in an environment supporting a private mount namespace.

## Performance and volume

Use a quiet host on AC power. For `--host-record`, save JSON with an `ac` boolean, `scheme` string, `windows_build` string and a `cpu` array containing the host CPU model and physical and logical counts. The benchmark records actual Linux kernel, stack limits, CPU affinity, dependency identity and output hashes. The holdout runs can take over an hour.

```sh
python3 -B bench/run.py --compare-fuel-v2 --a17-holdout-dataset \
  --host-record "$HOST_RECORD" --wasmtime-c-api "$WASMTIME_C_API" --out _build/tuning
python3 -B bench/summarize.py _build/tuning --out _build/tuning.json \
  --freeze-candidate _build/candidate-lock.json
python3 -B bench/run.py --compare-fuel-v2 --a17-holdout-dataset --holdout \
  --candidate-run _build/tuning --candidate-lock _build/candidate-lock.json \
  --host-record "$HOST_RECORD" --wasmtime-c-api "$WASMTIME_C_API" --out _build/holdout
python3 -B bench/summarize.py _build/holdout --out _build/holdout.json
moon build --frozen --target wasm --release cmd/instrument
python3 -B bench/check-small-size.py _build/wasm/release/build/cmd/instrument/instrument.wasm _build/small-size
```

The runner measures original, Fuel-only and full instrumentation. The summary records workload timings, compile phases, process RSS and artifact sizes. The separate scalar demo checks the small-volume tier and records both Wasm and manifest identities. Keep the results and command logs under the selected output directory when comparing measurements. [Performance report](performance.md)

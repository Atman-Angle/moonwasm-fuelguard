# Reproduce tests and measurements

Use an x86-64 Linux checkout. The reference environment used MoonBit 1.0 RC, wasmoon 0.18.0, Wasmtime CLI and C API 50.0.0, wasm-tools 1.263.0, Python 3.12, and NumPy 1.26.4. Put the engine executables on `PATH`. Prepare the pinned dependencies as described in [installation](install.md).

## Correctness checks

```sh
python3 -B scripts/prepare-dependencies.py . cmd/run bench/native integration/generated/worker
moon check --frozen --target wasm --deny-warn
moon test --frozen --target wasm
bash scripts/check-e2e.sh
python3 -B integration/manifest/check.py
python3 -B integration/acceptance/check.py --group correctness --group generated --group rejections
```

The named differential suite contains 69 cases, including 24 control-flow or stack-boundary cases. The generated suite uses seed `270019` and executes 10,000 distinct inputs in both runtimes. It records expected outcomes and reports the selected checks separately from full release status. Linux filesystem failure tests require an environment that supports a private mount namespace.

## Performance and size

Use a quiet host on AC power. The benchmark host record contains an `ac` boolean, a power-scheme string, the Windows build, and a CPU array with the model and physical/logical core counts. The run records the Linux kernel, stack limits, CPU affinity, dependency identity, and artifact hashes. Full holdout measurements can take over an hour.

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

The benchmark records original, Fuel-only, and fully protected runs, including lifecycle, hot calls, build stages, process RSS, Wasm size, and manifest size. Keep generated measurements under `_build/`. Summary values and interpretation are in the [performance report](performance.md).

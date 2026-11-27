# Installation and migration

The reference toolchain is MoonBit 1.0 RC. The tested builds use `moon 0.1.20261126 (ccd306a)` and `moonc v1.0.0-rc1+3c0520448`. The Linux product runner requires x86-64 Linux or WSL2 on a Linux filesystem, glibc, and a C compiler.

From a checkout or unpacked Mooncakes source archive, prepare the pinned dependencies and install both command-line tools:

```sh
moon update
python3 -B scripts/prepare-dependencies.py . cmd/run
moon build --frozen --target wasm --release cmd/instrument
install -Dm644 _build/wasm/release/build/cmd/instrument/instrument.wasm "$PWD/bin/instrument.wasm"
install -Dm755 scripts/fuelguard-instrument "$PWD/bin/fuelguard-instrument"
moon install ./cmd/run --bin "$PWD/bin"
export PATH="$PWD/bin:$PATH"
fuelguard-instrument --version
fuelguard-run --version
```

The source-build path uses the published `Atman-Angle/fuelguard-codec@0.1.0` compatibility package. Keep the `fuelguard-instrument` launcher beside `instrument.wasm`. The launcher sets glibc allocator parameters before starting Moonrun. Directly run the Wasm CLI with `moonrun bin/instrument.wasm -- <args>`.

Run the published instrumenter with `moonx Atman-Angle/moonwasm-fuelguard/cmd/instrument@0.2.1 <args>`. The CLI accepts an original Wasm file and writes a separate protected file and optional manifest.

## Migrating a protected artifact

Save the original Wasm with each protected artifact. Verify its SHA-256 against a trusted manifest before resolving a diagnostic site. Remove historical model and layout selectors, choose current Fuel, stack, depth, and growth limits, then instrument from the original file into new output files.

Run `fuelguard-instrument verify old.wasm --report old.json` to validate a historical pair. The verifier supports manifest v1 with its corresponding marker. Production 0.2.1 uses manifest v2, Fuel v2, Stack v2, and diagnostics v1. See [manifest v2](implementation/manifest-v2.md) for the artifact format.

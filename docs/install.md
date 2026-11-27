# Installation and migration

The reference toolchain is MoonBit 1.0 RC. The tested builds use `moon 0.1.20261126 (ccd306a)` and `moonc v1.0.0-rc1+3c0520448`. Install from the public GitHub repository or unpack the Mooncakes source archive. The Linux product runner requires x86-64 Linux or WSL2 on a Linux filesystem, glibc, and a C compiler.

The source package is `Atman-Angle/moonwasm-fuelguard@0.2.0`. Add it with `moon add Atman-Angle/moonwasm-fuelguard@0.2.0`. The dependency starshine 0.3.0 compiles without changes on the MoonBit snapshot `0.1.20261104 (940aa18)`. On MoonBit 1.0 RC it needs the bundled trait-call compatibility patch. For a consumer module, run `moon check --target wasm --dry-run --no-mbti` to resolve its dependencies, then apply the bundled patch with `git -C .mooncakes/jtenner/starshine apply /absolute/path/to/starshine-0.3.0-moonbit-20261126.patch`. The preparation script below checks the archive and patch hashes and supports repeat execution for the source workspaces.

From an unpacked source archive or checkout, install both command-line tools as follows. Keep the sibling launcher and Wasm file together.

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

The instrumenter also runs with `moonrun bin/instrument.wasm -- <args>`. If the versioned Wasm asset is present on the registry, use `moonx Atman-Angle/moonwasm-fuelguard/cmd/instrument@0.2.0 <args>`. The Linux launcher sets glibc allocator parameters for that invocation. Use the launcher when comparing construction memory against the published results.

## Migrating a protected artifact

Save the original Wasm with each protected artifact. Use the original input's SHA-256 from a trusted old manifest to find the matching file. Remove historical model and layout selectors, choose current Fuel, stack, depth and growth limits, then instrument into new files. The current manifest records the model versions and the hashes of both Wasm files.

Run `fuelguard-instrument verify old.wasm --report old.json` to check a historical pair. The verifier supports historical manifest v1 with its corresponding marker. Production 0.2.0 uses manifest v2, Fuel v2, Stack v2 and diagnostics v1. [Artifact format](implementation/manifest-v2.md)

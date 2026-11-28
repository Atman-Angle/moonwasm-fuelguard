# S02 Linux runtime smoke checks

Run from an x86_64 Linux or WSL2 distribution with Python 3.10+, Bash, a
native C toolchain for wasmoon, and MoonBit on PATH. The reference Linux
toolchain is `moon 0.1.20261104 (940aa18)` with GCC 13.3.0. The driver
records the actual MoonBit version and checks the frozen S01 input hashes.

1. Install the MoonBit runtime CLI with
   `moon install Milky2018/wasmoon/cmd/wasmoon@0.18.0`.
2. Put the Linux x86_64 executables from
   [Wasmtime v50.0.0](https://github.com/bytecodealliance/wasmtime/releases/tag/v50.0.0)
   and [wasm-tools v1.263.0](https://github.com/bytecodealliance/wasm-tools/releases/tag/v1.263.0)
   on PATH. Verify the downloaded archives against these SHA-256 digests:

   | Archive | SHA-256 |
   | --- | --- |
   | `wasmtime-v50.0.0-x86_64-linux.tar.xz` | `77c19ee0437991f9ac7837b9c269d9c7076744f85dad263fea5214cc2723c7ff` |
   | `wasm-tools-1.263.0-x86_64-linux.tar.gz` | `21c036c1740a0552124c79c6e2170cb61c5b016005671a6d5bc06cf642165431` |
3. Use the F0–F3 binaries under `fixtures/`, or rebuild them with their
   respective `build.sh` scripts and verify the hashes against S01.
4. From the repository root run:

   ```bash
   mkdir -p _build/s02-runtime
   set -o pipefail
   bash scripts/check-runtime-linux.sh 2>&1 | tee _build/s02-runtime/run.log
   ```

The driver uses fresh CLI processes, an 8 MiB Linux soft stack limit, a
512 KiB Wasmtime Wasm stack limit, and a 30 s timeout per runtime command.
It leaves engine fuel and epoch interruption at their default disabled
settings. Each command's stdout and stderr are saved under
`_build/s02-runtime/` with exit codes and SHA-256 hashes in the run log.
WASI tests compare stdout for the four originals and the instrumented F0. The other fixtures cover i32 returns, a guest getter over the diagnostic
global, an export trap, and a core start trap. The CLI processes do not
retain an instance for host-side diagnostic reads after a trap.

The instrumented F0 uses explicit memory and table limits and an exact allowance
for `wasi_snapshot_preview1.fd_write`. It is checked with the independent validator. The WAT fixtures are assembled by wasm-tools.
See [S02 evidence](../../docs/evidence/S02.md) for actual results.

"""Optional bulk-work sanity calibration on the S02 Linux toolchain."""

from pathlib import Path
from statistics import median
import subprocess
from time import perf_counter


def main():
    out = Path("_build/s04-calibration")
    out.mkdir(parents=True, exist_ok=True)
    for size in (4096, 1_048_576):
        wat = out / f"fill-{size}.wat"
        wasm = wat.with_suffix(".wasm")
        wat.write_text(f"""(module
          (memory 16)
          (func (export "run") (result i32) (local $i i32)
            (loop $again
              i32.const 0 local.get $i i32.const {size} memory.fill
              local.get $i i32.const 1 i32.add local.tee $i
              i32.const 8192 i32.lt_u br_if $again)
            i32.const {size - 1} i32.load8_u))
        """, encoding="utf-8")
        subprocess.run(["wasm-tools", "parse", wat, "-o", wasm], check=True, timeout=30)
        subprocess.run(["wasm-tools", "validate", wasm], check=True, timeout=30)
        commands = {
            "wasmoon": ["wasmoon", "run", wasm, "--invoke", "run"],
            "wasmtime": ["wasmtime", "run", "-W", "max-wasm-stack=524288", "--invoke", "run", wasm],
        }
        for engine, command in commands.items():
            samples = []
            for trial in range(6):
                start = perf_counter()
                result = subprocess.run(command, capture_output=True, check=True, timeout=30)
                elapsed = perf_counter() - start
                if result.stdout.strip() != b"255":
                    raise RuntimeError(f"{engine}: unexpected calibration result {result.stdout!r}")
                if trial:
                    samples.append(1000 * elapsed)
            print(f"{engine} memory.fill n={size}: median {median(samples):.2f} ms "
                  f"samples {[round(value, 2) for value in samples]}")


if __name__ == "__main__":
    main()

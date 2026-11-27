"""Sample guest hot paths for a scaled copy of the FuelGuard F2 workload."""

import argparse
import hashlib
import json
import subprocess
from collections import Counter
from pathlib import Path


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run(command):
    return subprocess.run(command, check=True, text=True, capture_output=True)


def wat_utf16(text):
    encoded = []
    for char in text:
        codepoint = ord(char)
        if codepoint < 0x20 or codepoint > 0x7E or char in ('"', "\\"):
            encoded.append(f"\\{codepoint & 0xFF:02x}\\{codepoint >> 8:02x}")
        else:
            encoded.append(char + f"\\{codepoint >> 8:02x}")
    return "".join(encoded)


def profile_counts(path):
    profile = json.loads(path.read_text(encoding="utf-8"))
    inclusive = Counter()
    exclusive = Counter()
    sample_count = 0
    for thread in profile["threads"]:
        strings = thread["stringArray"]
        functions = thread["funcTable"]["name"]
        frames = thread["frameTable"]["func"]
        stack_frames = thread["stackTable"]["frame"]
        stack_prefix = thread["stackTable"]["prefix"]
        samples = thread["samples"]
        sample_count += samples["length"]
        for stack, weight in zip(samples["stack"], samples["weight"]):
            frame = stack_frames[stack]
            exclusive[strings[functions[frames[frame]]]] += weight
            while stack is not None:
                frame = stack_frames[stack]
                function = frames[frame]
                inclusive[strings[functions[function]]] += weight
                stack = stack_prefix[stack]
    return sample_count, inclusive, exclusive


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--wasm-tools", type=Path, required=True)
    parser.add_argument("--wasmtime", type=Path, required=True)
    parser.add_argument("--build-worker", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--fib", type=int, default=30)
    parser.add_argument("--stack-units", type=int, default=500000)
    parser.add_argument("--depth", type=int, default=2048)
    parser.add_argument("--runs", type=int, default=5)
    parser.add_argument("--interval-ms", type=int, default=1)
    args = parser.parse_args()
    if args.fib < 18 or args.runs < 1 or args.interval_ms < 1:
        parser.error("fib must be >= 18, runs and interval-ms must be positive")

    source = args.source.resolve()
    wasm_tools = args.wasm_tools.resolve()
    wasmtime = args.wasmtime.resolve()
    builder = args.build_worker.resolve()
    output = args.out.resolve()
    output.mkdir(parents=True, exist_ok=False)

    wat = output / "profile-input.wat"
    module = output / "profile-input.wasm"
    run([str(wasm_tools), "print", str(source), "-o", str(wat)])
    wat_text = wat.read_text(encoding="utf-8")
    original_expr = wat_utf16("(fib 18))")
    profile_expr = wat_utf16(f"(fib {args.fib}))")
    if wat_text.count(original_expr) != 1:
        raise ValueError("expected exactly one embedded (fib 18) input")
    wat.write_text(wat_text.replace(original_expr, profile_expr, 1), encoding="utf-8")
    run([str(wasm_tools), "parse", str(wat), "-o", str(module)])
    run([str(wasm_tools), "validate", str(module)])

    expected = None
    variants = {
        "original": module,
        "fuel-only": output / "fuel-only.wasm",
        "full-protection": output / "full-protection.wasm",
    }
    for kind, path in (("fuel", variants["fuel-only"]),
                       ("fuel-v2", variants["full-protection"])):
        run([str(builder), kind, str(module), str(path), str(args.stack_units),
             str(args.depth), "1"])
        run([str(wasm_tools), "validate", str(path)])

    records = []
    for variant, path in variants.items():
        for run_number in range(1, args.runs + 1):
            profile_path = output / f"{variant}-{run_number}.json"
            result = run([str(wasmtime), "run",
                          f"--profile=guest,{profile_path},{args.interval_ms}", str(path)])
            stdout = result.stdout.encode("utf-8")
            if expected is None:
                expected = stdout
            elif stdout != expected:
                raise ValueError(f"stdout differs for {variant} run {run_number}")
            sample_count, inclusive, exclusive = profile_counts(profile_path)
            records.append({
                "variant": variant,
                "run": run_number,
                "profile_sha256": sha256(profile_path),
                "sample_count": sample_count,
                "inclusive_functions": inclusive.most_common(),
                "exclusive_functions": exclusive.most_common(),
            })

    (output / "expected.stdout").write_bytes(expected)
    summary = {
        "diagnostic_only": True,
        "input_scope": "scaled copy of the F2 tuning application",
        "fib": args.fib,
        "runs": args.runs,
        "interval_ms": args.interval_ms,
        "source_sha256": sha256(source),
        "scaled_module_sha256": sha256(module),
        "build_worker_sha256": sha256(builder),
        "wasmtime_sha256": sha256(wasmtime),
        "wasm_tools_sha256": sha256(wasm_tools),
        "variants": {name: sha256(path) for name, path in variants.items()},
        "stdout_sha256": hashlib.sha256(expected).hexdigest(),
        "runs_detail": records,
    }
    (output / "summary.json").write_text(
        json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps({
        "out": str(output),
        "fib": args.fib,
        "samples": {
            variant: sum(row["sample_count"] for row in records
                         if row["variant"] == variant)
            for variant in variants
        },
        "stdout_sha256": summary["stdout_sha256"],
    }, indent=2))


if __name__ == "__main__":
    main()

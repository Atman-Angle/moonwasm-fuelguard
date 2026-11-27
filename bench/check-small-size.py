"""Verify the below-10-KiB size tier on a separately frozen MoonBit workload."""

import argparse
import json
from pathlib import Path
import subprocess

from dataset import ROOT, sha256, write_json
from performance_evidence import size_status


DEMO_SHA256 = "8b5858f8d34e620db5c39ba9e2a036f8188c0283155b77b463aece3332b17d93"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("instrument", type=Path, help="built production instrument.wasm")
    parser.add_argument("out", type=Path, help="new evidence directory")
    args = parser.parse_args()
    out = args.out.resolve()
    out.mkdir(parents=True)
    instrument = args.instrument.resolve(strict=True)
    build = out / "demo-build"
    source = build / "wasm/release/build/demo/demo.wasm"
    protected = out / "demo.protected.wasm"
    sidecar = out / "demo.protected.json"
    commands = [
        ["moon", "version", "--all"],
        ["wasm-tools", "--version"],
        ["moon", "build", "--target", "wasm", "--release", "--target-dir", str(build)],
        ["wasm-tools", "validate", "--features=-simd", str(source)],
        ["moonrun", str(instrument), str(source), "-o", str(protected),
         "--fuel", "100000", "--max-stack-units", "100000", "--max-call-depth", "128",
         "--max-memory-pages", "64", "--max-table-elements", "64", "--report", str(sidecar)],
        ["wasm-tools", "validate", str(protected)],
        ["moonrun", str(instrument), "verify", str(protected), "--report", str(sidecar)],
    ]
    with (out / "commands.jsonl").open("x", encoding="utf-8") as journal:
        for index, command in enumerate(commands):
            if index == 4 and (sha256(source) != DEMO_SHA256 or source.stat().st_size >= 10240):
                raise ValueError("demo input differs from the frozen small-application workload")
            cwd = ROOT / "fixtures/demo" if index == 2 else ROOT
            result = subprocess.run(command, cwd=cwd, capture_output=True)
            stdout, stderr = out / f"{index}.stdout", out / f"{index}.stderr"
            stdout.write_bytes(result.stdout)
            stderr.write_bytes(result.stderr)
            journal.write(json.dumps({"argv": command, "cwd": str(cwd), "exit": result.returncode,
                                      "stdout_sha256": sha256(stdout), "stderr_sha256": sha256(stderr)}) + "\n")
            result.check_returncode()
    input_bytes, output_bytes = source.stat().st_size, protected.stat().st_size
    status = size_status(input_bytes, output_bytes)
    write_json(out / "report.json", {
        "case": "fuelguard-s16-demo", "tier": "<10 KiB", "status": status,
        "source_sha256": sha256(source), "instrument_sha256": sha256(instrument),
        "output_sha256": sha256(protected), "manifest_sha256": sha256(sidecar),
        "input_bytes": input_bytes, "wasm_bytes": output_bytes,
        "added_bytes": output_bytes - input_bytes, "manifest_bytes": sidecar.stat().st_size,
        "command_log_sha256": sha256(out / "commands.jsonl"),
    })
    print(f"{status}: {input_bytes} -> {output_bytes} B, manifest {sidecar.stat().st_size} B")
    return 0 if status == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())

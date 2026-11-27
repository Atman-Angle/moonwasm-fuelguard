"""Interleave two archived S28 builds, and replay the pilot and build gates."""
import argparse
import json
import os
import platform
import resource
import shutil
import sys
import time
from collections import defaultdict
from contextlib import redirect_stdout
from pathlib import Path

import numpy as np

from dataset import DATASET_SHA256, sha256, write_json
from performance_evidence import size_limit
from run import ENGINES, PREFIX_PILOT_SAMPLES, Run, measure
from summarize import checked_transcripts, interval, statistics, validate_construction


VARIANTS = ("original", "before", "after")
WORKERS = {"wasmoon": "wasmoon", "wasmtime": "wasmtime-worker"}
NOISE_LIMIT = 1.02
CPU_FIELDS = {"processor", "vendor_id", "cpu family", "model", "model name", "stepping", "microcode"}


def cpu_identity(cpuinfo):
    return [line for line in cpuinfo.splitlines()
            if line.partition(":")[0].strip() in CPU_FIELDS]


def lock_timing_environment(out, environment, protocol, host_record, replay):
    path = out / "timing-environment.json"
    expected = {key: environment[key] for key in ("uname", "host", "affinity", "stack", "clock")}
    expected["cpu"] = cpu_identity(environment["cpuinfo"])
    if replay:
        observed = json.loads(path.read_bytes())
    else:
        if platform.system() != "Linux" or platform.machine() != "x86_64" or not host_record:
            raise ValueError("live paired timing requires Linux x86_64 and a current host record")
        if protocol["cpu"] not in os.sched_getaffinity(0):
            raise ValueError("frozen CPU is unavailable")
        os.sched_setaffinity(0, {protocol["cpu"]})
        _, hard = resource.getrlimit(resource.RLIMIT_STACK)
        resource.setrlimit(resource.RLIMIT_STACK, (environment["stack"][0], hard))
        observed = dict(uname=platform.uname()._asdict(), host=json.loads(host_record.read_bytes()),
                        affinity=sorted(os.sched_getaffinity(0)), stack=list(resource.getrlimit(resource.RLIMIT_STACK)),
                        clock=time.get_clock_info("monotonic").__dict__,
                        cpu=cpu_identity(Path("/proc/cpuinfo").read_text()))
    if observed != expected:
        raise ValueError("paired timing differs from the frozen construction environment")
    if not replay:
        write_json(path, observed)
    return sha256(path)


def construction(directory, variant, data):
    environment = json.loads((directory / "environment.json").read_bytes())
    if (environment["smoke"] or environment["dataset_sha256"] != DATASET_SHA256
            or sha256(directory / "dataset.json") != DATASET_SHA256
            or variant not in environment["variants"][1:]):
        raise ValueError(f"incompatible construction run: {directory}")
    volumes, builds = validate_construction(directory, data, variants=tuple(environment["variants"]))
    sizes = {row["case"]: row for row in volumes if row["variant"] == variant}
    for row in sizes.values():
        if row["kind"] == "application":
            original = row["original_bytes"]
            row["limit_bytes"] = size_limit(original)
            row["excess_bytes"] = max(0, row["bytes"] - row["limit_bytes"])
    scales = {}
    for case, size in sizes.items():
        if size["kind"] == "build":
            rows = [row for row in builds if row["case"] == case
                    and row["variant"] in (variant, f"{variant}-cli")]
            wall = max(row["wall_ns"] for row in rows)
            rss = max(row["peak_rss_kib"] for row in rows)
            scales[case] = dict(wall_ns=wall, peak_rss_kib=rss,
                                status="PASS" if wall <= 10_000_000_000 and rss <= 524288 else "FAIL")
    return environment, dict(layout=variant, environment_sha256=sha256(directory / "environment.json"),
                             sizes=sizes, scales=scales)


def compare(before, after, out, before_layout, host_record, replay):
    dataset = after / "dataset.json"
    if sha256(dataset) != DATASET_SHA256:
        raise ValueError("requires the frozen SIMD-free dataset")
    data = json.loads(dataset.read_bytes())
    cases = {case["id"]: case for case in data["entries"]
             if case["split"] == "tuning" and case["windows"]}
    before_env, first = construction(before, before_layout, data)
    after_env, second = construction(after, "join-span-compact", data)
    fields = ("tools", "host", "affinity", "stack", "uname", "clock", "wasmtime_lib_sha256")
    if (any(before_env[key] != after_env[key] for key in fields)
            or cpu_identity(before_env["cpuinfo"]) != cpu_identity(after_env["cpuinfo"])
            or any(before_env["binaries"][key] != after_env["binaries"][key] for key in ENGINES)):
        raise ValueError("different construction or timing environments")
    protocol = {**data["sampling"], "samples": PREFIX_PILOT_SAMPLES}
    cells = {(engine, name, window) for engine in ENGINES for name, case in cases.items()
             for window in case["windows"]}
    if not replay:
        run = Run(out)
    timing_digest = lock_timing_environment(out, after_env, protocol, host_record, replay)
    recorded = dict(before=first, after=second, protocol=protocol, timing_environment_sha256=timing_digest)
    if not replay:
        write_json(out / "inputs.json", recorded)
    elif json.loads((out / "inputs.json").read_bytes()) != recorded:
        raise ValueError("pilot inputs differ from the recorded construction archives")

    def checked_copy(source, dest, expected):
        if not replay:
            shutil.copyfile(source, dest)
        if sha256(dest) != expected:
            raise ValueError(f"pilot input digest mismatch: {dest}")

    workers = {key: out / name for key, name in WORKERS.items()}
    for key, binary in workers.items():
        checked_copy(after / binary.name, binary, after_env["binaries"][key])
        if not replay:
            binary.chmod(0o755)
    checked_copy(after / "libwasmtime.so", out / "libwasmtime.so", after_env["wasmtime_lib_sha256"])
    artifacts = {}
    for name in cases:
        path = out / name
        expected = path / "expected.stdout"
        if not replay:
            path.mkdir()
            expected.write_bytes(cases[name]["stdout"].encode("utf-8"))
        modules = [path / file for file in ("original.wasm", "before-0.wasm", "after-0.wasm")]
        checked_copy(after / name / "original.wasm", modules[0], cases[name]["sha256"])
        checked_copy(before / name / f"{before_layout}-0.wasm", modules[1], first["sizes"][name]["sha256"])
        checked_copy(after / name / "join-span-compact-0.wasm", modules[2], second["sizes"][name]["sha256"])
        artifacts[name] = (expected, modules)
    if not replay:
        with redirect_stdout(sys.stderr):
            measure(run, cases.values(), workers, artifacts, protocol, False, 0, VARIANTS)

    observations = defaultdict(dict)
    for key, values in checked_transcripts(out, VARIANTS, cases, protocol, 0, input_run=out, cells=cells):
        if key[0] != "sample":
            continue
        setup, entry, _, _ = values
        _, engine, name, window, group, cycle, variant = key
        if setup + entry <= 0:
            raise ValueError("nonpositive elapsed time")
        if cycle >= protocol["warmups"]:
            observations[engine, name, window][group, cycle, variant] = setup + entry
    rng = np.random.default_rng(protocol["bootstrap_seed"])
    rows = []
    for engine, name, window in sorted(cells):
        timings = observations[engine, name, window]
        groups = [[[timings[group, cycle, key] for key in VARIANTS]
                   for cycle in range(protocol["warmups"], protocol["warmups"] + protocol["samples"])]
                  for group in range(protocol["processes"])]
        points, draws = statistics(groups, protocol["bootstrap_draws"], rng)
        median, p95 = [interval(points[i, 2] / points[i, 1], draws[i, 2] / draws[i, 1]) for i in range(2)]
        status = None
        if window == "hot" and cases[name]["kind"] == "application":
            if first["sizes"][name]["sha256"] == second["sizes"][name]["sha256"]:
                status = "IDENTICAL_ARTIFACT"
            elif median["low"] > NOISE_LIMIT:
                status = "REGRESSION"
            elif median["high"] <= NOISE_LIMIT:
                status = "WITHIN_LIMIT"
            else:
                status = "INCONCLUSIVE"
        rows.append(dict(engine=engine, case=name, window=window, median=median, p95=p95, hot_status=status))
    statuses = {row["hot_status"] for row in rows}
    overall = next((status for status in ("REGRESSION", "INCONCLUSIVE") if status in statuses), "WITHIN_LIMIT")
    return dict(**recorded, rows=rows, hot_median_noise_limit=NOISE_LIMIT, hot_status=overall)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("before", type=Path)
    parser.add_argument("after", type=Path)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--before-layout", choices=("join-span-cached", "join-span-compact"),
                        default="join-span-compact")
    parser.add_argument("--host-record", type=Path)
    parser.add_argument("--replay", action="store_true")
    opts = parser.parse_args()
    if not opts.replay and opts.host_record is None:
        parser.error("live paired timing requires --host-record")
    report = compare(opts.before.resolve(), opts.after.resolve(), opts.out.resolve(),
                     opts.before_layout, opts.host_record, opts.replay)
    print(json.dumps(report, indent=2))

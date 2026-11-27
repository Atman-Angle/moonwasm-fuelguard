"""Benchmark tuning or a frozen candidate's independent holdout on Linux."""
import argparse
import hashlib
import inspect
import json
import os
import platform
import random
import re
import resource
import shutil
import signal
import subprocess
import sys
import time
from pathlib import Path

from dataset import (A17_HOLDOUT_MANIFEST, A17_HOLDOUT_SHA256, BENCH, DATASET_SHA256,
                     MANIFEST, ROOT, build_scale, check_start, sha256, write_json)
from performance_evidence import (FROZEN_BINARIES, FROZEN_LAYOUT, FUEL_V2_VARIANTS, PERFORMANCE_PROTOCOL, cases_for,
                                  configuration_digest, evidence_scope, json_digest, size_status,
                                  source_hashes, timing_protocol, verify_candidate_lock,
                                  verify_holdout_run)

VARIANTS = ("original", "fuel", "p0")
FORMAL_V2_VARIANTS = FUEL_V2_VARIANTS
P1_VARIANTS = ("original", "p0", "p1")
S20_VARIANTS = ("original", "fuel", "p0", "p1", "p2")
PREFIX_VARIANTS = ("original", "p2", "p2-prefix")
JOIN_VARIANTS = ("original", "p2-prefix", "join-span")
CACHED_JOIN_VARIANTS = (*JOIN_VARIANTS, "join-span-cached")
COMPACT_JOIN_VARIANTS = ("original", "join-span-cached", "join-span-compact")
COMPACT_V2_VARIANTS = ("original", "join-span-compact", "join-span-compact-v2")
S29_VARIANTS = (*S20_VARIANTS, "p2-prefix", "join-span", "join-span-cached", "join-span-compact")
PREFIX_PILOT_SAMPLES = 30
CODEGEN = {"p0": "inline-per-instruction-v1", "p1": "p1-helper-v1",
           "p2": "p2-hybrid-loop-inline-sites21-v1", "p2-prefix": "p2-prefix-exact-v1",
           "join-span": "join-span-debit-first-v1", "join-span-cached": "join-span-packed-cache-v1",
           "join-span-compact": "join-span-compact-v1", "join-span-compact-v2": "join-span-compact-v2",
           "fuel-v2": FROZEN_LAYOUT}
S29_LAYOUTS = tuple(variant for variant in S29_VARIANTS if variant in CODEGEN)
ENGINES = ("wasmoon", "wasmtime")
ORIGINAL_BUILD_STAGES = (
    "read", "preflight", "decode", "input_policy", "validate_input", "input_limits",
    "module_index", "meter_site_analysis", "rewrite_plan", "fuel_rewrite",
    "validate_fuel", "growth_rewrite", "validate_growth", "stack_rewrite",
    "validate_stack", "audit_and_marker", "validate_pipeline_output", "result",
    "validate_before_encode", "encode", "write",
)
AUDIT_STAGES = ("audit_references", "audit_validate_source", "audit_validate_output",
                "audit_stack_layout", "artifact_marker")
S18_BUILD_STAGES = (*ORIGINAL_BUILD_STAGES[:15], *AUDIT_STAGES, *ORIGINAL_BUILD_STAGES[16:])
BUILD_STAGES = (*S18_BUILD_STAGES[:9], "fuel_state", "validate_fuel_state", *S18_BUILD_STAGES[9:])
FUEL_STAGES = tuple(phase for phase in BUILD_STAGES if phase not in
                    ("stack_rewrite", "validate_stack", *AUDIT_STAGES))
FUEL_V2_BUILD_STAGES = (
    "read", "preflight", "decode", "input_policy", "validate_input", "input_limits",
    "module_index", "meter_site_analysis", "rewrite_plan", "fuel_state", "validate_fuel_state",
    "fuel_rewrite", "validate_fuel", "growth_rewrite", "validate_growth", "stack_rewrite",
    "validate_stack", "audit_references", "audit_stack_checks", "audit_validate_source",
    "audit_validate_output", "audit_stack_layout", "local_coalescing",
    "validate_local_coalescing", "post_local_coalescing_audit_validate_source",
    "post_local_coalescing_audit_validate_output", "post_local_coalescing_audit_stack_layout",
    "artifact_marker", "validate_pipeline_output",
    "result", "validate_before_encode", "encode", "write",
)
FUEL_V2_ONLY_STAGES = (
    "read", "preflight", "decode", "input_policy", "validate_input", "input_limits",
    "module_index", "meter_site_analysis", "rewrite_plan", "fuel_state", "validate_fuel_state",
    "fuel_rewrite", "validate_fuel", "growth_rewrite", "validate_growth",
    "validate_pipeline_output", "result",
    "validate_before_encode", "encode", "write",
)
HISTORICAL_DATASET_SHA256 = "de53b10ea85e3d714112fe46873135f563a58fa870b65bc40665b5efff37faa7"
BENCH_MOON_VERSION = "moon 0.1.20261104 (940aa18 2026-11-04)\n\nFeature flags enabled: rr_moon_mod,rr_moon_pkg"
S29_ENVIRONMENT_SHA256 = "67c4ff9963813333f8051be130667f56202649990cb5ae9fd7a5bf6ad8a0d427"
S29_ENVIRONMENT_FIELDS = ("dataset_sha256", "tools", "wasmtime_lib_sha256", "host",
                          "affinity", "stack", "uname", "distro", "python", "clock",
                          "wasmoon", "wasmtime")
S29_CHECKS = {"fuel-v1": "integration/p1/check.py", "fuel-v1.2": "integration/fuel_cache/check.py"}
S29_DETERMINISM_CASE = "F0-hello"
S29_DEBUG_CLI = "_build/wasm/debug/build/cmd/instrument/instrument.wasm"
S29_INITIAL_RUN_SHA256 = "25b8ffcfe2b44e373eec4a35ea2545034f57c179e87b566aafcca675ae49a1d4"
S29_INITIAL_SAMPLING_SHA256 = "89718123c62a15ef077e5d885388a150ebb3a465f29db53b8c1b7eb3ccb494b5"
FUEL = "9223372036854775807"
FD_WRITE = "wasi_snapshot_preview1.fd_write"


def fuel_model(variant):
    if variant == "fuel-v2":
        return "fuel-v2"
    return "fuel-v1.2" if variant in (*CACHED_JOIN_VARIANTS[2:], *COMPACT_V2_VARIANTS[1:]) else "fuel-v1"


class Run:
    def __init__(self, out):
        self.out = out
        out.mkdir(parents=True)
        self.commands = out / "commands.jsonl"

    def command(self, label, argv, *, cwd=ROOT, timeout=900):
        args = list(map(str, argv))
        print(label, flush=True)
        stdout = self.out / (label + ".stdout")
        stderr = self.out / (label + ".stderr")
        with stdout.open("wb") as out, stderr.open("wb") as err:
            start = time.monotonic_ns()
            proc = subprocess.Popen(args, cwd=cwd, stdin=subprocess.DEVNULL,
                                    stdout=out, stderr=err, start_new_session=True)

            def limit(_signal, _frame):
                try:
                    os.killpg(proc.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass

            previous = signal.signal(signal.SIGALRM, limit)
            signal.alarm(timeout)
            try:
                _, status, usage = os.wait4(proc.pid, 0)
                elapsed = time.monotonic_ns() - start
            except BaseException:
                limit(None, None)
                proc.wait()
                raise
            finally:
                signal.alarm(0)
                signal.signal(signal.SIGALRM, previous)
            proc.returncode = os.waitstatus_to_exitcode(status)
        row = dict(argv=args, cwd=str(cwd), status=proc.returncode, pid=proc.pid,
                   wall_ns=elapsed, peak_rss_kib=usage.ru_maxrss,
                   minor_faults=usage.ru_minflt, major_faults=usage.ru_majflt,
                   voluntary_switches=usage.ru_nvcsw, involuntary_switches=usage.ru_nivcsw,
                   stdout=stdout.name, stderr=stderr.name)
        with self.commands.open("a", encoding="utf-8") as log:
            log.write(json.dumps(row) + "\n")
        if proc.returncode != 0:
            raise RuntimeError(f"{label} exited {proc.returncode}, see {stdout} and {stderr}")
        return stdout.read_text(encoding="utf-8"), row


def read_dataset(scope="tuning", manifest=MANIFEST):
    expected = A17_HOLDOUT_SHA256 if manifest == A17_HOLDOUT_MANIFEST else DATASET_SHA256
    if sha256(manifest) != expected:
        raise ValueError("requires the selected frozen SIMD-free dataset manifest")
    data = json.loads(manifest.read_text(encoding="utf-8"))
    if data["schema"] != "fuelguard-bench-dataset-v1":
        raise ValueError("unexpected dataset")
    seen = set()
    for case in data["entries"]:
        if case["sha256"] in seen:
            raise ValueError(f"repeated module across dataset: {case['id']}")
        seen.add(case["sha256"])
        if case["split"] == scope and case["kind"] != "build":
            source = ROOT / case["path"]
            if source.stat().st_size != case["bytes"] or sha256(source) != case["sha256"]:
                raise ValueError(f"input changed: {case['id']}")
            check_start(source, case)
    return data


def check_s29_environment(path, current):
    if sha256(path) != S29_ENVIRONMENT_SHA256:
        raise ValueError("formal timing requires the archived S26 environment lock")
    reference = json.loads(path.read_bytes())
    for key in S29_ENVIRONMENT_FIELDS:
        if reference[key] != current[key]:
            raise ValueError(f"formal timing environment differs from S26: {key}")
    cpu_fields = r"^(?:processor|vendor_id|cpu family|model|model name|stepping|microcode)\s*:.*$"
    if re.findall(cpu_fields, reference["cpuinfo"], re.M) != re.findall(cpu_fields, current["cpuinfo"], re.M):
        raise ValueError("formal timing Linux CPU identity differs from S26")


def check_s29_sampling_source(initial, supplemental):
    # Review can change orchestration and replay while keeping the product
    # and both sampling methods identical. Keep both complete maps in evidence.
    scripts = {"bench/run.py", "bench/summarize.py"}
    reference, current = initial["source"], supplemental["source"]
    reference_sampling = initial.get("sampling_source_sha256")
    if reference_sampling is None and reference["bench/run.py"] == S29_INITIAL_RUN_SHA256:
        reference_sampling = S29_INITIAL_SAMPLING_SHA256
    current_sampling = supplemental.get("sampling_source_sha256")
    if current_sampling is None and current["bench/run.py"] == S29_INITIAL_RUN_SHA256:
        current_sampling = S29_INITIAL_SAMPLING_SHA256
    if (initial["head"] != supplemental["head"] or not reference_sampling
            or current_sampling != reference_sampling
            or {k: v for k, v in reference.items() if k not in scripts}
            != {k: v for k, v in current.items() if k not in scripts}):
        raise ValueError("S29 supplemental product or sampling source differs from the initial run")


def lock_run(run, data, binaries, lib, host_record, smoke, append_of, build_only, variants, cells,
             prior_supplements, source_revision, *, scope, candidate_lock_sha256, source,
             proposal_sha256, manifest):
    if platform.system() != "Linux" or platform.machine() != "x86_64":
        raise RuntimeError("benchmark requires Linux x86_64")
    host = json.loads(host_record.read_bytes())
    historical_environment = variants != FORMAL_V2_VARIANTS or (run.out / "s26-environment.json").is_file()
    if historical_environment and (
            host["ac"] is not True or "381b4222-f694-41f0-9685-ff5bb260df2e" not in host["scheme"]):
        raise ValueError("run requires AC power and the frozen balanced power scheme")
    affinity = os.sched_getaffinity(0)
    requested_cpu = data["sampling"]["cpu"]
    cpu = requested_cpu if historical_environment or requested_cpu in affinity else min(affinity)
    os.sched_setaffinity(0, {cpu})
    _, hard = resource.getrlimit(resource.RLIMIT_STACK)
    resource.setrlimit(resource.RLIMIT_STACK, (8388608, hard))
    for name, argv in (("moon", ["moon", "version"]),
                       ("wasm-tools", ["wasm-tools", "--version"])):
        stdout, _ = run.command("version-" + name, argv)
        # The corpus producer and the frozen Linux instrumenter are separate.
        expected = BENCH_MOON_VERSION if name == "moon" else data["toolchain"][name]
        if historical_environment and stdout.strip() != expected:
            raise RuntimeError(f"unfrozen tool version: {name}")
    tools = {}
    for name in ("gcc", "moon", "moonc", "moonrun", "wasm-tools", "wasmtime"):
        path = Path(shutil.which(name)).resolve()
        stdout, _ = run.command("identify-" + name, [path, "-v" if name == "moonc" else "--version"])
        tools[name] = {"sha256": sha256(path), "version": stdout.strip(), "path": str(path)}
    if not tools["wasmtime"]["version"].startswith("wasmtime 50.0.0 "):
        raise RuntimeError("requires Wasmtime 50.0.0")
    if source_revision is None:
        head, _ = run.command("git-head", ["git", "rev-parse", "HEAD"])
        source_revision = head.strip()
    shutil.copyfile(manifest, run.out / "dataset.json")
    frozen_workers = run.out / "frozen-workers.json"
    sampling_source = None
    if variants in (S29_VARIANTS, FORMAL_V2_VARIANTS):
        methods = "\n".join(inspect.getsource(method) for method in (Run.command, measure))
        sampling_source = hashlib.sha256(methods.encode()).hexdigest()
    write_json(run.out / "environment.json", dict(
        head=source_revision, source=source, dataset_sha256=sha256(manifest), smoke=smoke, build_only=build_only,
        variants=variants, cells=sorted(cells) if cells else None,
        append_of=sha256(append_of / "environment.json") if append_of else None,
        prior_supplements=[sha256(path / "environment.json") for path in prior_supplements],
        sampling_source_sha256=sampling_source,
        tools=tools, binaries={name: sha256(binary) for name, binary in binaries.items()},
        frozen_workers_sha256=sha256(frozen_workers) if frozen_workers.is_file() else None,
        wasmtime_lib_sha256=sha256(lib), uname=platform.uname()._asdict(), python=platform.python_version(),
        distro=Path("/etc/os-release").read_text(), cpuinfo=Path("/proc/cpuinfo").read_text(),
        memory=Path("/proc/meminfo").read_text(), host=host,
        affinity=sorted(os.sched_getaffinity(0)), stack=resource.getrlimit(resource.RLIMIT_STACK),
        clock=time.get_clock_info("monotonic").__dict__,
        start_utc_ns=time.time_ns(), load_before=os.getloadavg(),
        wasmoon="0.18.0; x64 JIT with cancellation-capable codegen, 16 MiB fiber",
        wasmtime="50.0.0 C API; Cranelift, no cache; fuel/epoch/parallel compilation off; 512 KiB Wasm stack",
        performance_scope=scope, candidate_lock_sha256=candidate_lock_sha256,
        configuration_sha256=configuration_digest(data), proposal_sha256=proposal_sha256,
        python_sha256=sha256(Path(sys.executable)),
    ))
    if (run.out / "s26-environment.json").is_file():
        current = json.loads((run.out / "environment.json").read_bytes())
        check_s29_environment(run.out / "s26-environment.json", current)


def populate(run, cases, builder, cli, build_processes, variants=VARIANTS):
    artifacts = {}
    builds = []
    volumes = []
    for case in cases:
        name = case["id"]
        path = run.out / name
        path.mkdir()
        original = path / "original.wasm"
        if case["kind"] == "build":
            build_scale(original, case["functions"], case["instructions"], case["bytes"])
        else:
            shutil.copyfile(ROOT / case["path"], original)
        if sha256(original) != case["sha256"]:
            raise ValueError(f"wrong copy: {name}")
        run.command(f"{name}-validate-original", ["wasm-tools", "validate", original])
        original_start = check_start(original, case)
        expected = path / "expected.stdout"
        expected.write_bytes(case["stdout"].encode("utf-8"))
        outputs = {"original": original}
        for variant in variants[1:]:
            for rep in range(build_processes):
                product = path / f"{variant}-{rep}.wasm"
                label = f"{name}-{variant}-build-{rep}"
                stdout, row = run.command(
                    label, native_build_argv(builder, variant, case, path, rep))
                phases = {phase: int(ns) for phase, ns in map(str.split, stdout.splitlines())}
                expected_stages = (FUEL_V2_ONLY_STAGES if variant == "fuel" else
                                   FUEL_V2_BUILD_STAGES if variant == "fuel-v2" else BUILD_STAGES)
                if tuple(phases) != expected_stages:
                    raise ValueError(f"incomplete construction phases: {label}")
                digest = sha256(product)
                if rep == 0:
                    outputs[variant] = product
                else:
                    if digest != sha256(outputs[variant]):
                        raise ValueError(f"non-deterministic build: {label}")
                    product.unlink()
                builds.append(dict(case=name, variant=variant, process=rep,
                                   phases_ns=phases, artifact_sha256=digest, **row))
            run.command(f"{name}-validate-{variant}", ["wasm-tools", "validate", outputs[variant]])
            check_start(outputs[variant], case, variant=variant, original_start=original_start)
        reports = {}
        for variant in (name for name in variants if name in CODEGEN):
            cli_product = path / f"cli-{variant}.wasm"
            report = path / manifest_name(variant)
            args = cli_build_argv(cli, variant, case, path, explicit_layout=variant != "fuel-v2")
            _, row = run.command(f"{name}-cli-{variant}", args)
            digest = sha256(outputs[variant])
            if sha256(cli_product) != digest:
                raise ValueError(f"native and wasm production path disagree: {name}/{variant}")
            cli_product.unlink()
            builds.append(dict(case=name, variant=f"{variant}-cli", artifact_sha256=digest, **row))
            if case["kind"] != "build":
                run.command(f"{name}-verify-{report.stem}",
                            ["moonrun", cli, "verify", outputs[variant], "--report", report])
                details = json.loads(report.read_bytes())
                passes_match = ("passes" not in details if variant == "fuel-v2" else
                                details.get("passes") == ["FuelPass", "GrowthPass", "StackPass"])
                expected_schema = "fuelguard-manifest-v2" if variant == "fuel-v2" else "fuelguard-manifest-v1"
                if (details.get("schema") != expected_schema
                        or (variant == "fuel-v2" and details.get("deterministic") is not True)
                        or details.get("input_sha256") != case["sha256"]
                        or details.get("output_sha256") != digest
                        or not passes_match
                        or details["instrumentation"]["codegen"] != CODEGEN[variant]
                        or details["instrumentation"]["fuel_model"] != fuel_model(variant)):
                    raise ValueError(f"wrong production metadata: {name}/{variant}")
                reports[variant] = report.stat().st_size
        for variant, artifact in outputs.items():
            size = artifact.stat().st_size
            limit = original.stat().st_size
            status = size_status(limit, size)
            volumes.append(dict(case=name, kind=case["kind"], variant=variant, bytes=size,
                                sha256=sha256(artifact), original_bytes=limit,
                                a19=status if case["kind"] == "application" and variant in CODEGEN else None,
                                sidecar_bytes=reports.get(variant)))
        artifacts[name] = (expected, [outputs[key] for key in variants])
        write_json(run.out / "builds.json", builds)
        write_json(run.out / "volumes.json", volumes)
    return artifacts


def manifest_name(variant):
    return "manifest.json" if variant == "p0" else f"manifest-{variant}.json"


def native_build_argv(builder, variant, case, path, rep):
    return [builder, variant, path / "original.wasm", path / f"{variant}-{rep}.wasm",
            case["stack_units"], case["depth"], int(bool(case["stdout"]))]


def cli_build_argv(cli, variant, case, path, *, explicit_layout=True, suffix=""):
    args = ["moonrun", cli, path / "original.wasm", "-o", path / f"cli-{variant}{suffix}.wasm",
            "--profile", "production-v1", "--fuel", FUEL, "--max-stack-units",
            case["stack_units"], "--max-call-depth", case["depth"],
            "--max-memory-pages", "64", "--max-table-elements", "64"]
    if explicit_layout:
        args += ["--codegen", variant]
    if fuel_model(variant) == "fuel-v1.2":
        args += ["--cost-model", fuel_model(variant)]
    if case["stdout"]:
        args += ["--allow-import", FD_WRITE]
    if case["kind"] != "build":
        name = Path(manifest_name(variant))
        args += ["--report", path / f"{name.stem}{suffix}.json"]
    return args


def run_s29_checks(run, cases, cli):
    wasmoon = shutil.which("wasmoon")
    if wasmoon is None:
        raise RuntimeError("S29 A18 requires the wasmoon 0.18.0 CLI")
    command = [Path(wasmoon).resolve(), "--version"]
    version, _ = run.command("version-wasmoon-a18", command)
    if not re.search(r"(?<![\d.])0\.18\.0(?![\d.])", version):
        raise ValueError("S29 A18 requires the wasmoon 0.18.0 CLI")
    shutil.copy2(command[0], run.out / "wasmoon-a18")
    write_json(run.out / "wasmoon-a18.json", dict(
        path=str(command[0]), version=version.strip(), sha256=sha256(run.out / "wasmoon-a18")))
    for model, script in S29_CHECKS.items():
        run.command(f"a18-{model}", [sys.executable, "-E", "-B", script, "--out",
                                     run.out / f"a18-{model}"])
    shutil.copy2(ROOT / S29_DEBUG_CLI, run.out / "a18-instrument.wasm")
    case = next(case for case in cases if case["id"] == S29_DETERMINISM_CASE)
    path = run.out / case["id"]
    for variant in S29_LAYOUTS:
        expected = (sha256(path / f"{variant}-0.wasm"), sha256(path / manifest_name(variant)))
        for repetition in (2, 3):
            suffix = f"-repro-{repetition}"
            args = cli_build_argv(cli, variant, case, path, suffix=suffix)
            run.command(f"a16-{variant}{suffix}", args)
            if (sha256(Path(args[4])), sha256(Path(args[-1]))) != expected:
                raise ValueError(f"S29 CLI output or manifest is nondeterministic: {variant}")


def measure(run, cases, workers, artifacts, protocol, smoke, first_group, variants=VARIANTS, cells=None):
    warmup = 1 if smoke else protocol["warmups"]
    count = 2 if smoke else protocol["samples"]
    size = 1 if smoke else protocol["processes"]
    nvariants = len(variants)
    jobs = [(engine, case, window, batch, group)
            for engine in ENGINES for case in cases for window, batch in case["windows"].items()
            for group in range(first_group, first_group + size)
            if cells is None or (engine, case["id"], window) in cells]
    random.Random(f"{protocol['schedule_seed']}/{first_group}").shuffle(jobs)
    with (run.out / "samples.jsonl").open("w", encoding="utf-8") as output:
        for engine, case, window, batch, group in jobs:
            name = case["id"]
            label = f"{name}-{engine}-{window}-{group}"
            generator = random.Random(f"{protocol['schedule_seed']}/{label}")
            cycles = [generator.sample(range(nvariants), nvariants) for _ in range(warmup + count)]
            order = bytes(i for cycle in cycles for i in cycle)
            schedule = run.out / (label + ".schedule")
            schedule.write_bytes(order)
            expected, modules = artifacts[name]
            value = case["result_i32"]
            stdout, process = run.command(label, [
                workers[engine], schedule, window, batch, int(bool(case["stdout"])),
                case["entry"] or "-", value if value is not None else "-", expected, *modules])
            lines = stdout.splitlines()
            if len(lines) != len(order) + nvariants or (run.out / process["stderr"]).stat().st_size:
                raise ValueError(f"invalid engine transcript: {label}")
            for variant, line in zip(variants, lines[:nvariants], strict=True):
                match = re.fullmatch(r"compile (\d+) (\d+) (\d+)", line)
                if not match:
                    raise ValueError(f"invalid compile row: {label}: {line}")
                load, jit, verify = map(int, match.groups())
                row = dict(kind="compile", case=name, engine=engine, window=window, group=group,
                           variant=variant, pid=process["pid"], parse_or_read_ns=load,
                           jit_ns=jit, verify_ns=verify, process_peak_rss_kib=process["peak_rss_kib"])
                output.write(json.dumps(row) + "\n")
            for index, (variant_index, line) in enumerate(zip(order, lines[nvariants:], strict=True)):
                match = re.fullmatch(r"sample (\d) (\d+) (\d+)", line)
                if not match:
                    raise ValueError(f"invalid sample row: {label}: {line}")
                actual, instantiate, execute = map(int, match.groups())
                total = instantiate + execute
                if variant_index != actual or total <= 0 or (window == "hot" and instantiate):
                    raise ValueError(f"sample order or time mismatch: {label}")
                cycle, position = divmod(index, nvariants)
                row = dict(kind="sample", case=name, engine=engine, window=window, group=group,
                           variant=variants[actual], pid=process["pid"], cycle=cycle,
                           position=position, batch=batch, warmup=cycle < warmup,
                           instantiate_start_ns=instantiate, entry_ns=execute, total_ns=total)
                output.write(json.dumps(row) + "\n")
            output.flush()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--wasmtime-c-api", required=True, type=Path)
    parser.add_argument("--host-record", required=True, type=Path)
    parser.add_argument("--source-revision",
                        help="Git HEAD captured before copying a frozen source tree without .git metadata")
    parser.add_argument("--frozen-workers", type=Path,
                        help="reuse verified engine binaries from an archived run on this dataset")
    parser.add_argument("--s26-environment", type=Path,
                        help="archived S26 environment.json required for S29")
    comparison = parser.add_mutually_exclusive_group()
    comparison.add_argument("--compare-p1", action="store_true", help="interleave original, P0 and P1")
    comparison.add_argument("--compare-layouts", action="store_true",
                            help="interleave original, fuel-only P0 and all full layouts")
    comparison.add_argument("--compare-s29", action="store_true",
                            help="formally compare all seven full layouts on the frozen tuning split")
    comparison.add_argument("--compare-fuel-v2", action="store_true",
                            help="measure the single production Fuel v2 layout")
    comparison.add_argument("--compare-prefix", action="store_true",
                            help="pilot the exact prefix candidate against P2 and the original")
    comparison.add_argument("--compare-join-span", action="store_true",
                            help="pilot fuel-v1.2 against p2-prefix and the original")
    comparison.add_argument("--compare-join-cached", action="store_true",
                            help="pilot cached fuel-v1.2 against the frozen join-span layout")
    comparison.add_argument("--compare-join-compact", action="store_true",
                            help="pilot compact fuel-v1.2 against cached fuel-v1.2 and the original")
    comparison.add_argument("--compare-join-compact-v2", action="store_true",
                            help="pilot compact v2 against compact v1 and the original")
    parser.add_argument("--smoke", action="store_true")
    parser.add_argument("--build-only", action="store_true", help="refresh all construction evidence")
    parser.add_argument("--append-to", type=Path, nargs="+", metavar="RUN",
                        help="append three processes per cell to an initial run and any ordered S29 supplements")
    parser.add_argument("--cell", action="append", nargs=3, metavar=("ENGINE", "CASE", "WINDOW"),
                        help="with --append-to, sample only the specified borderline cells")
    parser.add_argument("--holdout", action="store_true",
                        help="independently confirm a frozen production Fuel v2 candidate")
    parser.add_argument("--candidate-lock", type=Path, help="pre-existing candidate freeze record")
    parser.add_argument("--candidate-run", type=Path, help="validated tuning archive named by the freeze")
    parser.add_argument("--a17-holdout-dataset", action="store_true",
                        help="use the fresh, frozen A17 holdout split with Fuel v2")
    opts = parser.parse_args()
    scope = "holdout" if opts.holdout else "tuning"
    if opts.a17_holdout_dataset and not opts.compare_fuel_v2:
        parser.error("--a17-holdout-dataset requires --compare-fuel-v2")
    manifest = A17_HOLDOUT_MANIFEST if opts.a17_holdout_dataset else MANIFEST
    if opts.holdout:
        if (not opts.compare_fuel_v2 or not opts.candidate_lock or not opts.candidate_run
                or opts.smoke or opts.build_only or opts.frozen_workers or opts.s26_environment
                or opts.append_to):
            parser.error("--holdout requires --compare-fuel-v2, --candidate-lock and --candidate-run "
                         "with one fixed sampling run and frozen workers")
    elif opts.candidate_lock or opts.candidate_run:
        parser.error("candidate freeze options require --holdout")
    pilot = opts.compare_prefix or opts.compare_join_span or opts.compare_join_cached or opts.compare_join_compact or opts.compare_join_compact_v2
    if pilot and (opts.smoke or opts.append_to):
        parser.error("pilot comparisons use their own sampling protocol")
    formal_mode = opts.compare_s29 or opts.compare_fuel_v2
    if (opts.compare_s29 and not opts.s26_environment) or (opts.s26_environment and not formal_mode):
        parser.error("--compare-s29 requires --s26-environment; Fuel v2 tuning can also use it")
    if opts.compare_s29 and opts.frozen_workers:
        parser.error("--compare-s29 builds its nine-module workers from the frozen source")
    if opts.cell and not opts.append_to:
        parser.error("--cell requires --append-to")
    if opts.append_to and (opts.build_only or opts.smoke):
        parser.error("--append-to requires a formal timing run")
    prior_supplements = []
    if opts.append_to:
        opts.append_to, *prior_supplements = (path.resolve() for path in opts.append_to)
        if prior_supplements and not formal_mode:
            parser.error("only formal comparisons accept a chain of supplemental runs")
        history = [opts.append_to, *prior_supplements]
        if any(path.parent != opts.out.resolve().parent for path in history):
            parser.error("initial and supplemental run directories must share a parent")
        if len(set([*history, opts.out.resolve()])) != len(history) + 1:
            parser.error("supplemental runs require distinct output directories")
    source = source_hashes()
    proposal_sha256 = sha256(PERFORMANCE_PROTOCOL)
    if opts.holdout:
        archive = opts.candidate_run.resolve()
        freeze_sha = sha256(opts.candidate_lock)
        identity, _ = verify_candidate_lock(opts.candidate_lock, archive / "environment.json",
                                            archive / "finished.json")
        if (identity["source_sha256"] != json_digest(source)
                or identity["proposal_sha256"] != proposal_sha256
                or (opts.source_revision and opts.source_revision != identity["head"])):
            raise ValueError("working source or proposal differs from the frozen candidate")
        opts.source_revision = identity["head"]
        from summarize import reconstruct, validate_construction

        archived_dataset, archived_variants, *_ = reconstruct([archive])
        validate_construction(archive, archived_dataset, variants=archived_variants)
    lib = opts.wasmtime_c_api.resolve() / "lib/libwasmtime.so"
    if sha256(lib) != "3127ca42fe7cdd3f0a43a358e79177dcfedd46c1746329826403b9d854de6178":
        raise ValueError("requires the frozen Wasmtime 50.0.0 Linux x86_64 C API library")
    data = read_dataset(scope, manifest)
    protocol = timing_protocol(data, scope)
    variants = (S29_VARIANTS if opts.compare_s29 else FORMAL_V2_VARIANTS if opts.compare_fuel_v2
                else COMPACT_V2_VARIANTS if opts.compare_join_compact_v2
                else COMPACT_JOIN_VARIANTS if opts.compare_join_compact
                else CACHED_JOIN_VARIANTS if opts.compare_join_cached else JOIN_VARIANTS if opts.compare_join_span
                else PREFIX_VARIANTS if opts.compare_prefix
                else S20_VARIANTS if opts.compare_layouts else P1_VARIANTS if opts.compare_p1 else VARIANTS)
    if pilot:
        protocol = {**protocol, "samples": PREFIX_PILOT_SAMPLES}
    cases = cases_for(data, scope)
    cells = {tuple(cell) for cell in opts.cell} if opts.cell else None
    available = {(engine, case["id"], window) for engine in ENGINES
                 for case in cases for window in case["windows"]}
    if cells is not None and not cells.issubset(available):
        parser.error("--cell must select an engine and an applicable window of the selected split")
    if formal_mode and opts.append_to:
        from summarize import summarize

        selection = summarize([opts.append_to, *prior_supplements])
        previous = json.loads((opts.append_to / "environment.json").read_bytes())
        if (evidence_scope(previous) != scope
                or previous.get("candidate_lock_sha256") != (freeze_sha if opts.holdout else None)):
            parser.error("supplement must use the initial run's scope and freeze record")
        required = {tuple(cell) for cell in selection["borderline_cells"]}
        if not required or (cells is not None and cells != required):
            parser.error("formal supplements must cover exactly the preceding report's borderline cells")
        cells = required
    run = Run(opts.out.resolve())
    workspace = BENCH / "native"
    native = workspace / "_build/native/release/build/Atman-Angle/fuelguard-bench"
    workers = {}
    reuse_formal = (archive if opts.holdout else opts.append_to) if formal_mode else None
    if not reuse_formal:
        run.command("build-worker-build", ["moon", "build", "--target", "native",
                    "--release", "build"], cwd=workspace)
        workers["build"] = shutil.copy2(native / "build/build.exe", run.out / "build")
    if opts.s26_environment:
        shutil.copyfile(opts.s26_environment, run.out / "s26-environment.json")
    if reuse_formal:
        previous = json.loads((reuse_formal / "environment.json").read_bytes())
        for key, name in FROZEN_BINARIES.items():
            binary = reuse_formal / name
            if sha256(binary) != previous["binaries"][key]:
                raise ValueError(f"frozen run binary changed: {key}")
            workers[key] = shutil.copy2(binary, run.out / name)
    elif opts.frozen_workers:
        archive = opts.frozen_workers.resolve()
        record = archive / "environment.json"
        env = json.loads(record.read_bytes())
        if (env["dataset_sha256"] != sha256(manifest)
                or sha256(archive / "dataset.json") != env["dataset_sha256"]
                or env["wasmtime_lib_sha256"] != sha256(lib)
                or sha256(archive / "libwasmtime.so") != env["wasmtime_lib_sha256"]):
            raise ValueError("frozen engine archive uses a different corpus or Wasmtime library")
        for engine, name in (("wasmoon", "wasmoon"), ("wasmtime", "wasmtime-worker")):
            binary = archive / name
            if sha256(binary) != env["binaries"][engine]:
                raise ValueError(f"frozen engine worker hash disagrees with its archive: {engine}")
            workers[engine] = shutil.copy2(binary, run.out / name)
        shutil.copyfile(record, run.out / "frozen-workers.json")
    else:
        run.command("build-worker-wasmoon", ["moon", "build", "--target", "native",
                    "--release", "wasmoon"], cwd=workspace)
        workers["wasmoon"] = shutil.copy2(native / "wasmoon/wasmoon.exe", run.out / "wasmoon")
        c_api = opts.wasmtime_c_api.resolve()
        workers["wasmtime"] = run.out / "wasmtime-worker"
        run.command("build-worker-wasmtime", [
            "gcc", "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror", "-I", c_api / "include",
            BENCH / "wasmtime.c", "-L", c_api / "lib", "-Wl,-rpath,$ORIGIN",
            "-lwasmtime", "-o", workers["wasmtime"]])
    if not reuse_formal:
        run.command("build-instrument-cli", ["moon", "build", "--target", "wasm", "--release",
                                           "cmd/instrument"])
        cli = ROOT / "_build/wasm/release/build/cmd/instrument/instrument.wasm"
        workers["cli"] = shutil.copy2(cli, run.out / "instrument.wasm")
    shutil.copy2(lib, run.out / lib.name)
    if opts.holdout:
        shutil.copyfile(opts.candidate_lock, run.out / "candidate-lock.json")
        for name in ("environment", "finished"):
            shutil.copyfile(archive / f"{name}.json", run.out / f"candidate-tuning-{name}.json")
    lock_run(run, data, workers, lib, opts.host_record, opts.smoke, opts.append_to, opts.build_only,
             variants, cells, prior_supplements, opts.source_revision, scope=scope,
             candidate_lock_sha256=freeze_sha if opts.holdout else None,
             source=source, proposal_sha256=proposal_sha256, manifest=manifest)
    if opts.holdout:
        verify_holdout_run(run.out, json.loads((run.out / "environment.json").read_bytes()))
    if pilot:
        write_json(run.out / "pilot-protocol.json", protocol)
    if opts.append_to:
        previous = json.loads((opts.append_to / "environment.json").read_bytes())
        current = json.loads((run.out / "environment.json").read_bytes())
        fields = ("binaries", "dataset_sha256", "tools", "wasmtime_lib_sha256",
                  "host", "affinity", "stack", "uname")
        if (previous.get("append_of") or previous.get("build_only")
                or tuple(previous.get("variants", VARIANTS)) != variants
                or previous["smoke"] or opts.smoke or any(previous[key] != current[key] for key in fields)):
            raise ValueError("appended run differs from the frozen environment")
        if formal_mode:
            check_s29_sampling_source(previous, current)
        from summarize import validate_construction

        validate_construction(opts.append_to, data, variants=variants)
        artifacts = {}
        for case in cases:
            if case["windows"]:
                directory = opts.append_to / case["id"]
                expected = directory / "expected.stdout"
                if expected.read_bytes() != case["stdout"].encode("utf-8"):
                    raise ValueError(f"changed stdout oracle: {case['id']}")
                artifacts[case["id"]] = (expected, [directory / name for name in
                    ("original.wasm" if variant == "original" else f"{variant}-0.wasm"
                     for variant in variants)])
        first_group = protocol["processes"] * (1 + len(prior_supplements))
    else:
        artifacts = populate(run, cases, workers["build"], workers["cli"],
                             1 if opts.smoke else protocol["build_processes"], variants)
        if opts.compare_s29 and not opts.smoke:
            from summarize import validate_construction

            validate_construction(run.out, data, variants=variants, in_progress=True)
            run_s29_checks(run, cases, workers["cli"])
        first_group = 0
    if not opts.build_only:
        measure(run, cases, workers, artifacts, protocol, opts.smoke, first_group, variants, cells)
    if source_hashes() != source or sha256(PERFORMANCE_PROTOCOL) != proposal_sha256:
        raise ValueError("source or proposal changed during the benchmark")
    write_json(run.out / "finished.json", dict(
        finish_utc_ns=time.time_ns(), load_after=os.getloadavg(),
        samples_sha256=None if opts.build_only else sha256(run.out / "samples.jsonl"),
        environment_sha256=sha256(run.out / "environment.json"),
        commands_sha256=sha256(run.commands),
        builds_sha256=None if opts.append_to else sha256(run.out / "builds.json"),
        volumes_sha256=None if opts.append_to else sha256(run.out / "volumes.json"),
    ))


if __name__ == "__main__":
    main()

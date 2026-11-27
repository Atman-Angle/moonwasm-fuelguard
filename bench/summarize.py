"""Replay tuning statistics and gates from process-group raw observations."""
import argparse
import json
import math
import random
import re
import sys
from collections import Counter, defaultdict
from pathlib import Path

import numpy as np

from dataset import A17_HOLDOUT_SHA256, check_start, instrumentation_markers, sha256, wasm_start
from performance_evidence import (cases_for, configuration_digest, create_candidate_lock, evidence_scope,
                                  json_digest, performance_result, size_status, timing_protocol,
                                  verify_finished, verify_holdout_run)
from run import (AUDIT_STAGES, BUILD_STAGES, CODEGEN, DATASET_SHA256, ENGINES, FUEL_STAGES,
                 CACHED_JOIN_VARIANTS, COMPACT_JOIN_VARIANTS, COMPACT_V2_VARIANTS, HISTORICAL_DATASET_SHA256, JOIN_VARIANTS,
                 ORIGINAL_BUILD_STAGES, P1_VARIANTS, PREFIX_PILOT_SAMPLES, PREFIX_VARIANTS,
                 S18_BUILD_STAGES, S20_VARIANTS, S29_VARIANTS, S29_CHECKS, S29_DEBUG_CLI, S29_LAYOUTS,
                 FUEL_V2_BUILD_STAGES, FUEL_V2_ONLY_STAGES,
                 S29_DETERMINISM_CASE, FORMAL_V2_VARIANTS, VARIANTS, check_s29_environment, check_s29_sampling_source,
                 cli_build_argv, fuel_model, manifest_name, native_build_argv)

QUANTILES = (0.5, 0.95)
JOIN_PILOTS = (JOIN_VARIANTS, CACHED_JOIN_VARIANTS, COMPACT_JOIN_VARIANTS, COMPACT_V2_VARIANTS)


def interval(point, draws):
    low, high = np.quantile(draws, [0.025, 0.975], method="linear")
    return dict(point=float(point), low=float(low), high=float(high))


def gate(result, limit):
    if result["high"] <= limit:
        return "PASS"
    return "FAIL"


def borderline(result, limit):
    return result["low"] <= limit < result["high"]


def statistics(groups, draws, rng, *, clustered=True):
    # Axes: matched independent process groups, interleaved cycles, variants.
    array = np.asarray(groups, dtype=np.float64)
    nprocess, nsample, nvariant = array.shape
    points = np.quantile(array.reshape(-1, nvariant), QUANTILES, axis=0, method="linear")
    sampled = np.empty((2, nvariant, draws))
    for start in range(0, draws, 128):
        size = min(128, draws - start)
        processes = rng.integers(nprocess, size=(size, nprocess, 1))
        # Keep each process's full ordered series and interleaved variants together.
        # Older layout comparisons keep their historical replay method.
        cycles = np.arange(nsample) if clustered else rng.integers(
            nsample, size=(size, nprocess, nsample))
        replicate = array[processes, cycles].reshape(size, -1, nvariant)
        sampled[:, :, start:start + size] = np.quantile(
            replicate, QUANTILES, axis=1, method="linear").transpose(0, 2, 1)
    return points, sampled


def checked_transcripts(run, variants, cases, protocol, first_group, *, input_run, cells):
    """Bind every evidence row to its timed process, seed schedule and module argv."""
    commands = {}
    for line in (run / "commands.jsonl").read_text(encoding="utf-8").splitlines():
        command = json.loads(line)
        stdout = command["stdout"]
        if stdout in commands:
            raise ValueError(f"duplicate command transcript: {stdout}")
        commands[stdout] = command
    pids = set()
    for engine in ENGINES:
        for case, metadata in cases.items():
            window_batches = metadata["windows"]
            for window, batch in window_batches.items():
                if (engine, case, window) not in cells:
                    continue
                for group in range(first_group, first_group + protocol["processes"]):
                    stem = f"{case}-{engine}-{window}-{group}"
                    command = commands.get(stem + ".stdout")
                    if not command or command["status"] != 0 or command["stderr"] != stem + ".stderr":
                        raise ValueError(f"missing successful worker command: {stem}")
                    pid = command["pid"]
                    if pid in pids:
                        raise ValueError(f"reused worker PID in one run: {pid}")
                    pids.add(pid)
                    argv = command["argv"]
                    worker = engine if engine == "wasmoon" else "wasmtime-worker"
                    directory = Path(argv[0]).parent
                    measured_modules = Path(argv[-1]).parent
                    # Keep archive replay independent of the original absolute prefix.
                    # Native runs refer to their own derived bytes; appends refer to the initial run.
                    expected_modules = [str(measured_modules / (
                        "original.wasm" if variant == "original" else f"{variant}-0.wasm"))
                        for variant in variants]
                    scalar = metadata["result_i32"]
                    expected_argv = [
                        str(directory / worker), str(directory / (stem + ".schedule")),
                        window, str(batch), str(int(bool(metadata["stdout"]))),
                        metadata["entry"] or "-", "-" if scalar is None else str(scalar),
                        str(measured_modules / "expected.stdout"), *expected_modules,
                    ]
                    if (argv != expected_argv or measured_modules.name != case
                            or measured_modules.parent != directory.parent / input_run.name
                            or directory.name != run.name):
                        raise ValueError(f"worker argv differs from the frozen design: {stem}")
                    if (input_run / case / "expected.stdout").read_bytes() != metadata["stdout"].encode("utf-8"):
                        raise ValueError(f"worker oracle differs from the frozen expectation: {case}")
                    gen = random.Random(f"{protocol['schedule_seed']}/{stem}")
                    cycles = protocol["warmups"] + protocol["samples"]
                    order = bytes(variant for _ in range(cycles)
                                  for variant in gen.sample(range(len(variants)), len(variants)))
                    if (run / (stem + ".schedule")).read_bytes() != order:
                        raise ValueError(f"worker schedule disagrees with frozen seed: {stem}")
                    lines = (run / command["stdout"]).read_text(encoding="utf-8").splitlines()
                    if len(lines) != len(order) + len(variants) or (run / command["stderr"]).stat().st_size:
                        raise ValueError(f"worker transcript is incomplete: {stem}")
                    key = (engine, case, window, group)
                    for variant, line in zip(variants, lines[:len(variants)], strict=True):
                        match = re.fullmatch(r"compile (\d+) (\d+) (\d+)", line)
                        if not match:
                            raise ValueError(f"invalid compilation transcript: {stem}")
                        yield ("compile", *key, variant), (*map(int, match.groups()), pid,
                            command["peak_rss_kib"])
                    for index, (choice, line) in enumerate(zip(order, lines[len(variants):], strict=True)):
                        match = re.fullmatch(r"sample (\d+) (\d+) (\d+)", line)
                        if not match:
                            raise ValueError(f"invalid timing transcript: {stem}")
                        actual, setup, entry = map(int, match.groups())
                        if actual != choice or (window == "hot" and setup):
                            raise ValueError(f"worker did not follow the schedule: {stem}")
                        cycle, position = divmod(index, len(variants))
                        yield ("sample", *key, cycle, variants[choice]), (setup, entry, pid, position)

def reconstruct(runs):
    first = runs[0]
    dataset_digest = sha256(first / "dataset.json")
    if dataset_digest not in (DATASET_SHA256, HISTORICAL_DATASET_SHA256, A17_HOLDOUT_SHA256):
        raise ValueError("raw run does not match the frozen dataset")
    frozen = json.loads((first / "dataset.json").read_bytes())
    first_env_path = first / "environment.json"
    first_env = json.loads(first_env_path.read_bytes())
    scope = evidence_scope(first_env)
    if scope == "holdout" and len(runs) != 1:
        raise ValueError("holdout uses one fixed sample size")
    protocol = timing_protocol(frozen, scope)
    case_metadata = {case["id"]: case for case in cases_for(frozen, scope) if case["windows"]}
    expected = {(engine, case, window) for engine in ENGINES
                for case, metadata in case_metadata.items() for window in metadata["windows"]}
    variants = tuple(first_env.get("variants", VARIANTS))
    formal_v2 = variants == FORMAL_V2_VARIANTS
    if dataset_digest == A17_HOLDOUT_SHA256 and not formal_v2:
        raise ValueError("the fresh A17 holdout dataset requires the Fuel v2 layout")
    if variants not in (S29_VARIANTS, FORMAL_V2_VARIANTS) and len(runs) > 2:
        raise ValueError("only formal comparisons support multiple supplemental runs")
    if variants in (*JOIN_PILOTS, S29_VARIANTS) and dataset_digest != DATASET_SHA256:
        raise ValueError("join-span comparison requires the SIMD-free dataset")
    if variants in (PREFIX_VARIANTS, *JOIN_PILOTS):
        protocol = {**protocol, "samples": PREFIX_PILOT_SAMPLES}
        if len(runs) != 1 or json.loads((first / "pilot-protocol.json").read_bytes()) != protocol:
            raise ValueError("unexpected pilot protocol")
    elif variants not in (VARIANTS, P1_VARIANTS, S20_VARIANTS, S29_VARIANTS, FORMAL_V2_VARIANTS):
        raise ValueError(f"unexpected variants: {variants}")
    count = protocol["samples"]
    warmup = protocol["warmups"]
    groups = defaultdict(dict)
    phases = defaultdict(list)
    compilation = defaultdict(list)
    group_ids = defaultdict(list)
    for index, run in enumerate(runs):
        env = json.loads((run / "environment.json").read_bytes())
        if (tuple(env.get("variants", VARIANTS)) != variants or env["smoke"]
                or env["dataset_sha256"] != dataset_digest
                or sha256(run / "dataset.json") != dataset_digest
                or evidence_scope(env) != scope
                or env.get("candidate_lock_sha256") != first_env.get("candidate_lock_sha256")
                or ("performance_scope" in env and
                    env["configuration_sha256"] != configuration_digest(frozen))):
            raise ValueError("run has no matching formal dataset")
        if env.get("build_only"):
            raise ValueError("construction-only evidence has no timing run")
        for key, name in (("wasmoon", "wasmoon"), ("wasmtime", "wasmtime-worker")):
            if sha256(run / name) != env["binaries"][key]:
                raise ValueError(f"archived worker binary disagrees with environment: {name}")
        if sha256(run / "libwasmtime.so") != env["wasmtime_lib_sha256"]:
            raise ValueError("archived Wasmtime library disagrees with environment")
        ref_sha = env.get("frozen_workers_sha256")
        if (variants == S29_VARIANTS
                or (formal_v2 and ("performance_scope" not in env
                                   or (run / "s26-environment.json").is_file()))):
            check_s29_environment(run / "s26-environment.json", env)
        if index and variants in (S29_VARIANTS, FORMAL_V2_VARIANTS):
            check_s29_sampling_source(first_env, env)
        if scope == "holdout":
            verify_holdout_run(run, env)
        if ref_sha:
            reference = run / "frozen-workers.json"
            previous = json.loads(reference.read_bytes())
            if (sha256(reference) != ref_sha
                    or previous["dataset_sha256"] != dataset_digest
                    or previous["wasmtime_lib_sha256"] != env["wasmtime_lib_sha256"]
                    or any(previous["binaries"][engine] != env["binaries"][engine] for engine in ENGINES)):
                raise ValueError("frozen worker provenance differs from the run")
        if index and (env.get("append_of") != sha256(first_env_path) or any(
                env[field] != first_env[field] for field in
                ("binaries", "tools", "wasmtime_lib_sha256", "host", "affinity", "stack", "uname"))):
            raise ValueError("appended samples used a different performance environment")
        if variants in (S29_VARIANTS, FORMAL_V2_VARIANTS) and (env.get("append_of") != (sha256(first_env_path) if index else None)
                or env.get("prior_supplements", []) !=
                [sha256(prior / "environment.json") for prior in runs[1:index]]):
            raise ValueError("formal supplemental history differs from the archived runs")
        subset = env.get("cells")
        selected = {tuple(cell) for cell in subset} if subset is not None else expected
        if not selected or not selected.issubset(expected) or (index == 0 and subset is not None):
            raise ValueError("invalid supplemental timing cells")
        finish = json.loads((run / "finished.json").read_bytes())
        verify_finished(run, env, finish)
        path = run / "samples.jsonl"
        if finish["samples_sha256"] != sha256(path):
            raise ValueError("raw sample file changed")
        ids = range(index * protocol["processes"], (index + 1) * protocol["processes"])
        for key in selected:
            group_ids[key].extend(ids)
        transcript = dict(checked_transcripts(
            run, variants, case_metadata, protocol, ids.start, input_run=first, cells=selected))
        sample_keys = set()
        for line in path.read_text(encoding="utf-8").splitlines():
            row = json.loads(line)
            key = (row["engine"], row["case"], row["window"])
            if row["kind"] == "compile":
                if key not in selected or row["group"] not in ids or row["variant"] not in variants:
                    raise ValueError("unexpected compilation row")
                actual = (row["parse_or_read_ns"], row["jit_ns"], row["verify_ns"],
                          row["pid"], row["process_peak_rss_kib"])
                if transcript.pop(("compile", *key, row["group"], row["variant"]), None) != actual:
                    raise ValueError("compilation row differs from the worker transcript")
                compilation[*key, row["variant"]].append(row)
                continue
            if row["kind"] != "sample":
                raise ValueError("unexpected row kind")
            group, cycle = row["group"], row["cycle"]
            variant = variants.index(row["variant"])
            if (key not in selected or group not in ids or not 0 <= cycle < count + warmup
                    or row["warmup"] != (cycle < warmup)
                    or row["batch"] != case_metadata[key[1]]["windows"][key[2]]
                    or row["total_ns"] != row["instantiate_start_ns"] + row["entry_ns"]
                    or row["total_ns"] <= 0):
                raise ValueError(f"raw sample outside frozen design: {row}")
            identity = (key, group, cycle, variant)
            if identity in sample_keys:
                raise ValueError(f"duplicate sample: {identity}")
            sample_keys.add(identity)
            actual = (row["instantiate_start_ns"], row["entry_ns"], row["pid"], row["position"])
            if transcript.pop(("sample", *key, group, cycle, row["variant"]), None) != actual:
                raise ValueError("sample row differs from the worker transcript")
            if not row["warmup"]:
                groups[key][group, cycle - warmup, variant] = row["total_ns"] / row["batch"]
                phases[*key, row["variant"]].append([
                    row["instantiate_start_ns"] / row["batch"], row["entry_ns"] / row["batch"]])
        if len(sample_keys) != len(selected) * len(ids) * (count + warmup) * len(variants):
            raise ValueError("missing raw samples")
        if transcript:
            raise ValueError("worker transcript has unreported samples")
    for key in expected:
        for variant in variants:
            rows = compilation[*key, variant]
            if sorted(row["group"] for row in rows) != group_ids[key]:
                raise ValueError(f"incomplete compilation observations: {key}, {variant}")
    return frozen, variants, {
        key: [[[samples[group, cycle, variant] for variant in range(len(variants))]
               for cycle in range(count)] for group in group_ids[key]]
        for key, samples in groups.items()
    }, phases, compilation


def validate_construction(run, dataset, *, require_detailed=False, variants=VARIANTS, in_progress=False):
    env = json.loads((run / "environment.json").read_bytes())
    binaries = env["binaries"]
    if not in_progress:
        verify_finished(run, env, json.loads((run / "finished.json").read_bytes()))
    for key, filename in (("build", "build"), ("cli", "instrument.wasm")):
        if sha256(run / filename) != binaries[key]:
            raise ValueError(f"archived construction binary disagrees with environment: {filename}")
    cases = {case["id"]: case for case in cases_for(dataset, evidence_scope(env))}
    volumes = json.loads((run / "volumes.json").read_bytes())
    builds = json.loads((run / "builds.json").read_bytes())
    processes = dataset["sampling"]["build_processes"]
    expected_sizes = {(name, variant) for name in cases for variant in variants}
    expected_builds = (
        {(name, variant, group) for name in cases for variant in variants[1:]
         for group in range(processes)}
        | {(name, f"{variant}-cli", None) for name in cases for variant in variants if variant in CODEGEN}
    )
    size_keys = [(row["case"], row["variant"]) for row in volumes]
    build_keys = [(row["case"], row["variant"], row.get("process")) for row in builds]
    if len(size_keys) != len(expected_sizes) or set(size_keys) != expected_sizes:
        raise ValueError("missing, duplicate or unexpected volume rows")
    if len(build_keys) != len(expected_builds) or set(build_keys) != expected_builds:
        raise ValueError("missing, duplicate or unexpected construction rows")
    commands = {}
    for line in (run / "commands.jsonl").read_text(encoding="utf-8").splitlines():
        command = json.loads(line)
        name = command["stdout"]
        if name in commands:
            raise ValueError(f"duplicate command log entry: {name}")
        commands[name] = command

    # The archived artifact retains its run directory name after relocation.
    # Use the original worker location as the common prefix for all build rows.
    anchor = commands[f"{next(iter(cases))}-{variants[1]}-build-0.stdout"]
    original_run = Path(anchor["argv"][0]).parent
    if original_run.name != run.name:
        raise ValueError("construction worker does not belong to the archived run")
    digests = {}
    site_tables = {}
    fuel_span_tables = {}
    stack_models = set()
    for row in volumes:
        name, variant = row["case"], row["variant"]
        case = cases[name]
        filename = "original.wasm" if variant == "original" else f"{variant}-0.wasm"
        wasm = run / name / filename
        size = wasm.stat().st_size
        digest = sha256(wasm)
        check_start(wasm, case, variant=variant, original_start=(
            wasm_start(run / name / "original.wasm") if variant == "fuel" else None))
        digests[name, variant] = digest
        if variant == "original" and (digest != case["sha256"] or size != case["bytes"]):
            raise ValueError(f"frozen original changed: {name}")
        is_candidate = variant in CODEGEN and case["kind"] != "build"
        sidecar = None
        status = None
        if is_candidate:
            path = run / name / manifest_name(variant)
            sidecar = path.stat().st_size
            manifest = json.loads(path.read_bytes())
            details = manifest["instrumentation"]
            stack_model = details["stack_model"]
            stack_models.add(stack_model)
            if stack_model not in ("stack-v1", "stack-v2") or len(stack_models) != 1:
                raise ValueError(f"unknown or mixed stack model: {name}/{variant}")
            fuel = fuel_model(variant)
            metering = "join-span" if fuel in ("fuel-v1.2", "fuel-v2") else "per-instruction"
            layout = "" if variant == "p0" else f"|codegen={CODEGEN[variant]}"
            marker = (f"production-v1|{fuel}|diagnostics-v1|metering={metering}"
                      f"|growth=growth-v1|stack={stack_model}{layout}")
            if instrumentation_markers(wasm) != [marker.encode()]:
                raise ValueError(f"Wasm marker disagrees with production manifest: {name}/{variant}")
            frozen_config = dataset["config"]
            expected_config = dict(
                fuel=str(frozen_config["fuel"]), max_stack_units=str(case["stack_units"]),
                max_call_depth=str(case["depth"]), max_memory_pages=frozen_config["memory_pages"],
                max_table_elements=frozen_config["table_elements"],
                allowed_imports=[dict(module="wasi_snapshot_preview1", name="fd_write")] if case["stdout"] else [],
            )
            expected_details = dict(profile="production-v1", fuel_model=fuel,
                                    growth_model="growth-v1", stack_model=stack_model,
                                    diagnostics_abi="diagnostics-v1", codegen=CODEGEN[variant],
                                    config=expected_config)
            schema = "fuelguard-manifest-v2" if variant == "fuel-v2" else "fuelguard-manifest-v1"
            passes_match = ("passes" not in manifest if variant == "fuel-v2" else
                            manifest.get("passes") == ["FuelPass", "GrowthPass", "StackPass"])
            if (manifest["schema"] != schema
                    or (variant == "fuel-v2" and manifest.get("deterministic") is not True)
                    or manifest["input_sha256"] != case["sha256"]
                    or manifest["output_sha256"] != digest
                    or not passes_match
                    or any(details[key] != expected for key, expected in expected_details.items())):
                raise ValueError(f"wrong production manifest: {name}/{variant}")
            if "sites" in details:
                sites = details["sites"]
                if site_tables.setdefault(name, sites) != sites:
                    raise ValueError(f"metering sites differ between layouts: {name}/{variant}")
            if fuel_model(variant) == "fuel-v1.2" and (
                    fuel_span_tables.setdefault(name, details["fuel_spans"]) != details["fuel_spans"]):
                raise ValueError(f"fuel-v1.2 span boundaries differ: {name}/{variant}")
            verify = commands.get(f"{name}-verify-{path.stem}.stdout")
            expected_verify = ["moonrun", str(original_run / "instrument.wasm"), "verify",
                               str(original_run / name / filename), "--report",
                               str(original_run / name / path.name)]
            if not verify or verify["status"] != 0 or verify["argv"] != expected_verify:
                raise ValueError(f"missing manifest verification evidence: {name}/{variant}")
            if case["kind"] == "application" or "performance_scope" not in env:
                status = size_status(case["bytes"], size)
        if (row["bytes"], row["original_bytes"], row["sha256"], row["kind"],
            row["sidecar_bytes"], row["a19"]) != (size, case["bytes"], digest,
                                                 case["kind"], sidecar, status):
            raise ValueError(f"inconsistent volume evidence for {name}, {variant}")
        validation = commands.get(f"{name}-validate-{variant}.stdout")
        if (not validation or validation["status"] != 0
                or validation["argv"] != ["wasm-tools", "validate", str(original_run / name / filename)]):
            raise ValueError(f"missing encoded Wasm validation evidence for {name}, {variant}")

    for row in builds:
        name, variant, group = row["case"], row["variant"], row.get("process")
        label = f"{name}-cli-{variant.removesuffix('-cli')}" if group is None else f"{name}-{variant}-build-{group}"
        command = commands.get(label + ".stdout")
        if not command or command["status"] != 0 or any(row[key] != value for key, value in command.items()):
            raise ValueError(f"construction process disagrees with command evidence: {label}")
        if row["wall_ns"] <= 0 or row["peak_rss_kib"] <= 0:
            raise ValueError(f"invalid wall time or RSS: {label}")
        variant_wasm = variant.removesuffix("-cli")
        path = original_run / name
        case = cases[name]
        if group is None:
            cli = original_run / "instrument.wasm"
            explicit = variant_wasm != "fuel-v2" or "performance_scope" not in env
            expected = [cli_build_argv(cli, variant_wasm, case, path, explicit_layout=explicit)]
            if variant_wasm == "p0" and variants not in (S20_VARIANTS, S29_VARIANTS):
                expected.append(cli_build_argv(cli, variant_wasm, case, path, explicit_layout=False))
        else:
            expected = [native_build_argv(original_run / "build", variant, case, path, group)]
        if command["argv"] not in [list(map(str, args)) for args in expected]:
            raise ValueError(f"construction argv differs from the frozen design: {label}")
        if row["artifact_sha256"] != digests[name, variant_wasm]:
            raise ValueError(f"builder output hash mismatch: {label}")
        if group is None:
            continue
        transcript = (run / command["stdout"]).read_text(encoding="utf-8")
        raw = [(phase, int(ns)) for phase, ns in map(str.split, transcript.splitlines())]
        if variant == "fuel":
            old_fuel = tuple(phase for phase in S18_BUILD_STAGES if phase not in
                             ("stack_rewrite", "validate_stack", *AUDIT_STAGES))
            phases = (FUEL_STAGES, old_fuel)
        else:
            phases = (BUILD_STAGES, S18_BUILD_STAGES) if variant == "p0" else (BUILD_STAGES,)
            if not require_detailed and variant == "p0":
                phases += (ORIGINAL_BUILD_STAGES,)
        if variants == FORMAL_V2_VARIANTS:
            phases = (FUEL_V2_ONLY_STAGES if variant == "fuel" else FUEL_V2_BUILD_STAGES,)
        elif variants == S29_VARIANTS:
            phases = (FUEL_STAGES if variant == "fuel" else BUILD_STAGES,)
        if (tuple(phase for phase, _ in raw) not in phases or dict(raw) != row["phases_ns"]
                or any(ns < 0 for _, ns in raw) or sum(dict(raw).values()) > row["wall_ns"]):
            raise ValueError(f"missing or inconsistent construction phases: {label}")
    return volumes, builds


def s29_correctness(run, dataset):
    rows = [json.loads(line) for line in (run / "commands.jsonl").read_text(encoding="utf-8").splitlines()]
    commands = {row["stdout"]: row for row in rows}
    anchor = commands[f"{S29_DETERMINISM_CASE}-p0-build-0.stdout"]
    original_run = Path(anchor["argv"][0]).parent
    case = next(case for case in dataset["entries"] if case["id"] == S29_DETERMINISM_CASE)
    path = run / case["id"]
    a18 = {}
    tool_record = run / "wasmoon-a18.json"
    wasmoon = None
    if tool_record.is_file():
        wasmoon = json.loads(tool_record.read_bytes())
        if (sha256(run / "wasmoon-a18") != wasmoon["sha256"]
                or not re.search(r"(?<![\d.])0\.18\.0(?![\d.])", wasmoon["version"])):
            raise ValueError("S29 wasmoon correctness CLI differs from its ledger")
    for model, script in S29_CHECKS.items():
        label = f"a18-{model}"
        command = commands[label + ".stdout"]
        probe = ["-B", script, "--out", str(original_run / label)]
        if command["status"] != 0 or command["argv"][1:] not in (probe, ["-E", *probe]):
            raise ValueError(f"missing S29 boundary checks: {model}")
        if "-E" in command["argv"] and wasmoon is None:
            raise ValueError("S29 boundary checks lack the wasmoon CLI record")
        log = run / (label + ".stdout")
        events = [json.loads(line) for line in log.read_text(encoding="utf-8").splitlines()
                  if line.startswith("{")]
        observed = {}
        artifacts = set()
        instrumenters = 0
        for event in events:
            if "case" in event:
                name = event["case"]
                for stream in ("stdout", "stderr"):
                    log_path = run / label / f"{name}.{stream}"
                    if sha256(log_path) != event[f"{stream}_sha256"]:
                        raise ValueError(f"S29 boundary transcript changed: {label}/{log_path.name}")
                observed[name] = event["exit"]
            elif "artifact" in event:
                artifact = Path(event["path"])
                if event["artifact"] == "instrument-cli":
                    instrumenters += 1
                    if artifact != Path(command["cwd"]) / S29_DEBUG_CLI:
                        raise ValueError("S29 debug instrumenter path differs from the boundary command")
                    archived = run / "a18-instrument.wasm"
                else:
                    archived = run / label / artifact.relative_to(original_run / label)
                    artifacts.add(archived.name)
                if sha256(archived) != event["sha256"]:
                    raise ValueError(f"S29 boundary artifact changed: {label}/{artifact.name}")
        if instrumenters != 1:
            raise ValueError(f"S29 requires one debug instrumenter record: {model}")
        witnesses = ("prefix-23", "bulk-9-1") if model == "fuel-v1" else (
            "after-dynamic-call-exact", "first-unpaid-prefix", "leaf-stack-first")
        for layout in (variant for variant in S29_LAYOUTS if fuel_model(variant) == model):
            for witness in witnesses:
                name = f"{witness}-{layout}"
                if model == "fuel-v1":
                    manifest = json.loads((run / label / f"{name}.json").read_bytes())
                    if (observed.get(f"verify-{name}") != 0
                            or manifest["output_sha256"] != sha256(run / label / f"{name}.wasm")
                            or manifest["instrumentation"]["codegen"] != CODEGEN[layout]):
                        raise ValueError(f"missing S29 boundary delivery: {name}")
                elif f"{name}.wasm" not in artifacts or f"{name}-observer.wasm" not in artifacts:
                    raise ValueError(f"missing S29 boundary instrumented and observed artifacts: {name}")
                for engine in ENGINES:
                    check = f"{engine}-{name}"
                    if observed.get(check) != 0:
                        raise ValueError(f"missing S29 boundary witness: {engine}/{witness}/{layout}")
                    output = (run / label / (check + ".stdout")).read_bytes()
                    if witness == "prefix-23":
                        if output != b"ready\n":
                            raise ValueError(f"wrong S29 boundary output: {check}")
                    elif engine == "wasmoon" and (b"Skipped: 0" not in output
                            or not re.search(rb"Passed:\s+[1-9]\d*", output)):
                        raise ValueError(f"missing S29 wasmoon WAST assertions: {check}")
        a18[model] = dict(stdout=log.name, sha256=sha256(log), commands=len(observed))
    a16 = {}
    for layout in S29_LAYOUTS:
        name = Path(manifest_name(layout))
        product_sha = sha256(path / f"{layout}-0.wasm")
        manifest_sha = sha256(path / name)
        for rep in (2, 3):
            suffix = f"-repro-{rep}"
            command = commands[f"a16-{layout}{suffix}.stdout"]
            expected = cli_build_argv(original_run / "instrument.wasm", layout, case,
                                      original_run / case["id"], suffix=suffix)
            if (command["status"] != 0 or command["argv"] != list(map(str, expected))
                    or sha256(path / f"cli-{layout}{suffix}.wasm") != product_sha
                    or sha256(path / f"{name.stem}{suffix}.json") != manifest_sha):
                raise ValueError(f"S29 CLI reproducibility evidence differs: {layout}")
        a16[layout] = dict(wasm_sha256=product_sha, manifest_sha256=manifest_sha, repetitions=3)
    return {"A16": {"case": case["id"], "layouts": a16},
            "A18": {"suites": a18, "wasmoon_cli": wasmoon,
                    "debug_instrument_sha256": sha256(run / "a18-instrument.wasm")}}


def join_span_statistics(path):
    details = json.loads(path.read_bytes())["instrumentation"]
    expected = [row for row in details["sites"] if row["kind"] == "instruction"]
    per_function = defaultdict(Counter)
    loops = Counter(row["function_index"] for row in expected if row["opcode"] == "loop")
    histogram = Counter()
    cursor = 0
    for span in details["fuel_spans"]:
        first, length = span["first_site"], span["length"]
        if type(length) is not int or not 1 <= length <= 19 or cursor + length > len(expected):
            raise ValueError(f"invalid join-span length: {path}")
        sites = expected[cursor:cursor + length]
        function = sites[0]["function_index"]
        if any(site["id"] != first + offset or site["function_index"] != function
               for offset, site in enumerate(sites)):
            raise ValueError(f"join-span crosses an instruction or function boundary: {path}")
        cursor += length
        histogram[length] += 1
        per_function[function][length] += 1
    if cursor != len(expected):
        raise ValueError(f"join-spans do not cover all instruction sites: {path}")
    return dict(instructions=cursor, spans=histogram.total(), lengths=dict(sorted(histogram.items())),
                functions=[dict(function_index=function, loops=loops[function],
                                spans=counts.total(), instructions=sum(k * v for k, v in counts.items()),
                                lengths=dict(sorted(counts.items())))
                           for function, counts in sorted(per_function.items())])


def summarize(runs, detailed_build=None):
    first = runs[0]
    initial_env = json.loads((first / "environment.json").read_bytes())
    scope = evidence_scope(initial_env)
    if scope == "holdout" and len(runs) != 1:
        raise ValueError("holdout uses one fixed sample size")
    s29 = tuple(initial_env.get("variants", VARIANTS)) == S29_VARIANTS
    formal_v2 = tuple(initial_env.get("variants", VARIANTS)) == FORMAL_V2_VARIANTS
    if (s29 or formal_v2) and len(runs) > 1:
        previous = summarize(runs[:-1], detailed_build)
        expected = previous["borderline_cells"]
        actual = json.loads((runs[-1] / "environment.json").read_bytes())["cells"]
        if not expected or actual != expected:
            raise ValueError("formal supplement must cover the preceding report's borderline cells")
    dataset, variants, groups, phases, compilation = reconstruct(runs)
    candidate = variants[-1]
    is_pilot = variants in (PREFIX_VARIANTS, *JOIN_PILOTS)
    protocol = timing_protocol(dataset, scope)
    if (s29 or formal_v2) and detailed_build is not None:
        raise ValueError("this comparison requires the original construction records")
    if s29 and np.__version__ != "1.26.4":
        raise ValueError("historical S29 replay requires NumPy 1.26.4")
    volumes, builds = validate_construction(first, dataset, variants=variants)
    correctness = s29_correctness(first, dataset) if s29 else None
    build_source = first
    if detailed_build is not None:
        original_env = initial_env
        refreshed_env = json.loads((detailed_build / "environment.json").read_bytes())
        refreshed_finish = json.loads((detailed_build / "finished.json").read_bytes())
        if (not refreshed_env.get("build_only") or refreshed_env["smoke"]
                or refreshed_finish["samples_sha256"] is not None
                or any(original_env[field] != refreshed_env[field]
                       for field in ("dataset_sha256", "host", "stack", "affinity", "uname",
                                     "tools", "wasmtime_lib_sha256"))):
            raise ValueError("detailed build evidence used a different performance environment")
        new_volumes, builds = validate_construction(detailed_build, dataset, require_detailed=True, variants=variants)
        if new_volumes != volumes:
            raise ValueError("detailed build artifacts differ from the timed artifacts")
        build_source = detailed_build
    by_name = {case["id"]: case for case in dataset["entries"]}
    rng = np.random.default_rng(protocol["bootstrap_seed"])
    workloads = []
    geometric = defaultdict(list)
    versus_p0 = defaultdict(list)
    for (engine, case, window), group in sorted(groups.items()):
        points, draws = statistics(group, protocol["bootstrap_draws"], rng, clustered=formal_v2)
        kind = by_name[case]["kind"]
        for variant, name in enumerate(variants):
            full = name in CODEGEN
            row = dict(engine=engine, case=case, kind=kind, window=window,
                       variant=name, groups=len(group), samples_per_group=len(group[0]))
            phases_key = (engine, case, window, name)
            batch_phases = phases[phases_key]
            compile_rows = compilation[phases_key]
            row["phase_medians_ns"] = dict(zip(
                ("instantiate_start", "entry"), np.median(batch_phases, axis=0).tolist(),
                strict=True))
            row["engine_medians_ns"] = {field: float(np.median([x[field] for x in compile_rows]))
                for field in ("parse_or_read_ns", "jit_ns", "verify_ns")}
            row["process_peak_rss_kib"] = max(x["process_peak_rss_kib"] for x in compile_rows)
            for index, label in enumerate(("median", "p95")):
                row[label + "_ns"] = interval(points[index, variant], draws[index, variant])
                if variant:
                    value = interval(points[index, variant] / points[index, 0],
                                     draws[index, variant] / draws[index, 0])
                    row[label + "_ratio"] = value
                    if full and kind == "application" and not is_pilot:
                        row[label + "_gate"] = gate(value, 3.0)
                        row[label + "_borderline"] = borderline(value, 3.0)
                    if name == "p1":
                        p0 = variants.index("p0")
                        row[label + "_p1_over_p0"] = interval(
                            points[index, variant] / points[index, p0],
                            draws[index, variant] / draws[index, p0])
            if variant and kind == "application":
                geometric[engine, window, name].append(
                    (points[0, variant] / points[0, 0], draws[0, variant] / draws[0, 0]))
            if name == "p1" and kind == "application":
                p0 = variants.index("p0")
                versus_p0[engine, window].append((
                    points[0, variant] / points[0, p0], draws[0, variant] / draws[0, p0]))
            workloads.append(row)

    aggregates = []
    for (engine, window, variant), values in sorted(geometric.items()):
        point = math.exp(math.fsum(math.log(value[0]) for value in values) / len(values))
        draws = np.exp(np.mean(np.log([value[1] for value in values]), axis=0))
        result = interval(point, draws)
        aggregates.append(dict(engine=engine, window=window, variant=variant,
                               median_geomean_ratio=result, workloads=len(values),
                               gate=gate(result, 2.0) if variant in CODEGEN and not is_pilot else None,
                               borderline=borderline(result, 2.0) if variant in CODEGEN and not is_pilot else None))
    for (engine, window), values in sorted(versus_p0.items()):
        point = math.exp(math.fsum(math.log(value[0]) for value in values) / len(values))
        draws = np.exp(np.mean(np.log([value[1] for value in values]), axis=0))
        aggregates.append(dict(engine=engine, window=window, variant="p1-over-p0",
                               median_geomean_ratio=interval(point, draws), workloads=len(values),
                               gate=None, borderline=None))
    build_cases = [case for case in cases_for(dataset, scope) if case["kind"] == "build"]
    largest = max(build_cases, key=lambda row: row["bytes"], default=None)
    comparisons = {}
    for layout in (name for name in variants if name in CODEGEN):
        a20 = {"status": "NOT_RUN"}
        if largest is not None:
            measured = [row for row in builds if row["case"] == largest["id"]
                        and row["variant"] in (layout, f"{layout}-cli")]
            a20 = {
                "max_input": largest["id"], "time_limit_ns": 10_000_000_000, "rss_limit_kib": 524288,
                "peak_wall_ns": max(row["wall_ns"] for row in measured),
                "peak_rss_kib": max(row["peak_rss_kib"] for row in measured),
            }
            a20["status"] = ("PASS" if a20["peak_wall_ns"] <= a20["time_limit_ns"]
                             and a20["peak_rss_kib"] <= a20["rss_limit_kib"] else "FAIL")
        aggregate_rows = [row for row in aggregates if row["variant"] == layout]
        a17_fails = any(row["gate"] == "FAIL" for row in aggregate_rows) or any(
            "FAIL" in (row.get("median_gate"), row.get("p95_gate"))
            for row in workloads if row["variant"] == layout)
        gates = dict(
            A17="NOT_RUN" if is_pilot else ("FAIL" if a17_fails else "PASS"),
            A19="FAIL" if any(row["a19"] == "FAIL" and row["variant"] == layout
                              and (row["kind"] == "application" or not formal_v2)
                              for row in volumes) else "PASS",
        )
        if not formal_v2:
            gates["A20"] = a20["status"]
        if correctness is not None:
            gates["A18"] = "PASS"
        comparisons[layout] = dict(codegen=CODEGEN[layout], gates=gates, a20_max_input=a20,
                                   worst_geomean_ratio=max(
                                       row["median_geomean_ratio"]["point"] for row in aggregate_rows))
        if variants in (S29_VARIANTS, FORMAL_V2_VARIANTS) and build_cases:
            scales = []
            for scale in build_cases:
                native = [row for row in builds if row["case"] == scale["id"] and row["variant"] == layout]
                cli = next(row for row in builds
                           if row["case"] == scale["id"] and row["variant"] == f"{layout}-cli")
                scales.append(dict(case=scale["id"], bytes=scale["bytes"], functions=scale["functions"],
                                   instructions=scale["instructions"],
                                   native_median_wall_ns=int(np.median([row["wall_ns"] for row in native])),
                                   native_peak_rss_kib=max(row["peak_rss_kib"] for row in native),
                                   cli_wall_ns=cli["wall_ns"], cli_peak_rss_kib=cli["peak_rss_kib"]))
            comparisons[layout]["a20_scales"] = scales
    description = "S29 formal tuning comparison" if variants == S29_VARIANTS else {
             "p0": "S18 tuning baseline", "p1": "S19 P0/P1 tuning comparison",
             "p2": "S20 P0/P1/P2 tuning comparison",
             "p2-prefix": "S20 exact-prefix tuning pilot", "join-span": "S26 join-span tuning pilot",
             "join-span-cached": "fuel-v1.2 cached tuning pilot",
             "join-span-compact": "S28 compact tuning pilot",
             "join-span-compact-v2": "compact v2 tuning pilot",
        "fuel-v2": f"Fuel v2 {scope} measurement"}[candidate]
    reported_sizes = [{**row, "a19": None} if formal_v2 and row["kind"] != "application" else row
                      for row in volumes]
    report = dict(
        schema="fuelguard-bench-report-v2" if formal_v2 else "fuelguard-bench-report-v1",
        layout=CODEGEN[candidate],
        numpy=np.__version__, summarize_sha256=sha256(Path(__file__)), scope=description,
        performance_scope=scope,
        aggregates=aggregates, workloads=workloads, sizes=reported_sizes, builds=builds,
        candidate_gates=comparisons[candidate]["gates"],
        a20_max_input=comparisons[candidate]["a20_max_input"],
        construction_evidence={"directory": build_source.name,
                               "environment_sha256": sha256(build_source / "environment.json")},
        final_acceptance={name: "NOT_RUN" for name in ("A17", "A18", "A19", "A20")},
        performance_verdict="NOT_RUN",
    )
    if formal_v2:
        report["comparisons"] = comparisons
    elif variants in (S20_VARIANTS, S29_VARIANTS):
        report["comparisons"] = comparisons
        report["performance_eligible"] = [layout for layout, row in comparisons.items()
                                          if all(result == "PASS" for result in row["gates"].values())]
    if correctness is not None:
        for field in ("layout", "candidate_gates", "a20_max_input"):
            del report[field]
        borderline_cells = {
            (row["engine"], row["case"], row["window"])
            for row in workloads
            if row.get("median_borderline") or row.get("p95_borderline")
        }
        borderline_windows = {(row["engine"], row["window"]) for row in aggregates if row["borderline"]}
        borderline_cells.update((row["engine"], row["case"], row["window"])
                                for row in workloads if row["kind"] == "application"
                                and (row["engine"], row["window"]) in borderline_windows)
        report.update(correctness=correctness, borderline_cells=[list(cell) for cell in sorted(borderline_cells)],
                      variants=variants,
                      fuel_models={layout: fuel_model(layout) for layout in comparisons},
                      timing_evidence=[
                          dict(directory=run.name, environment_sha256=sha256(run / "environment.json"),
                               samples_sha256=sha256(run / "samples.jsonl")) for run in runs],
                      holdout_executions=0)
    if variants == FORMAL_V2_VARIANTS:
        borderline_cells = {
            (row["engine"], row["case"], row["window"])
            for row in workloads
            if row.get("median_borderline") or row.get("p95_borderline")
        }
        borderline_windows = {(row["engine"], row["window"])
                              for row in aggregates if row["borderline"]}
        borderline_cells.update(
            (row["engine"], row["case"], row["window"])
            for row in workloads
            if row["kind"] == "application"
            and (row["engine"], row["window"]) in borderline_windows
        )
        report.update(
            borderline_cells=[list(cell) for cell in sorted(borderline_cells)],
            variants=variants,
            fuel_models={"fuel-v2": fuel_model("fuel-v2")},
            timing_evidence=[
                dict(directory=run.name, environment_sha256=sha256(run / "environment.json"),
                     samples_sha256=sha256(run / "samples.jsonl")) for run in runs
            ],
        )
        gates = comparisons[candidate]["gates"]
        report["final_acceptance"], report["performance_verdict"] = performance_result(
            scope, gates["A17"], gates["A19"], freeze_verified=scope == "holdout")
        if scope == "tuning":
            report["tuning_results"] = gates
        else:
            del report["candidate_gates"]
        report["engineering_checks"] = {"A20": comparisons[candidate]["a20_max_input"]}
        report["confidence_interval"] = {
            "level": 0.95, "method": "paired whole-process percentile bootstrap",
            "draws": protocol["bootstrap_draws"], "initial_independent_processes": protocol["processes"],
        }
    report["provenance"] = {
        "head": initial_env["head"], "source_sha256": json_digest(initial_env["source"]),
        "toolchain": initial_env["tools"], "binaries": initial_env["binaries"],
        "wasmtime_lib_sha256": initial_env["wasmtime_lib_sha256"],
        "python_sha256": initial_env.get("python_sha256"),
        "dataset_sha256": initial_env["dataset_sha256"],
        "configuration_sha256": configuration_digest(dataset),
        "proposal_sha256": initial_env.get("proposal_sha256"),
        "candidate_lock_sha256": initial_env.get("candidate_lock_sha256"),
        "inputs": {case["id"]: case["sha256"] for case in cases_for(dataset, scope)},
        "runs": [{name + "_sha256": sha256(run / f"{name}.json")
                  for name in ("environment", "finished")} for run in runs],
        "analysis": {
            "python": sys.version.split()[0], "python_sha256": sha256(Path(sys.executable)),
            "numpy": np.__version__,
            "scripts": {name: sha256(Path(__file__).with_name(name)) for name in
                        ("summarize.py", "run.py", "dataset.py", "performance_evidence.py")},
        },
    }
    if is_pilot:
        report["comparisons"] = comparisons
        report["pilot"] = {"samples_per_process": PREFIX_PILOT_SAMPLES, "default_selection": False}
    if variants in (JOIN_VARIANTS, CACHED_JOIN_VARIANTS):
        ratio = next(row["median_ratio"]["point"] for row in workloads
                     if (row["case"], row["engine"], row["window"], row["variant"])
                     == ("F1-json", "wasmoon", "hot", candidate))
        report["pilot"]["s26"] = dict(
            f1_wasmoon_hot_median_ratio=ratio, limit=2.2,
            status="PASS" if ratio <= 2.2 else "STOP" if ratio >= 2.5 else "FAIL",
            spans={case["id"]: join_span_statistics(first / case["id"] / manifest_name(candidate))
                   for case in dataset["entries"] if case["split"] == "tuning" and case["kind"] == "application"},
        )
    return report


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("run", type=Path, nargs="+")
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--detailed-build", type=Path)
    parser.add_argument("--freeze-candidate", type=Path,
                        help="write a candidate freeze record after validating a Fuel v2 tuning archive")
    opts = parser.parse_args()
    if opts.freeze_candidate and opts.freeze_candidate.resolve() == opts.out.resolve():
        parser.error("report and candidate freeze must use separate output files")
    report = summarize(opts.run, opts.detailed_build)
    with opts.out.open("x", encoding="utf-8") as output:
        json.dump(report, output, indent=2, ensure_ascii=False)
        output.write("\n")
    if opts.freeze_candidate:
        create_candidate_lock(opts.run[0], opts.freeze_candidate)
    if "pilot" in report:
        print(json.dumps({"pilot": report["pilot"], "candidate_gates": report["candidate_gates"]}))
    elif "confidence_interval" in report:
        print(json.dumps({key: report[key] for key in
                          ("performance_scope", "tuning_results", "final_acceptance",
                           "performance_verdict", "borderline_cells") if key in report}))
    elif "timing_evidence" in report:
        print(json.dumps({"gates": {key: row["gates"] for key, row in report["comparisons"].items()},
                          "performance_eligible": report["performance_eligible"],
                          "borderline_cells": report["borderline_cells"]}))
    else:
        print(json.dumps(report["candidate_gates"]))

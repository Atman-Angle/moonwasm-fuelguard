"""Run FuelGuard acceptance groups and record the status of A01–A24."""

import argparse
from dataclasses import dataclass
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))

from integration.generated.check import CommandLog, file_hash, save_json
from integration.generated.recipes import COUNT, FUEL_V2, JOIN_SEED
from integration.generated.reject import A15_CASE_COUNT

SCHEMA = "fuelguard-acceptance-v1"
TOOLS = {"wasmoon": "0.18.0", "wasmtime": "50.0.0", "wasm-tools": "1.263.0"}
STATUSES = ("FAIL", "BLOCKED", "NOT_RUN", "PASS")
PYTHON = (sys.executable, "-B")
PINS = ("moon", "moonrun", "wasm-tools", "wasmoon", "wasmtime")
RAW_CHECKS = {"named-corpus", "named-workloads", "named-demo", "pipeline", "stack", "runner",
              "bounded-refusals", "file-faults", "prefix-and-references"}


@dataclass(frozen=True)
class Check:
    name: str
    gates: tuple[int, ...]
    argv: tuple[str, ...]
    tools: tuple[str, ...]
    timeout: int = 1200


GROUPS = {
    "correctness": (
        Check("moon-tests", (1, 2, 4, 7), ("moon", "test", "--target", "wasm"), ("moon",)),
        Check("fuel-oracle", (2, 4), (*PYTHON, "-m", "unittest", "discover", "-s", "integration/fuel_oracle"), ()),
        Check("named-corpus", (*range(1, 8), 9, 10, 11, 12, 13, 16),
              (*PYTHON, "integration/corpus/check.py", "--group", "strict"), PINS),
        Check("pipeline", (1, 2, 3, 4, 6, 7, 9, 10, 11, 23),
              (*PYTHON, "integration/pipeline/check.py"), PINS),
        Check("stack", (5, 6, 7), (*PYTHON, "integration/stack_pass/check.py"), PINS),
        Check("runner", (5, 8, 13, 23), (*PYTHON, "integration/runner/check.py"),
              (*PINS, "bash", "cc", "prlimit")),
        Check("named-workloads", (11, 12, 13), (*PYTHON, "integration/corpus/check.py",
              "--group", "workloads"), (*PINS, "bash", "cc", "prlimit")),
        Check("named-demo", (2, 3, 5, 7, 12), (*PYTHON, "integration/corpus/check.py",
              "--group", "demo"), PINS),
        Check("moon-strict", (1,), ("moon", "check", "--target", "wasm", "--deny-warn"), ("moon",)),
        Check("join-oracle", (2, 3, 4, 6, 7, 16), (*PYTHON, "integration/fuel_cache/check.py"), PINS),
        Check("prefix-and-references", (2, 4, 6, 7), (*PYTHON, "integration/p1/check.py"), PINS),
    ),
    "generated": (Check("generation", (14,), (*PYTHON, "integration/generated/check.py", "run"),
                        PINS, timeout=3600),),
    "rejections": (
        Check("bounded-refusals", (15,), (*PYTHON, "integration/corpus/check.py", "--group", "boundaries"), PINS),
        Check("mutated-refusals", (15,), (*PYTHON, "integration/generated/reject.py"), ("moon", "moonrun", "wasm-tools")),
    ),
    "delivery": (
        Check("delivery-tests", (21,), ("moon", "test", "--target", "wasm"), ("moon",)),
        Check("file-faults", (21,), ("unshare", "--mount", *PYTHON, "integration/delivery/check.py",
                                     "--os-failures"), ("moon", "moonrun", "unshare", "mount", "umount", "setpriv")),
    ),
    "performance": (),
    "release": (),
}
FUTURE = {
    "performance": {17: "S21 full-protection performance gate",
                    18: "S18–S21 candidate layout comparison",
                    19: "S21 frozen layout size gate",
                    20: "S20 maximum input time and memory gate"},
    "release": {22: "S22 clean-environment package verification",
                24: "S23 independent replay of all production gates"},
}


def disposition(statuses):
    return next(status for status in STATUSES if status in statuses)


def tool_info(names, log):
    tools = {}
    for name in sorted(names):
        path = shutil.which(name)
        info = {"path": path, "version": None, "problem": None}
        if path is None:
            info["problem"] = f"missing {name} on PATH"
        else:
            command, stdout = log.run([path, "version" if name == "moon" else "--version"], timeout=15)
            info["probe"] = command
            expected = TOOLS.get(name)
            if command["exit_code"] != 0:
                info["problem"] = f"{name} version probe failed"
            elif expected and not re.search(rf"(?<![\d.]){re.escape(expected)}(?![\d.])", stdout):
                info["problem"] = f"{name} requires version {expected}"
            info["version"] = stdout.strip() or None
        tools[name] = info
    return tools


def source_identity(log, evidence):
    info = {"commit": None, "working_tree": None}
    if shutil.which("git"):
        row, stdout = log.run(["git", "rev-parse", "HEAD"], timeout=15)
        if row["exit_code"] == 0:
            info["commit"] = stdout.strip()
            status, text = log.run(["git", "--no-optional-locks", "status", "--porcelain"], timeout=15)
            if status["exit_code"] == 0:
                info["working_tree"] = "dirty" if text.strip() else "clean"
    digests = source_files(evidence)
    info["source_files"] = digests
    info["source_set_sha256"] = hashlib.sha256(
        json.dumps(digests, sort_keys=True).encode("utf-8")).hexdigest()
    return info


def source_files(evidence):
    extensions = {".mbt", ".pkg", ".mod", ".work", ".wasm", ".wat", ".py", ".sh", ".c"}
    files = [p for p in ROOT.iterdir() if p.suffix in extensions]
    files.extend(ROOT / path for path in ("bench/dataset.json", "bench/dataset.py"))
    for folder in ("cmd", "runner", "fixtures", "integration", "scripts"):
        for base, dirs, names in os.walk(ROOT / folder):
            dirs[:] = [name for name in dirs if not name.startswith(".")
                       and name not in ("_build", "target", "__pycache__")
                       and Path(base, name).resolve() != evidence]
            files.extend(Path(base) / name for name in names if Path(name).suffix in extensions)
    hashes = {}
    for path in sorted(files):
        if not path.is_file():
            raise ValueError(f"source input is not a regular file: {path}")
        hashes[path.relative_to(ROOT).as_posix()] = file_hash(path)
    return hashes


def environment_problem():
    if platform.system() != "Linux" or platform.machine() != "x86_64":
        return "acceptance requires x86_64 Linux (or WSL2 on the Linux filesystem)"
    if not __debug__:
        return "acceptance requires Python assertions enabled"
    import resource
    try:
        resource.setrlimit(resource.RLIMIT_STACK, (8388608, resource.getrlimit(resource.RLIMIT_STACK)[1]))
    except (ValueError, OSError) as error:
        return f"cannot set 8 MiB process stack: {error}"
    return None


def group_blocker(check, tools, environment, log):
    if environment:
        return environment
    problems = [tools[name]["problem"] for name in check.tools if tools[name]["problem"]]
    if problems:
        return "; ".join(problems)
    if check.name == "file-faults":
        if os.geteuid() != 0:
            return "real EACCES/ENOSPC checks require root in a private mount namespace"
        probe, _ = log.run(["unshare", "--mount", "true"], timeout=15)
        if probe["exit_code"] != 0:
            return "could not create a private mount namespace"
    return None


def run_check(check, directory, tools, environment, jobs, inject):
    log = CommandLog(directory / f"{check.name}.jsonl")
    reason = group_blocker(check, tools, environment, log)
    result = {"check_id": check.name, "gate_ids": [f"A{n:02d}" for n in check.gates],
              "status": "BLOCKED", "reason": reason, "command": None}
    if reason:
        return result
    argv = list(check.argv)
    if check.name == "generation":
        raw = directory / "generated"
        argv += ["--out", raw, "--jobs", str(jobs)]
        if inject:
            argv += ["--limit", "1", "--inject-failure"]
    elif check.name == "mutated-refusals":
        raw = directory / "rejected"
        argv += ["--out", raw]
    elif check.name == "join-oracle":
        raw = directory / "join-oracle-artifacts"
        argv += ["--out", raw]
    if check.name == "delivery-tests":
        argv += ["--filter", "partial report staging failure leaves both final paths unused"]
    env = dict(os.environ)
    env.pop("FUELGUARD_CHECK_EVIDENCE", None)
    if check.name in RAW_CHECKS:
        raw = directory / f"{check.name}-artifacts"
        env["FUELGUARD_CHECK_EVIDENCE"] = str(raw)
    if check.name in RAW_CHECKS or check.name in ("generation", "mutated-refusals", "join-oracle"):
        result["artifact_directory"] = str(raw)
    command, stdout = log.run(argv, timeout=check.timeout, env=env)
    rc = command["exit_code"]
    result.update(command=command, reason=command["environment_error"],
                  status="PASS" if rc == 0 else "FAIL" if rc is not None else "BLOCKED",
                  command_log=str(log.path), command_log_sha256=file_hash(log.path))
    if rc == 0 and check.name in ("moon-tests", "delivery-tests"):
        if not re.search(r"Total tests: [1-9]\d*, passed: [1-9]\d*, failed: 0\.", stdout):
            result.update(status="FAIL", reason="MoonBit command did not report a nonempty passing test set")
    if check.name in ("generation", "mutated-refusals"):
        attach_corpus(check.name, raw, result, rc)
    return result


def attach_corpus(name, raw, result, rc):
    summary_file = raw / "summary.json"
    if not summary_file.is_file():
        if rc == 0:
            result.update(status="FAIL", reason="missing corpus summary")
        return
    try:
        summary = json.loads(summary_file.read_bytes())
        if not isinstance(summary, dict):
            raise ValueError("expected a JSON object")
    except (ValueError, OSError) as error:
        result.update(status="FAIL", reason=f"invalid corpus summary: {error}")
        return
    result["corpus"] = {"summary": str(summary_file), "sha256": file_hash(summary_file),
                        "details": summary}
    if rc == 0:
        if name == "generation":
            required = ("requested", "input_validated", "unique_input_hashes",
                        "instrumented", "output_validated", "executed_both_engines")
            complete = (summary.get("seed") == JOIN_SEED and summary.get("status") == "PASS"
                        and summary.get("codegen") == FUEL_V2
                        and summary.get("frozen_input_set_match") is True
                        and all(summary.get(key) == COUNT for key in required))
        else:
            complete = (summary.get("status") == "PASS" and
                        summary.get("codegen") == FUEL_V2 and
                        summary.get("rejected") == summary.get("requested") == A15_CASE_COUNT)
        if not complete:
            result.update(status="FAIL", reason="corpus summary does not meet the group acceptance threshold")
    elif rc == 2 and summary.get("status") in ("BLOCKED", "NOT_RUN"):
        result.update(status=summary["status"], reason=summary.get("reason", "corpus did not complete"))


def run_acceptance(directory, selected, jobs, inject):
    log = CommandLog(directory / "environment.jsonl")
    environment = environment_problem()
    groups = GROUPS
    checks = {check.name: check for group in selected for check in groups[group]}
    tools, identity = {}, None
    try:
        if not environment:
            tools = tool_info({tool for check in checks.values() for tool in check.tools}, log)
        identity = source_identity(log, directory)
    except (OSError, ValueError) as error:
        environment = f"cannot capture acceptance setup: {error}"
    results = {}
    for check in checks.values():
        try:
            result = run_check(check, directory, tools, environment, jobs, inject)
        except (OSError, ValueError) as error:
            result = {"check_id": check.name, "gate_ids": [f"A{n:02d}" for n in check.gates],
                      "status": "BLOCKED", "reason": str(error), "command": None}
        results[check.name] = result
        print(f"{check.name} {result['status']}", flush=True)
    try:
        changed = identity is not None and identity["source_files"] != source_files(directory)
    except (OSError, ValueError):
        changed = True
    if changed:
        for result in results.values():
            if result["status"] == "PASS":
                result.update(status="BLOCKED", reason="acceptance inputs changed during the run")

    gates = []
    selected_gates = []
    for n in range(1, 25):
        applicable = [(group, check) for group, suite in groups.items()
                      for check in suite if n in check.gates]
        owning = {group for group, _ in applicable}
        future = next(((group, gates[n]) for group, gates in FUTURE.items() if n in gates), None)
        ids = [check.name for group, check in applicable if group in selected]
        gate = {"id": f"A{n:02d}", "status": "NOT_RUN", "checks": ids,
                "reason": "gate group was not requested"}
        if future:
            group, reason = future
            owning = {group}
            gate["reason"] = reason
        elif ids:
            gate["status"] = disposition([results[name]["status"] for name in ids])
            gate["reason"] = None
        gates.append(gate)
        if owning.intersection(selected):
            selected_gates.append(gate["status"])
    selection_status = disposition(selected_gates)
    overall = disposition([row["status"] for row in gates])
    exit_code = {"PASS": 0, "FAIL": 1, "BLOCKED": 2, "NOT_RUN": 2}[selection_status]
    report = {"schema": SCHEMA, "status": selection_status, "overall": overall, "exit_code": exit_code,
              "selected_groups": selected, "gates": gates, "checks": list(results.values()),
              "candidate": identity, "environment": {"platform": platform.platform(),
              "libc": platform.libc_ver(), "python": platform.python_version(),
              "tools": tools, "problem": environment},
              "model": {"profile": "production-v1",
                        "fuel": FUEL_V2,
                        "growth": "growth-v1", "stack": "stack-v2", "abi": "diagnostics-v1",
                        "layout": "fuel-v2-inline-v1"},
              "injected_failure": inject}
    save_json(directory / "report.json", report)
    print(f"selection={selection_status} overall={overall} {directory / 'report.json'}", flush=True)
    return exit_code


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--group", choices=GROUPS, action="append",
                        help="repeat to run several groups; default runs all gates")
    parser.add_argument("--out", type=Path, help="new directory for report and raw artifacts")
    parser.add_argument("--codegen", choices=(FUEL_V2,), default=FUEL_V2)
    parser.add_argument("--jobs", type=int, default=min(8, os.cpu_count() or 1))
    parser.add_argument("--inject-failure", action="store_true",
                        help="run a negative control against the generated group")
    args = parser.parse_args()
    selected = list(dict.fromkeys(args.group or GROUPS))
    if not 1 <= args.jobs <= 32:
        parser.error("jobs must be 1–32")
    if args.inject_failure and "generated" not in selected:
        parser.error("--inject-failure requires the generated group")
    try:
        if args.out:
            directory = args.out.resolve()
            directory.mkdir(parents=True)
        else:
            base = ROOT / "_build/s17"
            base.mkdir(parents=True, exist_ok=True)
            directory = Path(tempfile.mkdtemp(prefix="acceptance-", dir=base))
        os.environ["LC_ALL"] = "C"
        return run_acceptance(directory, selected, args.jobs, args.inject_failure)
    except (OSError, RuntimeError, ValueError) as error:
        print(f"acceptance setup error: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())

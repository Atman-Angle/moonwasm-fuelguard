"""Shared scope, acceptance and provenance for performance evidence."""

import hashlib
import json
import time
from pathlib import Path

if __package__:
    from .dataset import FUEL_V2_DATASET_HASHES, ROOT, sha256
else:
    from dataset import FUEL_V2_DATASET_HASHES, ROOT, sha256

PROPOSAL = ROOT / "docs/04_项目申报书_v2.md"
FUEL_V2_VARIANTS = ("original", "fuel", "fuel-v2")
FROZEN_LAYOUT = "fuel-v2-inline-v1"
FROZEN_BINARIES = {
    "build": "build", "cli": "instrument.wasm",
    "wasmoon": "wasmoon", "wasmtime": "wasmtime-worker",
}
HOLDOUT_PROCESSES = 20
FREEZE_SCHEMA = "fuelguard-performance-freeze-v1"


def json_digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def source_hashes():
    excluded = {".git", "_build", ".mooncakes", "__pycache__", "evidence"}
    suffixes = {".mbt", ".mbti", ".c", ".py", ".pkg", ".mod", ".work", ".lock"}
    files = (path for path in ROOT.rglob("*") if path.is_file()
             and excluded.isdisjoint(path.relative_to(ROOT).parts)
             and path.suffix in suffixes)
    return {path.relative_to(ROOT).as_posix(): sha256(path) for path in sorted(files)}


def cases_for(dataset, scope):
    return [case for case in dataset["entries"] if case["split"] == scope]


def configuration_digest(dataset):
    return json_digest({
        "config": dataset["config"],
        "cases": {case["id"]: {key: case[key] for key in ("depth", "stack_units", "stdout")}
                  for case in dataset["entries"]},
    })


def evidence_scope(env):
    scope = env.get("performance_scope", "tuning")
    if scope == "holdout":
        if (tuple(env.get("variants", ())) != FUEL_V2_VARIANTS or not env.get("candidate_lock_sha256")
                or env.get("smoke") or env.get("build_only")):
            raise ValueError("holdout requires a frozen, complete Fuel v2 run")
    elif scope != "tuning" or env.get("candidate_lock_sha256") is not None:
        raise ValueError("invalid performance evidence scope")
    return scope


def timing_protocol(dataset, scope):
    protocol = dataset["sampling"]
    return {**protocol, "processes": HOLDOUT_PROCESSES} if scope == "holdout" else protocol


def size_status(original_bytes, output_bytes):
    limit = size_limit(original_bytes)
    return "PASS" if output_bytes <= limit else "FAIL"


def size_limit(original_bytes):
    if original_bytes < 10 * 1024:
        return original_bytes + 15 * 1024
    return 3 * original_bytes


def performance_result(scope, a17, a19, *, freeze_verified=False):
    if scope == "tuning":
        return {"A17": "NOT_RUN", "A19": "NOT_RUN"}, "NOT_RUN"
    if scope != "holdout" or not freeze_verified or {a17, a19} - {"PASS", "FAIL"}:
        raise ValueError("final performance requires verified independent evidence for A17 and A19")
    return {"A17": a17, "A19": a19}, "FINAL_PASS" if a17 == a19 == "PASS" else "FINAL_FAIL"


def read_json(path):
    return json.loads(path.read_bytes())


def run_identity(env):
    return {
        "head": env["head"],
        "source_sha256": json_digest(env["source"]),
        "tools": {name: {"version": tool["version"], "sha256": tool["sha256"]}
                  for name, tool in env["tools"].items()},
        "binaries": env["binaries"],
        "wasmtime_lib_sha256": env["wasmtime_lib_sha256"],
        "python_sha256": env["python_sha256"],
        "dataset_sha256": env["dataset_sha256"],
        "configuration_sha256": env["configuration_sha256"],
        "proposal_sha256": env["proposal_sha256"],
    }


def freeze_identity(environment, finished):
    env, finish = read_json(environment), read_json(finished)
    if (env.get("performance_scope") != "tuning" or evidence_scope(env) != "tuning"
            or tuple(env.get("variants", ())) != FUEL_V2_VARIANTS
            or env.get("smoke") or env.get("build_only") or env.get("append_of")
            or env.get("cells") is not None or env["dataset_sha256"] not in FUEL_V2_DATASET_HASHES
            or not finish.get("samples_sha256") or not finish.get("commands_sha256")
            or finish["finish_utc_ns"] < env["start_utc_ns"]):
        raise ValueError("freeze requires a complete, provenance-bound Fuel v2 tuning run")
    return {
        "schema": FREEZE_SCHEMA,
        "layout": FROZEN_LAYOUT,
        "identity": run_identity(env),
        "tuning_environment_sha256": sha256(environment),
        "tuning_finished_sha256": sha256(finished),
    }


def create_candidate_lock(run, output):
    record = freeze_identity(run / "environment.json", run / "finished.json")
    record["frozen_utc_ns"] = time.time_ns()
    with output.open("x", encoding="utf-8") as file:
        json.dump(record, file, indent=2)
        file.write("\n")


def verify_candidate_lock(lock, environment, finished):
    record = read_json(lock)
    frozen_at = record.pop("frozen_utc_ns", None)
    if (type(frozen_at) is not int or frozen_at < read_json(finished)["finish_utc_ns"]
            or record != freeze_identity(environment, finished)):
        raise ValueError("candidate freeze record differs from the archived tuning run")
    return record["identity"], frozen_at


def verify_holdout_identity(env, identity, frozen_at):
    if env["start_utc_ns"] < frozen_at or run_identity(env) != identity:
        raise ValueError("holdout differs from the candidate frozen before execution")


def verify_holdout_run(run: Path, env):
    lock = run / "candidate-lock.json"
    if sha256(lock) != env["candidate_lock_sha256"]:
        raise ValueError("holdout candidate freeze record changed")
    identity, frozen_at = verify_candidate_lock(lock, run / "candidate-tuning-environment.json",
                                               run / "candidate-tuning-finished.json")
    verify_holdout_identity(env, identity, frozen_at)


def verify_finished(run, env, finish):
    if "performance_scope" not in env:
        return  # Historical records used only the sample digest and transcript cross-check.
    files = ["environment", "commands"]
    if not env.get("append_of"):
        files.extend(("builds", "volumes"))
    for name in files:
        suffix = "jsonl" if name == "commands" else "json"
        if finish[f"{name}_sha256"] != sha256(run / f"{name}.{suffix}"):
            raise ValueError(f"archived {name} digest disagrees with completion record")

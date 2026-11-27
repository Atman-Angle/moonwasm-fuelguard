"""Run, replay and minimize the deterministic S17 corpus."""

import argparse
from collections import Counter
from concurrent.futures import ThreadPoolExecutor
from dataclasses import asdict, replace
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))

from integration.generated.recipes import (
    CAPS, COUNT, FUEL_V2, JOIN_SEED, JOIN_VERSION, SPAN_LAYOUTS,
    VERSION, Recipe, generate,
)
from bench.dataset import instrumentation_markers

STAGES = ["FuelPass", "GrowthPass", "StackPass"]
SHARD_SIZE = 64
JOIN_INPUT_SET = "671463f97bb7a1bd30b1fdc599cd57a21f1917bf1a0ccb81706d8b5d915f5fb9"
JOIN_MARKERS = {
    "join-span": b"join-span-debit-first-v1",
    "join-span-cached": b"join-span-packed-cache-v1",
    "join-span-compact": b"join-span-compact-v1",
    "join-span-compact-v2": b"join-span-compact-v2",
}
FUEL_V2_MARKER = (b"production-v1|fuel-v2|diagnostics-v1|metering=join-span"
                  b"|growth=growth-v1|stack=stack-v2|codegen=fuel-v2-inline-v1")
ENGINES = {
    "wasmtime": ["wasmtime", "wast", "-C", "parallel-compilation=n", "-W", "max-wasm-stack=524288"],
    "wasmoon": ["wasmoon", "test", "--show-success"],
}
PROCESS_GROUP = "FUELGUARD_CHECK_GROUP"


def digest(data):
    return hashlib.sha256(data).hexdigest()


def file_hash(path):
    return digest(path.read_bytes())


def save_json(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


class CommandLog:
    def __init__(self, path):
        self.path = path
        self.sequence = 0

    def run(self, args, *, cwd=ROOT, timeout=60, env=None):
        self.sequence += 1
        command = [str(arg) for arg in args]
        label = self.path.parent / f"{self.path.stem}-{self.sequence}"
        exit_code, reason = None, None
        child_env = dict(os.environ if env is None else env)
        leader = os.name == "posix" and PROCESS_GROUP not in child_env
        if leader:
            child_env[PROCESS_GROUP] = "1"
        try:
            # File-backed streams let an inner deadline finish even if a
            # descendant kept stdout open. The outer group owns its cleanup.
            with tempfile.TemporaryFile() as out, tempfile.TemporaryFile() as err, subprocess.Popen(
                    command, cwd=cwd, env=child_env, stdin=subprocess.DEVNULL,
                    stdout=out, stderr=err, start_new_session=leader) as process:
                try:
                    exit_code = process.wait(timeout=timeout)
                except subprocess.TimeoutExpired:
                    reason = f"timeout after {timeout}s"
                    if leader:
                        kill_group(process.pid)
                    else:
                        process.kill()
                    process.wait()
                if leader and exit_code not in (None, 0):
                    kill_group(process.pid)
                out.seek(0)
                err.seek(0)
                stdout, stderr = out.read(), err.read()
        except OSError as error:
            reason = str(error)
            stdout, stderr = b"", b""
        row = {"sequence": self.sequence, "command": command, "cwd": str(cwd), "exit_code": exit_code,
               "environment_error": reason}
        for stream, data in (("stdout", stdout), ("stderr", stderr)):
            row[f"{stream}_sha256"] = digest(data)
            if data:
                path = label.with_suffix(f".{stream}")
                path.write_bytes(data)
                row[stream] = str(path)
        with self.path.open("a", encoding="utf-8") as log:
            log.write(json.dumps(row) + "\n")
        return row, stdout.decode("utf-8", errors="replace")


def kill_group(pid):
    try:
        os.killpg(pid, signal.SIGKILL)
    except ProcessLookupError:
        pass


def build_worker(directory, commands):
    target = ROOT / "_build/s17-worker"
    row, _ = commands.run(["moon", "build", "--target", "wasm", "--release", ".",
                           "--target-dir", target],
                          cwd=ROOT / "integration/generated/worker", timeout=300)
    matches = list((target / "wasm/release/build").rglob("*.wasm"))
    if row["exit_code"] != 0 or len(matches) != 1:
        raise RuntimeError(f"corpus worker build failed, see {commands.path}")
    # Keep the exact worker beside the results so the record survives a rebuild.
    worker = directory / "corpus-worker.wasm"
    worker.write_bytes(matches[0].read_bytes())
    return worker


def module_directive(path):
    binary = path.read_bytes().hex()
    return '(module binary "' + "".join("\\" + binary[i:i + 2]
                                          for i in range(0, len(binary), 2)) + '")'


def join_marker_matches(path, codegen):
    if codegen == FUEL_V2:
        return instrumentation_markers(path) == [FUEL_V2_MARKER]
    expected = (b"production-v1|fuel-v1.2|diagnostics-v1|metering=join-span"
                b"|growth=growth-v1|stack=stack-v2|codegen=" + JOIN_MARKERS[codegen])
    return instrumentation_markers(path) == [expected]


def wast_lines(trial, path, protected, *, inject=False):
    lines = [module_directive(path)]
    if protected and trial.code is not None:
        lines.append('(assert_trap (invoke "run") "unreachable")')
        code, site = trial.code, trial.site
    else:
        expected = " ".join(f"({ty}.const {n + int(inject)})" for ty, n in trial.values)
        lines.append(f'(assert_return (invoke "run") {expected})')
        code, site = 0, 0
    if protected:
        lines.extend((f'(assert_return (get "__moonwasm_trap_code") (i32.const {code}))',
                      f'(assert_return (get "__moonwasm_trap_site") (i32.const {site}))'))
    prefix = trial.protected_prefix if protected and trial.protected_prefix is not None else trial.prefix
    if prefix is not None:
        lines.append(f'(assert_return (get "trace") (i32.const {prefix}))')
    return lines


def run_engine(log, directory, prepared, engine, *, inject):
    path = directory / f"{engine}.wast"
    lines = []
    line_ranges = {}
    for trial, record in prepared:
        start = len(lines) + 1
        for protected, key in ((False, "input"), (True, "output")):
            lines += wast_lines(trial, Path(record["artifact_paths"][key]), protected,
                                inject=inject and protected and record["case_id"] == "g00000")
        line_ranges[record["case_id"]] = [start, len(lines)]
    path.write_text("\n".join(lines) + "\n", encoding="ascii")
    command, stdout = log.run([*ENGINES[engine], path], timeout=150)
    count = sum(line.startswith("(assert_") for line in lines)
    success = command["exit_code"] == 0 and count > 0
    if engine == "wasmoon":
        success = success and bool(re.search(rf"(?m)^  Passed: +{count}$", stdout)
                                   and re.search(r"(?m)^  Skipped: +0$", stdout)
                                   and re.search(r"(?m)^  Failed: +0$", stdout))
    line = None
    if not success and command["exit_code"] is not None:
        stderr = Path(command["stderr"]).read_text(errors="replace") if "stderr" in command else ""
        match = re.search(r"failed directive on .*?:(\d+)", stderr)
        if not match:
            match = re.search(r"(?im)^line (\d+):.*\bFAIL(?:ED)?\b", stdout + stderr)
        if match:
            line = int(match[1])
    return {"status": "PASS" if success else
            ("BLOCKED" if command["environment_error"] else "FAIL"),
            "wast": str(path), "wast_sha256": file_hash(path), "assertions": count,
            "line_ranges": line_ranges, "failure_line": line, **command}


def fail(record, stage, command, actual, signature=None):
    record.update(status="BLOCKED" if command["environment_error"] else "FAIL",
                  stage=stage, exit_code=command["exit_code"], actual=actual,
                  failure_signature=signature)


def engine_signature(result, trial):
    line = result["failure_line"]
    start, end = result["lines"]
    if line is None or not start <= line <= end:
        return None
    role = "original" if line < start + 2 + int(trial.prefix is not None) else "protected"
    directive = Path(result["wast"]).read_text().splitlines()[line - 1]
    match = re.match(r'^\((assert_\w+) \((invoke|get) "([^"]+)"', directive)
    if match:
        return [role, *match.groups()]
    if directive.startswith("(module binary "):
        return [role, "instantiate"]
    return None


def run_shard(recipes, directory, worker, *, inject=False, codegen=FUEL_V2):
    directory.mkdir()
    log = CommandLog(directory / "commands.jsonl")
    records = []
    ready = []
    for recipe in recipes:
        trial = recipe.trial(codegen)
        stem = directory / recipe.case_id
        wat, source, output = (stem.with_suffix(f".{ext}") for ext in ("wat", "wasm", "protected.wasm"))
        wat.write_text(trial.wat + "\n", encoding="ascii")
        record = {
            "case_id": recipe.case_id, "gate_id": "A14", "status": "NOT_RUN",
            "seed": recipe.seed, "generator": JOIN_VERSION if codegen in SPAN_LAYOUTS else VERSION,
            "recipe": asdict(recipe),
            "parent_wat_sha256": (digest(replace(recipe, mutated=False).trial().wat.encode("ascii"))
                                  if recipe.mutated else None),
            "artifact_paths": {"wat": str(wat), "input": str(source), "output": str(output),
                               "command_log": str(log.path)},
            "input_hash": None, "output_hash": None, "engine_config": ENGINES,
            "instrument_config": {**CAPS, "fuel": trial.fuel, "profile": "production-v1", "codegen": codegen},
            "expected": {"original": trial.values, "protected": (
                trial.values if trial.code is None else {"code": trial.code, "site": trial.site}),
                         "trace": trial.prefix,
                         "protected_trace": (trial.prefix if trial.protected_prefix is None
                                             else trial.protected_prefix)},
            "actual": None, "exit_code": None, "trap_code": None, "site_id": None,
            "diagnostic_reason": "no verified controlled trap", "command": {},
        }
        if inject and recipe.index == 0:
            record["expected"]["protected"] = [(ty, n + 1) for ty, n in trial.values]
        records.append(record)
        command, _ = log.run(["wasm-tools", "parse", wat, "-o", source])
        record["command"]["parse"] = command
        if command["exit_code"] != 0:
            fail(record, "parse", command, "cannot assemble generated WAT")
            continue
        record["input_hash"] = file_hash(source)
        command, _ = log.run(["wasm-tools", "validate", source])
        record["command"]["validate_input"] = command
        if command["exit_code"] != 0:
            fail(record, "validate_input", command, "generated input did not validate")
            continue
        ready.append((trial, record))

    if not ready:
        return records, {}
    request = []
    for trial, record in ready:
        request.extend((record["case_id"], trial.fuel, record["artifact_paths"]["input"],
                        record["artifact_paths"]["output"]))
    invocation = ["moonrun", worker] + ([f"--{codegen}"] if codegen != "p0" else [])
    command, stdout = log.run([*invocation, *request], timeout=150)
    try:
        outcomes = [json.loads(line) for line in stdout.splitlines()]
        if [row["case_id"] for row in outcomes] != [row["case_id"] for _, row in ready]:
            raise ValueError("worker IDs differ from request")
    except (ValueError, KeyError, TypeError):
        outcomes = []
    prepared = []
    for i, (trial, record) in enumerate(ready):
        record["command"]["instrument"] = {"sequence": command["sequence"],
                                           "command": list(map(str, invocation)) + list(map(str, request[i * 4:i * 4 + 4])),
                                           "exit_code": command["exit_code"]}
        if command["exit_code"] != 0 or not outcomes:
            fail(record, "instrument", command, "missing, malformed or unsuccessful worker results")
            continue
        outcome = outcomes[i]
        path = Path(record["artifact_paths"]["output"])
        source = Path(record["artifact_paths"]["input"])
        if (outcome.get("error") is not None or outcome.get("stages") != STAGES
                or not path.is_file() or file_hash(source) != record["input_hash"]):
            fail(record, "instrument", command, outcome, outcome.get("error"))
            continue
        record["output_hash"] = file_hash(path)
        if record["output_hash"] == record["input_hash"]:
            fail(record, "instrument", command, "instrumented bytes equal the source")
            continue
        command_out, _ = log.run(["wasm-tools", "validate", path])
        record["command"]["validate_output"] = command_out
        if command_out["exit_code"] != 0:
            fail(record, "validate_output", command_out, "instrumented bytes did not validate")
            continue
        if codegen in SPAN_LAYOUTS and not join_marker_matches(path, codegen):
            fail(record, "verify_codegen", command_out, "artifact does not identify the requested layout")
            continue
        prepared.append((trial, record))

    engines = {engine: run_engine(log, directory, prepared, engine, inject=inject)
               for engine in ENGINES} if prepared else {}
    for trial, record in prepared:
        results = {}
        for engine, result in engines.items():
            results[engine] = {k: v for k, v in result.items() if k != "line_ranges"}
            results[engine]["lines"] = result["line_ranges"][record["case_id"]]
        record["command"]["execute"] = results
        rejected = next((e for e, result in results.items() if result["status"] == "FAIL"), None)
        if rejected is None:
            rejected = next((e for e, result in results.items() if result["status"] == "BLOCKED"), None)
        if rejected:
            result = results[rejected]
            fail(record, f"execute:{rejected}", result,
                 "engine did not complete all shard assertions; replay isolates the case",
                 engine_signature(result, trial))
        else:
            record.update(status="PASS", stage="execute", exit_code=0,
                          actual={"verified": record["expected"], "engines": list(results)},
                          trap_code=trial.code, site_id=trial.site,
                          diagnostic_reason=None if trial.code is not None else "returned normally")
    return records, engines


def run_corpus(directory, worker, recipes, jobs, *, inject=False, codegen=FUEL_V2):
    groups = [recipes[i:i + SHARD_SIZE] for i in range(0, len(recipes), SHARD_SIZE)]
    seen = set()
    status_counts = Counter()
    input_validated = instrumented = output_validated = executed = controlled = 0
    failed_shards = []
    counterexample = None
    duplicate_ids = []
    with (directory / "cases.jsonl").open("w", encoding="utf-8") as case_log:
        def run(group):
            return run_shard(group, directory / f"shard-{group[0].index:05d}", worker,
                             inject=inject, codegen=codegen)

        with ThreadPoolExecutor(max_workers=jobs) as pool:
            for group, (records, engines) in zip(groups, pool.map(run, groups)):
                for record in records:
                    sha = record["input_hash"]
                    if sha is not None:
                        if sha in seen:
                            duplicate_ids.append(record["case_id"])
                            record.update(status="FAIL", stage="dedup", actual="duplicate input SHA-256")
                        seen.add(sha)
                    command = record["command"]
                    input_validated += command.get("validate_input", {}).get("exit_code") == 0
                    instrumented += record["output_hash"] is not None
                    output_validated += command.get("validate_output", {}).get("exit_code") == 0
                    executed += record["status"] == "PASS"
                    controlled += record["status"] == "PASS" and record["trap_code"] is not None
                    status_counts[record["status"]] += 1
                    case_log.write(json.dumps(record, ensure_ascii=False) + "\n")
                if any(row["status"] == "FAIL" for row in records):
                    failed_shards.append([group[0].index, group[-1].index])
                    if counterexample is None:
                        counterexample = locate_counterexample(records, engines)
                case_log.flush()
                if len(seen) % 1024 == 0 or group is groups[-1]:
                    print(f"generated: {len(seen)} unique inputs, {executed} verified", flush=True)
    reduction = None
    if counterexample is not None:
        reduction = directory / "counterexample"
        reduction.mkdir()
        recipe = Recipe(**counterexample["recipe"])
        try:
            reduced = minimize(recipe, reduction, worker, inject=inject, codegen=codegen)
            save_json(reduction / "recipe.json", reduced["recipe"])
        except (OSError, ValueError) as error:
            save_json(reduction / "reduction.json", {"status": "BLOCKED", "reason": str(error)})
    summary = {
        "generator": JOIN_VERSION if codegen in SPAN_LAYOUTS else VERSION,
        "codegen": codegen, "seed": recipes[0].seed, "requested": len(recipes),
        "generated": sum(not item.mutated for item in recipes),
        "mutated": sum(item.mutated for item in recipes),
        "input_validated": input_validated, "unique_input_hashes": len(seen),
        "input_set_sha256": digest("".join(sorted(seen)).encode("ascii")),
        "instrumented": instrumented, "output_validated": output_validated,
        "executed_both_engines": executed, "controlled_traps_both_engines": controlled,
        "duplicates": duplicate_ids, "statuses": dict(status_counts), "failed_shards": failed_shards,
        "worker_sha256": file_hash(worker), "cases_sha256": file_hash(directory / "cases.jsonl"),
        "counterexample": str(reduction) if reduction else None,
        "families": dict(Counter(item.family for item in recipes)),
        "status": "FAIL" if status_counts["FAIL"] else
                  "BLOCKED" if status_counts["BLOCKED"] else
                  "PASS" if executed == len(recipes) == COUNT else "NOT_RUN",
    }
    if codegen in SPAN_LAYOUTS and recipes[0].seed == JOIN_SEED and len(recipes) == COUNT:
        frozen = summary["input_set_sha256"] == JOIN_INPUT_SET
        summary["frozen_input_set_match"] = frozen
        if summary["status"] == "PASS" and (not frozen or controlled < 2727):
            summary["status"] = "FAIL"
    save_json(directory / "summary.json", summary)
    return summary


def locate_counterexample(records, engines):
    for record in records:
        if record["status"] == "FAIL" and not record["stage"].startswith("execute:"):
            return record
    for engine, result in engines.items():
        if result["status"] != "FAIL":
            continue
        line = result["failure_line"]
        if line is not None:
            for record in records:
                start, end = result["line_ranges"].get(record["case_id"], (0, 0))
                if start <= line <= end:
                    return record
    return None


def minimize(recipe, directory, worker, *, inject=False, codegen=FUEL_V2):
    attempts = []

    def probe(candidate):
        where = directory / f"probe-{len(attempts):02d}"
        [result], _ = run_shard([candidate], where, worker, inject=inject, codegen=codegen)
        attempts.append(result)
        save_json(directory / "attempts.json", attempts)
        return result

    original = probe(recipe)
    if original["status"] != "FAIL":
        save_json(directory / "reduction.json", {"status": original["status"],
                  "reason": "no reproducible individual failure", "original": original})
        return original
    if original["failure_signature"] is None:
        save_json(directory / "reduction.json", {"status": "NOT_RUN",
                  "reason": "individual failure has no stable coordinate", "original": original})
        return original
    best, record = recipe, original
    # Search smaller grammar instances. Keep the same failing phase and engine.
    for field, alternatives in (("size", range(1, recipe.size)),
                                ("salt", (0, 1, recipe.salt & 0xff)),
                                ("mutated", (False,) if recipe.mutated else ())):
        for value in alternatives:
            candidate = replace(best, **{field: value})
            if len(candidate.trial(codegen).wat) > len(best.trial(codegen).wat) or value >= getattr(best, field):
                continue
            result = probe(candidate)
            if (result["status"] == "FAIL" and result["stage"] == original["stage"] and
                    result["failure_signature"] == original["failure_signature"]):
                best, record = candidate, result
                break
    save_json(directory / "reduction.json", {"status": "FAIL", "original": original,
              "minimized": record, "attempts": len(attempts)})
    return record


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("run", "replay", "minimize"))
    parser.add_argument("--out", type=Path)
    parser.add_argument("--codegen", choices=(FUEL_V2,), default=FUEL_V2)
    parser.add_argument("--seed", type=int)
    parser.add_argument("--index", type=int, default=0)
    parser.add_argument("--recipe", type=Path, help="replay a JSON recipe saved by the reducer")
    parser.add_argument("--limit", type=int, default=COUNT, help="smoke only when below 10,000")
    parser.add_argument("--jobs", type=int, default=min(8, os.cpu_count() or 1))
    parser.add_argument("--inject-failure", action="store_true",
                        help="test the checker with a deliberately wrong protected result for sample 0")
    args = parser.parse_args()
    seed = args.seed if args.seed is not None else JOIN_SEED
    if not 1 <= args.limit <= COUNT or not 1 <= args.jobs <= 32:
        parser.error("limit must be 1–10000 and jobs must be 1–32")
    try:
        if args.out is None:
            base = ROOT / "_build/s17"
            base.mkdir(parents=True, exist_ok=True)
            out = Path(tempfile.mkdtemp(prefix="corpus-", dir=base))
        else:
            out = args.out.resolve()
            out.mkdir(parents=True)
    except OSError as error:
        print(error, file=sys.stderr)
        return 2
    print(out, flush=True)
    try:
        worker = build_worker(out, CommandLog(out / "setup.jsonl"))
        if args.action == "run":
            summary = run_corpus(out, worker, [generate(seed, i, args.codegen) for i in range(args.limit)],
                                 args.jobs, inject=args.inject_failure, codegen=args.codegen)
            return {"PASS": 0, "FAIL": 1, "BLOCKED": 2, "NOT_RUN": 2}[summary["status"]]
        recipe = (Recipe(**json.loads(args.recipe.read_bytes())) if args.recipe
                  else generate(seed, args.index, args.codegen))
        if args.action == "minimize":
            record = minimize(recipe, out, worker, inject=args.inject_failure, codegen=args.codegen)
            save_json(out / "recipe.json", record["recipe"])
        else:
            [record], _ = run_shard([recipe], out / "sample", worker, inject=args.inject_failure, codegen=args.codegen)
        save_json(out / "case.json", record)
        return {"PASS": 0, "FAIL": 1, "BLOCKED": 2}[record["status"]]
    except (RuntimeError, OSError, ValueError) as error:
        save_json(out / "summary.json", {"status": "BLOCKED", "reason": str(error)})
        print(error, file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())

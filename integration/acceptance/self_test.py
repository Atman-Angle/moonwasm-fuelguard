"""Exercise the acceptance exit contract using real positive and negative checks."""

import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
ENTRY = ROOT / "integration/acceptance/check.py"
CORPUS = ROOT / "integration/generated/check.py"
sys.path.insert(0, str(ROOT))

from integration.generated.check import CommandLog


def execute(argv, output, expected_exit, env=None):
    command = [sys.executable, "-B", str(argv[0]), *map(str, argv[1:])]
    result = subprocess.run(command, env=env, cwd=ROOT, capture_output=True, timeout=300)
    output.with_suffix(".stdout").write_bytes(result.stdout)
    output.with_suffix(".stderr").write_bytes(result.stderr)
    print(f"{output.name} exit={result.returncode}", flush=True)
    if result.returncode != expected_exit:
        raise RuntimeError(f"{output}: expected exit {expected_exit}, got {result.returncode}")


def require(condition, why):
    if not condition:
        raise RuntimeError(why)


def nested_timeout(base):
    started, escaped = base / "started", base / "escaped"
    leaf = ("from pathlib import Path; import time; "
            f"Path({str(started)!r}).touch(); time.sleep(4); Path({str(escaped)!r}).touch()")
    child = ("from pathlib import Path; from integration.generated.check import CommandLog; "
             f"CommandLog(Path({str(base / 'inner.jsonl')!r})).run("
             f"{[sys.executable, '-B', '-c', leaf]!r}, timeout=10)")
    command, _ = CommandLog(base / "timeout.jsonl").run([sys.executable, "-B", "-c", child], timeout=2)
    require(command["environment_error"] == "timeout after 2s" and started.is_file(),
            "nested timeout did not exercise a live descendant")
    time.sleep(2.2)
    require(not escaped.exists(), "nested subprocess escaped the outer deadline")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path)
    options = parser.parse_args()
    if options.out:
        base = options.out.resolve()
        base.mkdir(parents=True)
    else:
        parent = ROOT / "_build/s17"
        parent.mkdir(parents=True, exist_ok=True)
        base = Path(tempfile.mkdtemp(prefix="self-test-", dir=parent))
    print(base, flush=True)
    empty_path = base / "empty-path"
    empty_path.mkdir()
    scenarios = (
        ("success", ["--group", "rejections"], 0, "PASS", "A15", None),
        ("injected", ["--group", "generated", "--inject-failure"], 1, "FAIL", "A14", None),
        ("missing", ["--group", "generated"], 2, "BLOCKED", "A14",
         {**os.environ, "PATH": str(empty_path)}),
        ("pending", ["--group", "performance", "--group", "release"], 2, "NOT_RUN", "A24", None),
    )
    for name, args, exit_code, status, gate, env in scenarios:
        directory = base / name
        execute([ENTRY, *args, "--out", directory], directory, exit_code, env)
        report = json.loads((directory / "report.json").read_bytes())
        gates = {row["id"]: row["status"] for row in report["gates"]}
        require(set(gates) == {f"A{n:02d}" for n in range(1, 25)}, "incomplete gate report")
        require(report["status"] == gates[gate] == status and report["exit_code"] == exit_code,
                f"{name}: report disagrees with observed exit or gate")
        require(report["overall"] != "PASS", f"{name}: unfinished gates yielded a production pass")
        if name == "missing":
            require("missing moon" in report["checks"][0]["reason"], "missing-tool reason lost")
    reduction = base / "injected/generated/counterexample"
    result = json.loads((reduction / "reduction.json").read_bytes())
    first, minimized = result["original"], result["minimized"]
    require(first["stage"].startswith("execute:") and minimized["stage"] == first["stage"],
            "injected expectation did not fail at the same engine stage after reduction")
    require(first["failure_signature"] == minimized["failure_signature"] ==
            ["protected", "assert_return", "invoke", "run"],
            "reduction changed the failing protected-result assertion")
    require(Path(minimized["artifact_paths"]["wat"]).stat().st_size <
            Path(first["artifact_paths"]["wat"]).stat().st_size, "counterexample was not reduced")
    recipe = reduction / "recipe.json"
    execute([CORPUS, "replay", "--recipe", recipe, "--inject-failure", "--out", base / "retry-bad"],
            base / "retry-bad", 1)
    execute([CORPUS, "replay", "--recipe", recipe, "--out", base / "retry-good"], base / "retry-good", 0)
    nested_timeout(base)
    print("S17 acceptance exit contract and counterexample replay passed", flush=True)


if __name__ == "__main__":
    main()

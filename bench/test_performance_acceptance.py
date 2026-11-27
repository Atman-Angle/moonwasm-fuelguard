"""Synthetic archive tests. No real fixture is executed."""

import json
from contextlib import redirect_stderr
from io import StringIO
import shutil
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import patch

import numpy as np

import performance_evidence as evidence
import run as runner
import summarize as replay
from dataset import build_scale, section, sha256, uleb, write_json


def custom(name, payload):
    return section(0, uleb(len(name)) + name + payload)


class SyntheticRun(runner.Run):
    def __init__(self, out, cases, slow_application):
        super().__init__(out)
        self.cases = {case["id"]: case for case in cases}
        self.slow_application = slow_application
        self.pid = 0

    def command(self, label, argv, **_):
        args = list(map(str, argv))
        self.pid += 1
        content = ""
        if Path(args[0]).name in ("wasmoon", "wasmtime-worker"):
            schedule = Path(args[1]).read_bytes()
            case = self.cases[Path(args[-1]).parent.name]
            slow = self.slow_application or case["kind"] == "micro"
            times = [100, 120, 400 if slow else 150]
            setup = 0 if args[2] == "hot" else 20
            content = "compile 1 1 1\n" * 3 + "".join(
                f"sample {variant} {setup} {times[variant] - setup}\n" for variant in schedule)
        elif Path(args[0]).name == "build":
            source, output = map(Path, args[2:4])
            case = self.cases[source.parent.name]
            if args[1] == "fuel":
                output.write_bytes(source.read_bytes())
                phases = runner.FUEL_V2_ONLY_STAGES
            else:
                marker = (b"production-v1|fuel-v2|diagnostics-v1|metering=join-span"
                          b"|growth=growth-v1|stack=stack-v2|codegen=fuel-v2-inline-v1")
                padding = custom(b"padding", bytes(11000)) if case["kind"] == "micro" else b""
                output.write_bytes(source.read_bytes() + custom(b"fuelguard.instrumented", marker) + padding)
                phases = runner.FUEL_V2_BUILD_STAGES
            content = "".join(f"{phase} 1\n" for phase in phases)
        elif args[0] == "moonrun" and args[2] != "verify":
            source, output, manifest = map(Path, (args[2], args[4], args[-1]))
            case = self.cases[source.parent.name]
            shutil.copyfile(source.parent / "fuel-v2-0.wasm", output)
            write_json(manifest, {
                "schema": "fuelguard-manifest-v2", "deterministic": True,
                "input_sha256": sha256(source), "output_sha256": sha256(output),
                "instrumentation": {
                    "profile": "production-v1", "fuel_model": "fuel-v2", "growth_model": "growth-v1",
                    "stack_model": "stack-v2", "diagnostics_abi": "diagnostics-v1",
                    "codegen": evidence.FROZEN_LAYOUT,
                    "config": {"fuel": runner.FUEL, "max_stack_units": str(case["stack_units"]),
                               "max_call_depth": str(case["depth"]), "max_memory_pages": 64,
                               "max_table_elements": 64, "allowed_imports": []},
                },
            })
        stdout, stderr = label + ".stdout", label + ".stderr"
        (self.out / stdout).write_text(content, encoding="ascii")
        (self.out / stderr).touch()
        row = {"argv": args, "status": 0, "pid": self.pid, "wall_ns": 1000,
               "peak_rss_kib": 600000, "stdout": stdout, "stderr": stderr}
        with self.commands.open("a", encoding="utf-8") as log:
            log.write(json.dumps(row) + "\n")
        return content, row


class AcceptanceTests(unittest.TestCase):
    def test_threshold_boundaries_and_process_pairing(self):
        for original, limit in ((5387, 20747), (10239, 25599), (10240, 30720), (13000, 39000)):
            self.assertEqual(evidence.size_limit(original), limit)
            self.assertEqual(evidence.size_status(original, limit), "PASS")
            self.assertEqual(evidence.size_status(original, limit + 1), "FAIL")
        self.assertEqual(evidence.size_limit(10239), 10239 + 15 * 1024)
        self.assertEqual(evidence.size_limit(10240), 3 * 10240)
        self.assertEqual(replay.gate({"high": 2.0}, 2.0), "PASS")
        self.assertEqual(replay.gate({"high": 2.01}, 2.0), "FAIL")
        # Perfectly correlated repeats within each process must not narrow the CI.
        groups = np.asarray([[[10, 20]], [[20, 20]], [[15, 45]], [[5, 20]]])
        _, short = replay.statistics(groups, 200, np.random.default_rng(23))
        _, long = replay.statistics(np.repeat(groups, 100, axis=1), 200, np.random.default_rng(23))
        np.testing.assert_array_equal(short[0], long[0])
        paired = groups.copy()
        paired[:, :, 1] = 2 * paired[:, :, 0]
        _, draws = replay.statistics(paired, 200, np.random.default_rng(23))
        np.testing.assert_array_equal(draws[:, 1] / draws[:, 0], 2)

    def test_holdout_flag_requires_freeze_before_reading_inputs(self):
        argv = ["run.py", "--out", "unused", "--wasmtime-c-api", "unused",
                "--host-record", "unused", "--compare-fuel-v2", "--holdout"]
        with patch.object(sys, "argv", argv), patch.object(runner, "read_dataset") as read, redirect_stderr(StringIO()):
            with self.assertRaises(SystemExit) as err:
                runner.main()
            self.assertEqual(err.exception.code, 2)
            read.assert_not_called()

    def test_full_archive_replay_and_final_scope(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            dataset = self.make_dataset(root)
            dataset_path = root / "dataset.json"
            write_json(dataset_path, dataset)
            digest = sha256(dataset_path)
            with patch.object(replay, "DATASET_SHA256", digest), patch.object(evidence, "FUEL_V2_DATASET_HASHES", (digest,)):
                tune = self.archive(root / "tuning", dataset_path, "tuning")
                tuned = replay.summarize([tune])
                self.assertEqual(tuned["schema"], "fuelguard-bench-report-v2")
                self.assertEqual(tuned["tuning_results"], {"A17": "PASS", "A19": "PASS"})
                self.assertEqual(tuned["final_acceptance"], {"A17": "NOT_RUN", "A19": "NOT_RUN"})
                self.assertEqual(tuned["performance_verdict"], "NOT_RUN")
                self.assertEqual(tuned["engineering_checks"]["A20"]["status"], "FAIL")
                lock = root / "freeze.json"
                evidence.create_candidate_lock(tune, lock)
                for label, slow, outcome in (("passed", False, "FINAL_PASS"), ("failed", True, "FINAL_FAIL")):
                    holdout = self.archive(root / label, dataset_path, "holdout", tune=tune, lock=lock, slow=slow)
                    report = replay.summarize([holdout])
                    self.assertEqual(report["performance_verdict"], outcome)
                    self.assertEqual(report["engineering_checks"]["A20"]["status"], "NOT_RUN")
                    self.assertNotIn("tuning_results", report)
                    self.assertEqual(set(report["provenance"]["inputs"]), {"holdout-app", "holdout-micro"})
                self.assertEqual(report["final_acceptance"], {"A17": "FAIL", "A19": "PASS"})
                with self.assertRaisesRegex(ValueError, "fixed sample"):
                    replay.summarize([holdout, holdout])
                env = evidence.read_json(holdout / "environment.json")
                for key, changed in (("source", {"changed": "hash"}), ("tools", {
                        "moon": {"version": "changed", "sha256": "changed"}}),
                        ("configuration_sha256", "changed"), ("start_utc_ns", 0)):
                    with self.subTest(key=key), self.assertRaisesRegex(ValueError, "candidate frozen"):
                        evidence.verify_holdout_run(holdout, {**env, key: changed})
                samples = holdout / "samples.jsonl"
                original = samples.read_bytes()
                samples.write_bytes(original + b"\n")
                with self.assertRaisesRegex(ValueError, "raw sample file changed"):
                    replay.summarize([holdout])
                samples.write_bytes(original)
                (holdout / "candidate-lock.json").unlink()
                with self.assertRaises(FileNotFoundError):
                    replay.summarize([holdout])

    @staticmethod
    def make_dataset(root):
        dataset = {"config": {"fuel": int(runner.FUEL), "memory_pages": 64, "table_elements": 64},
                   "sampling": {"processes": 3, "build_processes": 1, "samples": 3, "warmups": 1,
                                "bootstrap_draws": 100, "bootstrap_seed": 17, "schedule_seed": 49},
                   "entries": []}
        for split in ("tuning", "holdout"):
            for kind in ("application", "micro"):
                name = f"{split}-{'app' if kind == 'application' else kind}"
                original = root / (name + ".wasm")
                original.write_bytes(b"\0asm\x01\0\0\0" + custom(b"test", name.encode()))
                dataset["entries"].append(dict(
                    id=name, path=str(original), bytes=original.stat().st_size, sha256=sha256(original),
                    split=split, kind=kind, entry="_start", core_start=False,
                    stdout="", result_i32=None, windows={"lifecycle": 1, "hot": 1},
                    stack_units=100, depth=10))
        build = root / "build.wasm"
        build_scale(build, 1, 8, 1024)
        dataset["entries"].append(dict(id="build-scale", kind="build", split="tuning", windows={},
                                       bytes=1024, functions=1, instructions=8, sha256=sha256(build),
                                       stdout="", depth=10, stack_units=100))
        return dataset

    @staticmethod
    def archive(path, dataset_path, scope, *, tune=None, lock=None, slow=False):
        dataset = evidence.read_json(dataset_path)
        cases = evidence.cases_for(dataset, scope)
        run = SyntheticRun(path, cases, slow)
        workers = {name: path / filename for name, filename in evidence.FROZEN_BINARIES.items()}
        for name, worker in workers.items():
            worker.write_text(name, encoding="ascii")
        lib = path / "libwasmtime.so"
        lib.write_bytes(b"test library")
        shutil.copyfile(dataset_path, path / "dataset.json")
        if scope == "holdout":
            shutil.copyfile(lock, path / "candidate-lock.json")
            for name in ("environment", "finished"):
                shutil.copyfile(tune / f"{name}.json", path / f"candidate-tuning-{name}.json")
        write_json(path / "environment.json", dict(
            performance_scope=scope, variants=evidence.FUEL_V2_VARIANTS, head="test", source={"src": "test"},
            dataset_sha256=sha256(dataset_path), configuration_sha256=evidence.configuration_digest(dataset),
            proposal_sha256="proposal", smoke=False, build_only=False, cells=None, append_of=None,
            candidate_lock_sha256=sha256(lock) if lock else None, start_utc_ns=time.time_ns(),
            binaries={name: sha256(worker) for name, worker in workers.items()}, tools={},
            python_sha256="python", wasmtime_lib_sha256=sha256(lib)))
        protocol = evidence.timing_protocol(dataset, scope)
        artifacts = runner.populate(run, cases, workers["build"], workers["cli"],
                                    protocol["build_processes"], evidence.FUEL_V2_VARIANTS)
        runner.measure(run, cases, workers, artifacts, protocol, False, 0, evidence.FUEL_V2_VARIANTS)
        names = ("environment.json", "commands.jsonl", "builds.json", "volumes.json", "samples.jsonl")
        write_json(path / "finished.json", {"finish_utc_ns": time.time_ns(),
                   **{Path(name).stem + "_sha256": sha256(path / name) for name in names}})
        return path

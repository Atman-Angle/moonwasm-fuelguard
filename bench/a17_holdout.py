"""Construct the second holdout split using fixed settings and original-only output."""
import argparse
import json
import subprocess

from dataset import BENCH, MANIFEST, ROOT, arithmetic, check_start, sha256, write_json


def generate():
    data = json.loads(MANIFEST.read_bytes())
    directory = BENCH / "fixtures" / "a17-holdout"
    directory.mkdir()
    cases = {case["id"]: case for case in data["entries"] if case["split"] == "holdout"}

    def record(case, path):
        subprocess.run(["wasm-tools", "validate", "--features=-simd", path], check=True)
        check_start(path, case)
        case.update(path=path.relative_to(ROOT).as_posix(), sha256=sha256(path),
                    bytes=path.stat().st_size)

    recipes = {
        "json_parse": [("rounds=200", "rounds=217"), ("'alpha'", "'omega'"),
                       ("'gamma'", "'kappa'")],
        "lisp_eval": [("(fib 18)", "(fib 19)"), ("(count 400)", "(count 421)")],
        "sha256_hash": [("rounds=32", "rounds=37")],
    }
    # The frozen binaries use scalar code. Change only the loop bounds and
    # existing UTF-16LE data, keeping every Wasm section length intact.
    round_limits = {
        "json_parse": (0x2B33, bytes.fromhex("41 c8 01"), bytes.fromhex("41 d9 01")),
        "sha256_hash": (0x22CE, bytes.fromhex("41 20"), bytes.fromhex("41 25")),
    }
    tuning = [case for case in data["entries"] if case["split"] == "tuning"]
    for name, changes in recipes.items():
        case = cases["holdout-" + name]
        path = directory / (name + ".wasm")
        source = ROOT / "fixtures" / "workloads" / name / path.name
        expected = next(row["sha256"] for row in tuning if row.get("path") == source.relative_to(ROOT).as_posix())
        if sha256(source) != expected:
            raise ValueError(f"input changed: {source}")
        wasm = source.read_bytes()
        if name in round_limits:
            offset, old, new = round_limits[name]
            if wasm[offset:offset + len(old)] != old:
                raise ValueError(f"unexpected loop bound: {source}")
            wasm = wasm[:offset] + new + wasm[offset + len(old):]
        for old, new in changes:
            old_bytes = old.encode("utf-16le")
            new_bytes = new.encode("utf-16le")
            if len(old_bytes) != len(new_bytes) or wasm.count(old_bytes) != 1:
                raise ValueError(f"unexpected input data: {source}, {old}")
            wasm = wasm.replace(old_bytes, new_bytes)
        path.write_bytes(wasm)
        case["stdout"] = subprocess.check_output(["wasmtime", "run", path], text=True)
        record(case, path)
    for start_only in (False, True):
        name = "start" if start_only else "call"
        case = cases["holdout-" + name]
        path = directory / (name + ".wasm")
        case["result_i32"] = arithmetic(path, 6119, 13, start_only)
        record(case, path)
    data["holdout_generation"] = {
        "recipe": "a17-frozen-scalar-inputs-v1",
        "base_dataset_sha256": sha256(MANIFEST),
    }
    manifest = BENCH / "dataset-a17-holdout.json"
    write_json(manifest, data)
    print(sha256(manifest))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.parse_args()
    generate()

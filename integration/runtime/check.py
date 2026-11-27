"""S02 test driver. Each invocation uses a fresh engine process."""

import hashlib
import json
import os
import platform
import re
import shlex
import shutil
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "_build/s02-runtime"
FIXTURES = {
    "hello": ("fixtures/hello/hello.wasm", "5050\n111\n190"),
    "json_parse": ("fixtures/workloads/json_parse/json_parse.wasm", "json5 rounds=200 checksum=8928400"),
    "lisp_eval": ("fixtures/workloads/lisp_eval/lisp_eval.wasm", "Number(2584)\nNumber(0)"),
    "sha256_hash": (
        "fixtures/workloads/sha256_hash/sha256_hash.wasm",
        "sha256 rounds=32 bytes=4096 checksum=132768\n"
        "words=-807933589 1631200399 1145861550 -1471824509 -268182326 1702735228 1915947960 668078838",
    ),
}
VERSIONS = {"wasmoon": "0.18.0", "wasmtime": "50.0.0", "wasm-tools": "1.263.0"}
_dataset = json.loads((ROOT / "bench/dataset.json").read_bytes())
_tuning_hashes = {case["path"]: case["sha256"] for case in _dataset["entries"]
                  if case["split"] == "tuning" and case["kind"] == "application"}
BASELINE_HASHES = {name: _tuning_hashes[path] for name, (path, _) in FIXTURES.items()}


def acceptance_directory():
    path = os.environ.get("FUELGUARD_CHECK_EVIDENCE")
    return Path(path).resolve() if path else None


def sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def run(case, args, accept, timeout=30):
    command = [str(arg) for arg in args]
    print(f"{case}: {shlex.join(command)}", flush=True)
    try:
        result = subprocess.run(
            command, stdin=subprocess.DEVNULL, capture_output=True, timeout=timeout, cwd=ROOT
        )
    except subprocess.TimeoutExpired as error:
        (OUT / f"{case}.stdout").write_bytes(error.stdout or b"")
        (OUT / f"{case}.stderr").write_bytes(error.stderr or b"")
        raise RuntimeError(f"{case}: timeout after {timeout}s") from error
    (OUT / f"{case}.stdout").write_bytes(result.stdout)
    (OUT / f"{case}.stderr").write_bytes(result.stderr)
    stdout = result.stdout.decode(errors="replace").strip()
    stderr = result.stderr.decode(errors="replace").strip()
    print(json.dumps({
        "case": case, "exit": result.returncode,
        "stdout_sha256": sha256(OUT / f"{case}.stdout"),
        "stderr_sha256": sha256(OUT / f"{case}.stderr"),
    }), flush=True)
    if not accept(result.returncode, stdout, stderr):
        raise RuntimeError(f"{case}: unexpected exit or output (see {OUT})\n{stdout}\n{stderr}")
    return stdout


def ok(code, _stdout, _stderr):
    return code == 0


def artifact(name, path):
    print(json.dumps({"artifact": name, "path": str(path), "sha256": sha256(path)}))
    return path


def encoded_inputs():
    for name, (path, _) in FIXTURES.items():
        if sha256(ROOT / path) != BASELINE_HASHES[name]:
            raise RuntimeError(f"{name}: input hash differs from the frozen benchmark dataset")

    modules = {}
    for name in ("return", "trap", "start-trap"):
        path = OUT / f"{name}.wasm"
        run(f"encode-{name}", [
            "wasm-tools", "parse", ROOT / f"integration/runtime/{name}.wat", "-o", path,
        ], ok)
        modules[name] = path

    original = ROOT / FIXTURES["hello"][0]
    instrumented = OUT / "hello.fuel.wasm"
    instrumented.unlink(missing_ok=True)
    run("encode-hello-fuel", [
        "moon", "run", "cmd/instrument", "--target", "wasm", "--",
        original, "-o", instrumented, "--fuel", "100000", "--profile", "fuel-growth-v1", "--max-memory-pages", "64", "--max-table-elements", "64",
        "--allow-import", "wasi_snapshot_preview1.fd_write",
    ], ok, timeout=180)
    modules["hello-fuel"] = instrumented
    for name, (path, _) in FIXTURES.items():
        modules[name] = ROOT / path
    for name, path in modules.items():
        artifact(name, path)
        run(f"validate-{name}", ["wasm-tools", "validate", path], ok)
    malformed = OUT / "truncated.wasm"
    malformed.write_bytes(modules["return"].read_bytes()[:-1])
    artifact("truncated", malformed)
    run("validate-truncated", ["wasm-tools", "validate", malformed],
        lambda code, _out, err: code == 1 and "unexpected end-of-file" in err)

    def imports(name, path):
        wat = run(f"print-{name}", ["wasm-tools", "print", path], ok)
        return re.findall(r"^\s*\(import .*$", wat, flags=re.MULTILINE)

    if imports("hello", original) != imports("hello-fuel", instrumented):
        raise RuntimeError("instrumentation changed the fixture's imports")
    return modules


def invoke(engine, path, export=None):
    if engine == "wasmoon":
        return ["wasmoon", "run", "-S", "inherit-stdout", path] + (
            ["--invoke", export] if export else []
        )
    args = ["wasmtime", "run", "-W", "max-wasm-stack=524288"]
    return args + (["--invoke", export] if export else []) + [path]


def expected_return(value):
    return lambda code, out, _err: code == 0 and out == str(value)


def unreachable(code, out, err):
    return code > 0 and "unreachable" in (out + err).lower()


def runtime_checks(modules):
    for engine in ("wasmoon", "wasmtime"):
        for name, (_, expected) in {**FIXTURES, "hello-fuel": FIXTURES["hello"]}.items():
            run(f"{engine}-{name}", invoke(engine, modules[name]),
                lambda code, out, _err: code == 0 and out == expected)
        run(f"{engine}-return", invoke(engine, modules["return"], "answer"), expected_return(42))
        run(f"{engine}-diagnostic-getter",
            invoke(engine, modules["return"], "read_diagnostic"), expected_return(0))
        run(f"{engine}-trap", invoke(engine, modules["trap"], "run_trap"), unreachable)
        run(f"{engine}-start-trap", invoke(engine, modules["start-trap"], "answer"),
            lambda code, out, err: unreachable(code, out, err) and not out
            and ("instantiating module" in err or "failed to instantiate" in err))
        print(f"{engine}: diagnostic getter readable on success; "
              "CLI has no retained instance for trap inspection; initialization diagnostic unavailable")


def main():
    if platform.system() != "Linux" or platform.machine() != "x86_64":
        raise SystemExit("S02 requires x86_64 Linux or WSL2")
    import resource

    OUT.mkdir(parents=True, exist_ok=True)
    print(platform.platform(), platform.libc_ver(), "RLIMIT_STACK", resource.getrlimit(resource.RLIMIT_STACK))
    print("Wasmtime max-wasm-stack=524288; fuel and epoch interruption disabled (CLI defaults)")
    for name, version in VERSIONS.items():
        executable = shutil.which(name)
        if executable is None:
            raise SystemExit(f"missing {name} {version}; see integration/runtime/README.md")
        artifact(name, executable)
        run(f"version-{name}", [executable, "--version"], lambda code, out, err:
            code == 0 and re.search(rf"(?<![\d.]){re.escape(version)}(?![\d.])", out + err))
    run("version-moon", ["moon", "version"], ok)
    runtime_checks(encoded_inputs())
    print("S02 runtime smoke checks passed")


if __name__ == "__main__":
    main()

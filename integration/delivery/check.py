"""Exercise real S15 publication and the CLI pair verifier."""
import argparse
import hashlib
import json
import os
import shutil
import subprocess
import tempfile
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "fixtures/hello/hello.wasm"
FLAGS = (
    "--max-stack-units", "100000", "--max-call-depth", "128",
    "--max-memory-pages", "64", "--max-table-elements", "64",
    "--allow-import", "wasi_snapshot_preview1.fd_write",
)


def run(args, expected=None, diagnostic="", cwd=ROOT):
    result = subprocess.run([str(arg) for arg in args], cwd=cwd, env={**os.environ, "LC_ALL": "C"},
                            capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=90)
    if expected is not None:
        assert result.returncode == expected and diagnostic.lower() in result.stdout.lower(), (
            args, result.returncode, result.stdout, result.stderr,
        )
    print(f"exit={result.returncode} {args!r}", flush=True)
    if result.returncode == 2 and result.stdout:
        print(result.stdout.strip(), flush=True)
    return result


def instrument(tool, source, output, report, fuel="100000"):
    return [*tool, source, "-o", output, "--report", report, "--fuel", fuel, *FLAGS]


def verify(tool, output, report, expected=0, diagnostic=""):
    return run([*tool, "verify", output, "--report", report], expected, diagnostic)


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def no_temps(*dirs):
    for directory in dirs:
        assert not list(directory.glob(".fuelguard-*.tmp")), list(directory.iterdir())


def publication_cases(tool, work):
    source = work / "source.wasm"
    shutil.copyfile(SOURCE, source)
    source_hash = sha256(source)
    existing = work / "existing.wasm"
    existing.write_bytes(b"existing file")
    existing_hash = sha256(existing)
    absent = work / "untouched.json"
    run(instrument(tool, source, existing, absent), 2, "output path already exists")
    run(instrument(tool, source, absent, existing), 2, "report path already exists")
    assert sha256(existing) == existing_hash and not absent.exists()

    alias = work / "hard.wasm"
    os.link(source, alias)
    for candidate in (source, alias):
        run(instrument(tool, source, candidate, absent), 2, "output")
        run(instrument(tool, source, absent, candidate), 2, "report")
        assert not absent.exists() and sha256(candidate) == source_hash
    if os.name != "nt":
        dangling = work / "dangling"
        dangling.symlink_to(work / "absent")
        run(instrument(tool, source, dangling, absent), 2, "output path already exists")
        assert dangling.is_symlink() and not (work / "absent").exists() and not absent.exists()

    final = work / "result.wasm"
    folder = work / "folder"
    folder.mkdir()
    run(instrument(tool, source, final, str(folder) + "/../result.wasm"), 2, "must differ")
    if os.name == "nt":
        run(instrument(tool, source, final, work / "RESULT.wasm"), 2, "must differ")
        long_name = work / "this_is_long_destination.wasm"
        short_name = work / "THIS_I~1.WAS"
        for output, manifest in ((long_name, short_name), (short_name, long_name)):
            run(instrument(tool, source, output, manifest), 2, "ambiguous Windows short name")
            assert not long_name.exists() and not short_name.exists()
    else:
        symlink = work / "directory-alias"
        symlink.symlink_to(folder, target_is_directory=True)
        run(instrument(tool, source, folder / "clash", symlink / "clash"), 2, "must differ")
        assert not (folder / "clash").exists()
    assert not final.exists()
    run(instrument(tool, source, final, work / "absent-parent" / "manifest.json"), 2,
        "cannot resolve report directory")
    assert not final.exists()

    report = folder / "result.json"
    commands = [instrument(tool, source, final, report, fuel) for fuel in ("100000", "99999")]
    with ThreadPoolExecutor(max_workers=2) as executor:
        results = list(executor.map(run, commands))
    assert sorted(result.returncode for result in results) == [0, 2], results
    winner = next(i for i, result in enumerate(results) if result.returncode == 0)
    manifest = report.read_bytes()
    expected = json.loads(manifest)
    assert expected["instrumentation"]["config"]["fuel"] == ("100000", "99999")[winner]
    assert expected["output_sha256"] == sha256(final) and expected["input_sha256"] == source_hash
    verify(tool, final, report)
    verify(tool, absent, report, 2, "failed to read Wasm")
    verify(tool, final, absent, 2, "failed to read manifest")
    verify(tool, source, report, 2, "does not match")

    partial = work / "partial.json"
    partial.write_bytes(manifest[:len(manifest) // 2])
    verify(tool, final, partial, 2, "invalid manifest JSON")
    partial.write_text(json.dumps({"schema": expected["schema"], "output_sha256": sha256(final)}),
                       encoding="utf-8")
    verify(tool, final, partial, 2, "incomplete manifest")
    incomplete = json.loads(manifest)
    del incomplete["instrumentation"]["codegen"]
    partial.write_text(json.dumps(incomplete), encoding="utf-8")
    verify(tool, final, partial, 2, "incomplete manifest")
    incomplete = json.loads(manifest)
    incomplete["deterministic"] = False
    partial.write_text(json.dumps(incomplete), encoding="utf-8")
    verify(tool, final, partial, 2, "incomplete manifest")
    if os.name != "nt":
        pipe = work / "pipe"
        os.mkfifo(pipe)
        verify(tool, final, pipe, 2, "expected a regular file")
        verify(tool, pipe, report, 2, "expected a regular file")
    named_verify = work / "verify"
    shutil.copyfile(source, named_verify)
    named_output, named_report = work / "named.wasm", work / "named.json"
    run(instrument(tool, "verify", named_output, named_report), 0, cwd=work)
    verify(tool, named_output, named_report)
    assert sha256(source) == source_hash and sha256(existing) == existing_hash
    assert report.read_bytes() == manifest
    no_temps(work, folder)
    print(f"complete output_sha256={sha256(final)} manifest_sha256={sha256(report)}", flush=True)


def os_failures(tool_binary):
    # Run this branch in a private Linux mount namespace as root.
    with tempfile.TemporaryDirectory(prefix="fuelguard-s15-os-") as directory:
        work = Path(directory)
        work.chmod(0o755)
        moonrun = work / "moonrun"
        shutil.copy(shutil.which("moonrun"), moonrun)
        tool = work / "instrument.wasm"
        shutil.copyfile(tool_binary, tool)
        source = work / "source.wasm"
        shutil.copyfile(SOURCE, source)
        source_hash = sha256(source)
        writable = work / "writable"
        writable.mkdir()
        writable.chmod(0o777)
        denied = work / "denied"
        denied.mkdir()
        denied.chmod(0o555)
        final = writable / "result.wasm"
        report = denied / "result.json"
        nobody = ["setpriv", "--reuid", "65534", "--regid", "65534", "--clear-groups", moonrun, "--", tool]
        run(instrument(nobody, source, final, report), 2, "permission denied", cwd=work)
        assert not final.exists() and not report.exists()
        no_temps(writable, denied)

        alias = work / "bind-alias"
        alias.mkdir()
        subprocess.run(["mount", "--bind", writable, alias], check=True)
        try:
            run(instrument([moonrun, "--", tool], source, writable / "alias.wasm", alias / "alias.wasm"),
                2, "must differ")
            assert not (writable / "alias.wasm").exists()
            no_temps(writable)
        finally:
            subprocess.run(["umount", alias], check=True)

        small = work / "small"
        small.mkdir()
        subprocess.run(["mount", "-t", "tmpfs", "-o", "size=4096", "tmpfs", small], check=True)
        try:
            disk_tool = [moonrun, "--", tool]
            cases = ((small / "out.wasm", writable / "out.json"),
                     (writable / "out.wasm", small / "out.json"))
            for index, (output, manifest) in enumerate(cases):
                filler = small / ".capacity-reservation"
                if index == 1:
                    filler.write_bytes(b"x")
                run(instrument(disk_tool, source, output, manifest), 2, "no space left on device")
                if index == 1:
                    filler.unlink()
                assert not output.exists() and not manifest.exists()
                no_temps(writable, small)
            assert sha256(source) == source_hash
        finally:
            subprocess.run(["umount", small], check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--os-failures", action="store_true",
                        help="run real EACCES and ENOSPC cases inside a private Linux mount namespace")
    options = parser.parse_args()
    base = ROOT / "_build/s15"
    base.mkdir(parents=True, exist_ok=True)
    target = base / f"tool-build-{os.name}"
    run(["moon", "build", "--target", "wasm", "cmd/instrument", "--target-dir", target], 0)
    binary = target / "wasm/debug/build/cmd/instrument/instrument.wasm"
    evidence = os.environ.get("FUELGUARD_CHECK_EVIDENCE")
    if evidence:
        work = Path(evidence).resolve()
        work.mkdir(parents=True)
        copy = work / "instrument-tool.wasm"
        shutil.copyfile(binary, copy)
        binary = copy
    else:
        work = Path(tempfile.mkdtemp(dir=base, prefix="delivery-"))
    publication_cases(["moonrun", "--", binary], work)
    if options.os_failures:
        assert os.geteuid() == 0, "--os-failures requires root in a private mount namespace"
        assert os.readlink("/proc/self/ns/mnt") != os.readlink("/proc/1/ns/mnt"), "use unshare --mount"
        os_failures(binary)
    print("S15 delivery checks passed", flush=True)


if __name__ == "__main__":
    main()

"""Stage and verify the public Mooncakes source package."""

import argparse
import hashlib
from pathlib import Path
import shutil
import subprocess
import sys
from tempfile import TemporaryDirectory
from zipfile import ZipFile


ROOT = Path(__file__).resolve().parents[1]
TREES = {"bench", "cmd", "docs", "fixtures", "integration", "runner", "scripts"}
ROOT_FILES = {"LICENSE", "NOTICE", "README.md",
              "THIRD_PARTY.md", "moon.mod", "moon.pkg", "pkg.generated.mbti"}
REQUIRED = {"LICENSE", "NOTICE", "THIRD_PARTY.md", "moon.mod", "moon.pkg",
            "cmd/instrument/moon.pkg", "cmd/run/moon.mod", "scripts/fuelguard-instrument",
            "scripts/prepare-dependencies.py",
            "docs/install.md", "docs/cli.md", "docs/support.md", "docs/performance.md",
            "docs/reproduce.md", "docs/implementation/fuel-v1.md",
            "docs/implementation/fuel-v2.md", "docs/implementation/fuel-v2.sha256",
            "docs/implementation/stack-v2.md", "docs/implementation/manifest-v2.md"}
PUBLIC_DOCS = {
    "docs/install.md", "docs/cli.md", "docs/support.md", "docs/performance.md",
    "docs/reproduce.md", "docs/implementation/fuel-v1.md",
    "docs/implementation/fuel-v2.md", "docs/implementation/fuel-v2.sha256",
    "docs/implementation/stack-v2.md", "docs/implementation/manifest-v2.md",
}
EXCLUDED = {"_build", "target", "__pycache__", ".git", ".mooncakes", ".moonagent"}


def digest(path):
    with path.open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def stage_sources(stage):
    names = subprocess.check_output(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"], cwd=ROOT)
    for name in sorted(set(names.decode("utf-8").split("\0")) - {""}):
        path = Path(name)
        if EXCLUDED.intersection(path.parts) or path.name in {"64", "trace.json"}:
            continue
        if path.parts[0] == "docs" and name not in PUBLIC_DOCS:
            continue
        if path.parts[0] == "bench" and name == "bench/README.md":
            continue
        if path.parts[0] == "integration" and path.name == "README.md":
            continue
        if name == "scripts/patches/starshine-0.3.0-moonbit-20261126.patch":
            continue
        if path.parts[0] not in TREES and name not in ROOT_FILES and not (
                len(path.parts) == 1 and path.suffix == ".mbt"):
            continue
        source = ROOT / path
        if source.is_symlink():
            raise ValueError(f"unexpected source symlink: {name}")
        if source.is_file():
            destination = stage / path
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, destination)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("out", type=Path, help="new release directory")
    args = parser.parse_args()
    out = args.out.resolve()
    if out.exists():
        parser.error("output directory already exists")
    with TemporaryDirectory(prefix="fuelguard-release-") as scratch:
        stage = Path(scratch)
        stage_sources(stage)
        subprocess.run([sys.executable, "-B", "scripts/prepare-dependencies.py"], cwd=stage, check=True)
        subprocess.run(["moon", "package", "--frozen"], cwd=stage, check=True)
        archives = list((stage / "_build/publish").glob("*.zip"))
        if len(archives) != 1:
            raise ValueError("expected one Mooncakes package")
        archive = archives[0]
        with ZipFile(archive) as package:
            entries = set(package.namelist())
            missing = REQUIRED - entries
            if missing or package.testzip() is not None:
                raise ValueError(f"invalid release archive, missing: {sorted(missing)}")
            for name in entries:
                path = Path(name)
                if EXCLUDED.intersection(path.parts) or path.name in {"64", "trace.json"}:
                    raise ValueError(f"unexpected release archive entry: {name}")
            internal_markers = (
                "docs/evidence/", "docs/prompts/", "docs/adr/", "docs/audit-",
                "docs/project-status", ".scratch/", "AGENTS.md", "CONTEXT.md",
                "项目申报书", "任务提示词",
            )
            if any(any(marker in name for marker in internal_markers) for name in entries):
                raise ValueError("release archive contains internal project material")
        out.mkdir(parents=True)
        shutil.copy2(archive, out / archive.name)
        files = sorted(path for path in out.rglob("*") if path.is_file())
        (out / "SHA256SUMS").write_text(
            "".join(f"{digest(path)}  {path.relative_to(out).as_posix()}\n" for path in files),
            encoding="utf-8")
    print(out / archive.name)


if __name__ == "__main__":
    main()

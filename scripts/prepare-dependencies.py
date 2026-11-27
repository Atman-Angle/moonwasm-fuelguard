"""Prepare the pinned starshine dependency for MoonBit 1.0 RC."""

import argparse
import hashlib
import os
from pathlib import Path
import subprocess
from tempfile import TemporaryFile


ROOT = Path(__file__).resolve().parents[1]
PATCH = ROOT / "scripts/patches/starshine-0.3.0-moonbit-20261126.patch"
PATCH_SHA256 = "cf32bea9f748deba743fd31cea07a15db493140f64eac54007a0dcb842f1f876"
UPSTREAM_SHA256 = "841177b98a13a126ff9cfaf6da6c100e2c6c3203f84ebd81c51062867c9de409"
WORKSPACES = {".": "wasm", "cmd/run": "native", "bench/native": "native",
              "integration/generated/worker": "native"}


def check_hash(path, expected):
    if hashlib.sha256(path.read_bytes()).hexdigest() != expected:
        raise ValueError(f"unexpected SHA-256: {path}")


def prepare(workspace):
    project = ROOT / workspace
    target = WORKSPACES[workspace]
    with TemporaryFile(mode="w+") as log:
        result = subprocess.run(["moon", "check", "--dry-run", "--no-mbti", "--target", target],
                                cwd=project, stdout=log)
        if result.returncode:
            log.seek(0)
            print(log.read(), end="")
            result.check_returncode()
    dependency = project / ".mooncakes/jtenner/starshine"
    home = Path(os.environ.get("MOON_HOME") or Path.home() / ".moon")
    check_hash(home / "registry/cache/jtenner/starshine/0.3.0.zip", UPSTREAM_SHA256)
    environment = {**os.environ, "GIT_CEILING_DIRECTORIES": str(dependency.parent)}
    apply = ["git", "apply"]
    previous = subprocess.run([*apply, "--check", "--reverse", PATCH], cwd=dependency,
                              env=environment, capture_output=True)
    if previous.returncode:
        subprocess.run([*apply, "--check", PATCH], cwd=dependency, env=environment, check=True)
        subprocess.run([*apply, PATCH], cwd=dependency, env=environment, check=True)
    subprocess.run([*apply, "--check", "--reverse", PATCH], cwd=dependency,
                   env=environment, check=True)
    print(f"Prepared {workspace} for {target}", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("workspace", nargs="*", metavar="WORKSPACE",
                        help="defaults to the root module; choices: " + ", ".join(WORKSPACES))
    args = parser.parse_args()
    check_hash(PATCH, PATCH_SHA256)
    for workspace in args.workspace or ["."]:
        if workspace not in WORKSPACES:
            parser.error(f"unknown workspace: {workspace}")
        prepare(workspace)


if __name__ == "__main__":
    main()

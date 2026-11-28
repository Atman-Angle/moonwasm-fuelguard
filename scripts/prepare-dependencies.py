"""Prepare the pinned starshine dependency for MoonBit 1.0 RC."""

import argparse
import hashlib
import os
from pathlib import Path
import subprocess
from tempfile import TemporaryFile


ROOT = Path(__file__).resolve().parents[1]
BASE_PATCHES = [
    (ROOT / "docs/evidence/starshine-0.3.0-moonbit-20261126.patch",
     "cf32bea9f748deba743fd31cea07a15db493140f64eac54007a0dcb842f1f876"),
]
ARRAY_PATCH = (
    ROOT / "docs/evidence/starshine-0.3.0-moonbit-20261127.patch",
    "cd329ca71914b023ea354283da1cf1dee99e4a2c4d813864d9b06f9e60947836",
)
ARRAYVIEW_PATCH = (
    ROOT / "docs/evidence/starshine-0.3.0-moonbit-20261128.patch",
    "a178c73711fdf03b30b7cc10642b6435341f0bd370005423e416d9c3affef840",
)
UPSTREAM_SHA256 = "841177b98a13a126ff9cfaf6da6c100e2c6c3203f84ebd81c51062867c9de409"
WORKSPACES = {".": "wasm", "cmd/run": "native", "bench/native": "native",
              "integration/generated/worker": "native"}


def check_hash(path, expected):
    if hashlib.sha256(path.read_bytes()).hexdigest() != expected:
        raise ValueError(f"unexpected SHA-256: {path}")


def patch_state(patch, dependency, environment):
    apply = ["git", "apply"]
    reverse = subprocess.run(
        [*apply, "--check", "--reverse", patch],
        cwd=dependency,
        env=environment,
        capture_output=True,
        text=True,
    )
    if reverse.returncode == 0:
        return "applied"
    forward = subprocess.run(
        [*apply, "--check", patch],
        cwd=dependency,
        env=environment,
        capture_output=True,
        text=True,
    )
    if forward.returncode == 0:
        return "pending"
    return "conflict"


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
    patches = BASE_PATCHES + ([ARRAYVIEW_PATCH] if workspace == "cmd/run" else [ARRAY_PATCH])
    states = [(patch, patch_state(patch, dependency, environment)) for patch, _ in patches]
    conflicts = [patch for patch, state in states if state == "conflict"]
    if conflicts:
        summary = ", ".join(
            f"{patch.name}={state}" for patch, state in states
        )
        raise RuntimeError(
            f"starshine patch state is not recoverable in {dependency}: {summary}; "
            "restore the dependency from the pinned archive before retrying"
        )
    for patch, state in states:
        if state == "pending":
            subprocess.run(["git", "apply", patch], cwd=dependency,
                           env=environment, check=True)
        applied = patch_state(patch, dependency, environment)
        if applied != "applied":
            raise RuntimeError(f"failed to apply and verify {patch.name}: state={applied}")
    print(f"Prepared {workspace} for {target}", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("workspace", nargs="*", metavar="WORKSPACE",
                        help="defaults to the root module; choices: " + ", ".join(WORKSPACES))
    args = parser.parse_args()
    for patch, digest in BASE_PATCHES + [ARRAY_PATCH, ARRAYVIEW_PATCH]:
        check_hash(patch, digest)
    for workspace in args.workspace or ["."]:
        if workspace not in WORKSPACES:
            parser.error(f"unknown workspace: {workspace}")
        prepare(workspace)


if __name__ == "__main__":
    main()

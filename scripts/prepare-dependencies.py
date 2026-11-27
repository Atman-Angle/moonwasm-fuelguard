"""Resolve and validate the published FuelGuard codec dependency."""

import argparse
from pathlib import Path
import subprocess
from tempfile import TemporaryFile


ROOT = Path(__file__).resolve().parents[1]
WORKSPACES = {".": "wasm", "cmd/run": "native", "bench/native": "native",
              "integration/generated/worker": "native"}


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
    print(f"Resolved codec dependency for {workspace} ({target})", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("workspace", nargs="*", metavar="WORKSPACE",
                        help="defaults to the root module; choices: " + ", ".join(WORKSPACES))
    args = parser.parse_args()
    for workspace in args.workspace or ["."]:
        if workspace not in WORKSPACES:
            parser.error(f"unknown workspace: {workspace}")
        prepare(workspace)


if __name__ == "__main__":
    main()

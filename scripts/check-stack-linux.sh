#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
export LC_ALL=C PYTHONDONTWRITEBYTECODE=1
ulimit -S -s 8192
exec python3 integration/stack_probe/check.py

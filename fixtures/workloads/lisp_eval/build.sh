#!/usr/bin/env bash
# Rebuilds fixtures/workloads/lisp_eval/lisp_eval.wasm from pinned sources.
set -euo pipefail

FIXTURE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

cd "$FIXTURE_DIR"
moon build --target wasm --release

cp "$FIXTURE_DIR/_build/wasm/release/build/lisp_eval/lisp_eval.wasm" "$FIXTURE_DIR/lisp_eval.wasm"
echo "built $FIXTURE_DIR/lisp_eval.wasm"
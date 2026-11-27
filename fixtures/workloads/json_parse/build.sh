#!/usr/bin/env bash
# Rebuilds fixtures/workloads/json_parse/json_parse.wasm from pinned sources.
set -euo pipefail

FIXTURE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

cd "$FIXTURE_DIR"
moon build --target wasm --release

cp "$FIXTURE_DIR/_build/wasm/release/build/json_parse/json_parse.wasm" "$FIXTURE_DIR/json_parse.wasm"
echo "built $FIXTURE_DIR/json_parse.wasm"
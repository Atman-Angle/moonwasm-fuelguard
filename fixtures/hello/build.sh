#!/usr/bin/env bash
# Rebuilds fixtures/hello/hello.wasm from source.
set -euo pipefail

FIXTURE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

cd "$FIXTURE_DIR"
moon build --target wasm --release

cp "$FIXTURE_DIR/_build/wasm/release/build/hello/hello.wasm" "$FIXTURE_DIR/hello.wasm"
echo "built $FIXTURE_DIR/hello.wasm"

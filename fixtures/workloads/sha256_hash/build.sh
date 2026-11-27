#!/usr/bin/env bash
# Rebuilds fixtures/workloads/sha256_hash/sha256_hash.wasm from pinned sources.
set -euo pipefail

FIXTURE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

cd "$FIXTURE_DIR"
moon build --target wasm --release

cp "$FIXTURE_DIR/_build/wasm/release/build/sha256_hash/sha256_hash.wasm" "$FIXTURE_DIR/sha256_hash.wasm"
echo "built $FIXTURE_DIR/sha256_hash.wasm"
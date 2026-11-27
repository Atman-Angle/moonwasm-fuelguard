#!/usr/bin/env bash
# End-to-end check: instrument the frozen, supported MoonBit fixture twice.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "$ROOT/_build"
OUT_DIR="$(mktemp -d "$ROOT/_build/e2e.XXXXXX")"
DEMO="$ROOT/fixtures/demo"
INPUT="$OUT_DIR/demo-build/wasm/release/build/demo/demo.wasm"
FIRST="$OUT_DIR/demo.fuel.wasm"
SECOND="$OUT_DIR/demo.fuel.second.wasm"
FUEL=100000

(cd "$DEMO" && moon build --target wasm --release --target-dir "$OUT_DIR/demo-build")

cd "$ROOT"
moon run cmd/instrument --target wasm -- "$INPUT" -o "$FIRST" --fuel "$FUEL" --max-memory-pages 64 --max-table-elements 64 --max-stack-units 100000 --max-call-depth 128

if [ ! -s "$FIRST" ]; then
  echo "e2e failure: instrument produced no output" >&2
  exit 1
fi

if cmp -s "$INPUT" "$FIRST"; then
  echo "e2e failure: instrumented output is identical to the input" >&2
  exit 1
fi

if ! grep -a -q "__moonwasm_trap_code" "$FIRST"; then
  echo "e2e failure: trap code export missing from the output" >&2
  exit 1
fi

moon run cmd/instrument --target wasm -- "$INPUT" -o "$SECOND" --fuel "$FUEL" --max-memory-pages 64 --max-table-elements 64 --max-stack-units 100000 --max-call-depth 128

if ! cmp -s "$FIRST" "$SECOND"; then
  echo "e2e failure: repeated instrumentation produced different bytes" >&2
  exit 1
fi

echo "e2e ok: $FIRST"

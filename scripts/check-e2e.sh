#!/usr/bin/env bash
# End-to-end check: build the real MoonBit fixture and instrument it twice.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="$ROOT/_build/e2e"
INPUT="$ROOT/fixtures/hello/hello.wasm"
FIRST="$OUT_DIR/hello.fuel.wasm"
SECOND="$OUT_DIR/hello.fuel.second.wasm"
FUEL=100000

bash "$ROOT/fixtures/hello/build.sh"

mkdir -p "$OUT_DIR"
rm -f "$FIRST" "$SECOND"

cd "$ROOT"
moon run cmd/instrument --target wasm -- "$INPUT" -o "$FIRST" --fuel "$FUEL"

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

moon run cmd/instrument --target wasm -- "$INPUT" -o "$SECOND" --fuel "$FUEL"

if ! cmp -s "$FIRST" "$SECOND"; then
  echo "e2e failure: repeated instrumentation produced different bytes" >&2
  exit 1
fi

echo "e2e ok: $FIRST"

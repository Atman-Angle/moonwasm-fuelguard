#!/usr/bin/env bash
# Exercises instrument CLI failure paths and checks that no output is written.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$ROOT/_build/cli-failures"
FIXTURE="$ROOT/fixtures/hello/hello.wasm"

rm -rf "$WORK"
mkdir -p "$WORK"

cd "$ROOT"

fail() {
  echo "failure-path check failed: $*" >&2
  exit 1
}

expect_exit_2() {
  local label="$1"
  shift
  set +e
  moon run cmd/instrument --target wasm -- "$@" >"$WORK/last.log" 2>&1
  local status=$?
  set -e
  [ "$status" -eq 2 ] || fail "$label: expected exit 2, got $status"
  grep -q "instrument:" "$WORK/last.log" || fail "$label: no diagnostic printed"
}

expect_absent() {
  local label="$1"
  local path="$2"
  [ ! -e "$path" ] || fail "$label: output file was created"
}

# Missing input file.
OUT="$WORK/missing-input.wasm"
expect_exit_2 "missing input" "$WORK/does-not-exist.wasm" -o "$OUT" --fuel 100 --max-stack-units 100000 --max-call-depth 128
grep -q "failed to read input" "$WORK/last.log" || fail "missing input: unexpected diagnostic"
expect_absent "missing input" "$OUT"

# Missing required --fuel budget.
OUT="$WORK/missing-fuel.wasm"
expect_exit_2 "missing fuel" "$FIXTURE" -o "$OUT"
grep -q "missing required --fuel" "$WORK/last.log" || fail "missing fuel: unexpected diagnostic"
expect_absent "missing fuel" "$OUT"

# Invalid guard limit.
OUT="$WORK/invalid-limit.wasm"
expect_exit_2 "invalid limit" "$FIXTURE" -o "$OUT" --fuel 100 --max-memory-pages 65537
grep -q "invalid guard limit" "$WORK/last.log" || fail "invalid limit: unexpected diagnostic"
expect_absent "invalid limit" "$OUT"

# Undecodable input.
printf 'not a wasm module' >"$WORK/junk.wasm"
OUT="$WORK/undecodable.wasm"
expect_exit_2 "undecodable input" "$WORK/junk.wasm" -o "$OUT" --fuel 100 --max-stack-units 100000 --max-call-depth 128
grep -q "failed to decode wasm" "$WORK/last.log" || fail "undecodable input: unexpected diagnostic"
expect_absent "undecodable input" "$OUT"

# Initial memory above the configured growth limit is rejected before output.
OUT="$WORK/guard-rejected.wasm"
expect_exit_2 "guard config" "$FIXTURE" -o "$OUT" --fuel 100000 --max-memory-pages 0 --max-table-elements 64 --max-stack-units 100000 --max-call-depth 128 --allow-import wasi_snapshot_preview1.fd_write
grep -q "initial memory pages 1 exceeds configured limit 0" "$WORK/last.log" || fail "guard config: unexpected diagnostic"
expect_absent "guard config" "$OUT"

# A failing run must not overwrite an existing output file.
SENTINEL="$WORK/existing.wasm"
printf 'SENTINEL' >"$SENTINEL"
expect_exit_2 "guard config overwrite" "$FIXTURE" -o "$SENTINEL" --fuel 100000 --max-memory-pages 0 --max-table-elements 64 --max-stack-units 100000 --max-call-depth 128 --allow-import wasi_snapshot_preview1.fd_write
[ "$(cat "$SENTINEL")" = "SENTINEL" ] || fail "existing output was overwritten by a failing run"

# Successful instrumentation must refuse existing output and aliases of the input.
VALID=(--fuel 100000 --max-memory-pages 64 --max-table-elements 64 --max-stack-units 100000 --max-call-depth 128 --allow-import wasi_snapshot_preview1.fd_write)
expect_exit_2 "existing output" "$FIXTURE" -o "$SENTINEL" "${VALID[@]}"
grep -q "output path already exists" "$WORK/last.log" || fail "existing output: unexpected diagnostic"
[ "$(cat "$SENTINEL")" = "SENTINEL" ] || fail "existing output was changed"

INPUT_COPY="$WORK/input-copy.wasm"
cp "$FIXTURE" "$INPUT_COPY"
ln "$INPUT_COPY" "$WORK/hard-link.wasm"
ln -s "input-copy.wasm" "$WORK/symbolic-link.wasm"
for alias in "$INPUT_COPY" "$WORK/./input-copy.wasm" "$WORK/hard-link.wasm" "$WORK/symbolic-link.wasm"; do
  expect_exit_2 "input alias $alias" "$INPUT_COPY" -o "$alias" "${VALID[@]}"
  grep -q "output path already exists" "$WORK/last.log" || fail "input alias: unexpected diagnostic"
  cmp -s "$FIXTURE" "$INPUT_COPY" || fail "original input was changed"
  cmp -s "$FIXTURE" "$alias" || fail "output alias was changed"
done

# Repeated successful runs produce the same bytes and summary details.
OUT="$WORK/stable.wasm"
SECOND="$WORK/stable-second.wasm"
moon run cmd/instrument --target wasm -- "$FIXTURE" -o "$OUT" "${VALID[@]}" >"$WORK/summary-1.txt"
moon run cmd/instrument --target wasm -- "$FIXTURE" -o "$SECOND" "${VALID[@]}" >"$WORK/summary-2.txt"
[ -s "$OUT" ] || fail "successful run did not write output"
cmp -s "$OUT" "$SECOND" || fail "output bytes changed between equivalent runs"
diff -q <(tail -n +3 "$WORK/summary-1.txt") <(tail -n +3 "$WORK/summary-2.txt") || fail "success summary details changed"
expect_exit_2 "replace instrumented artifact" "$FIXTURE" -o "$OUT" --fuel 200000 "${VALID[@]:2}"
grep -q "output path already exists" "$WORK/last.log" || fail "replace artifact: unexpected diagnostic"
cmp -s "$OUT" "$SECOND" || fail "existing instrumented artifact was changed"
grep -q "passes: FuelPass, GrowthPass, StackPass" "$WORK/summary-1.txt" || fail "summary is missing the pass order"
grep -q "fuel=" "$WORK/summary-1.txt" || fail "summary is missing the fuel budget"
grep -q "functions=" "$WORK/summary-1.txt" || fail "summary is missing the function count"
grep -q "loops=" "$WORK/summary-1.txt" || fail "summary is missing the loop count"

echo "failure paths ok: $WORK"

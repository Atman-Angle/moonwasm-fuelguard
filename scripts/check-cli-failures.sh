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
expect_exit_2 "missing input" "$WORK/does-not-exist.wasm" -o "$OUT" --fuel 100
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
expect_exit_2 "undecodable input" "$WORK/junk.wasm" -o "$OUT" --fuel 100
grep -q "failed to decode wasm" "$WORK/last.log" || fail "undecodable input: unexpected diagnostic"
expect_absent "undecodable input" "$OUT"

# Configured guard options are rejected before writing any output.
OUT="$WORK/guard-rejected.wasm"
expect_exit_2 "guard config" "$FIXTURE" -o "$OUT" --fuel 100000 --max-memory-pages 64
grep -q "GuardPass is not implemented" "$WORK/last.log" || fail "guard config: unexpected diagnostic"
expect_absent "guard config" "$OUT"

# A failing run must not overwrite an existing output file.
SENTINEL="$WORK/existing.wasm"
printf 'SENTINEL' >"$SENTINEL"
expect_exit_2 "guard config overwrite" "$FIXTURE" -o "$SENTINEL" --fuel 100000 --max-memory-pages 64
[ "$(cat "$SENTINEL")" = "SENTINEL" ] || fail "existing output was overwritten by a failing run"

# The success summary is stable for identical invocations.
OUT="$WORK/stable.wasm"
moon run cmd/instrument --target wasm -- "$FIXTURE" -o "$OUT" --fuel 100000 >"$WORK/summary-1.txt"
moon run cmd/instrument --target wasm -- "$FIXTURE" -o "$OUT" --fuel 100000 >"$WORK/summary-2.txt"
cmp -s "$WORK/summary-1.txt" "$WORK/summary-2.txt" || fail "success summary changed between identical runs"
[ -s "$OUT" ] || fail "successful run did not write output"
grep -q "passes: FuelPass, GuardPass" "$WORK/summary-1.txt" || fail "summary is missing the pass order"
grep -q "fuel=" "$WORK/summary-1.txt" || fail "summary is missing the fuel budget"
grep -q "functions=" "$WORK/summary-1.txt" || fail "summary is missing the function count"
grep -q "loops=" "$WORK/summary-1.txt" || fail "summary is missing the loop count"

echo "failure paths ok: $WORK"

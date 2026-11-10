#!/bin/bash
# Conformance test runner. Usage: tests/run.sh [path/to/alc] [filter]
# tests/run/NAME.al   must compile and print NAME.out (exit code from NAME.code, default 0;
#                     every line of NAME.err must appear in stderr)
# tests/fail/NAME.al  must fail to compile; every line of NAME.err must appear in the diagnostics
cd "$(dirname "$0")/.." || exit 2
ALC=${1:-./target/release/alc}
FILTER=${2:-}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
for src in tests/run/*.al; do
  name=$(basename "$src" .al)
  [[ -n "$FILTER" && "$name" != *"$FILTER"* ]] && continue
  exp_out="tests/run/$name.out"
  exp_code=0
  [[ -f "tests/run/$name.code" ]] && exp_code=$(cat "tests/run/$name.code")
  modes=("" "-O0" "--unchecked")
  [[ -f "tests/run/$name.checked" ]] && modes=("" "-O0")
  for mode in "${modes[@]}"; do
    label="$name [${mode:-default}]"
    if ! $ALC build "$src" $mode -o "$TMP/bin" 2>"$TMP/cerr"; then
      echo "FAIL $label: compile error"; head -5 "$TMP/cerr"; fail=$((fail+1)); continue
    fi
    if [[ -f "tests/run/$name.in" ]]; then
      timeout 20 "$TMP/bin" <"tests/run/$name.in" >"$TMP/out" 2>"$TMP/err"; code=$?
    else
      timeout 20 "$TMP/bin" a1 b2 >"$TMP/out" 2>"$TMP/err" </dev/null; code=$?
    fi
    ok=1
    if ! cmp -s "$TMP/out" "$exp_out"; then
      echo "FAIL $label: stdout differs"; diff "$exp_out" "$TMP/out" | head -10; ok=0
    fi
    if [[ "$code" != "$exp_code" ]]; then
      echo "FAIL $label: exit code $code, expected $exp_code"; head -3 "$TMP/err"; ok=0
    fi
    if [[ -f "tests/run/$name.err" ]]; then
      while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        if ! grep -qF -- "$line" "$TMP/err"; then echo "FAIL $label: stderr lacks: $line"; ok=0; fi
      done <"tests/run/$name.err"
    fi
    if [[ $ok == 1 ]]; then pass=$((pass+1)); else fail=$((fail+1)); fi
  done
done
for src in tests/fail/*.al; do
  [[ -e "$src" ]] || continue
  name=$(basename "$src" .al)
  [[ -n "$FILTER" && "$name" != *"$FILTER"* ]] && continue
  if $ALC check "$src" 2>"$TMP/cerr" >/dev/null; then
    echo "FAIL $name: expected a compile error"; fail=$((fail+1)); continue
  fi
  ok=1
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    if ! grep -qF -- "$line" "$TMP/cerr"; then echo "FAIL $name: diagnostics lack: $line"; sed 's/^/    /' "$TMP/cerr" | head -5; ok=0; fi
  done <"tests/fail/$name.err"
  if [[ $ok == 1 ]]; then pass=$((pass+1)); else fail=$((fail+1)); fi
done
echo "conformance: $pass passed, $fail failed"
[[ $fail == 0 ]]

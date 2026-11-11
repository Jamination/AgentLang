#!/bin/bash
# Conformance test runner. Usage: tests/run.sh [path/to/alc] [filter]
# tests/run/NAME.al   must compile and print NAME.out (exit code from NAME.code, default 0;
#                     every line of NAME.err must appear in stderr)
# tests/std/NAME.al   the same, for the standard library (static, libc-free programs)
# tests/sys/NAME.al   the same, for programs that need something from this machine (a GPU
#                     driver, a sound device, a display, a shared library). NAME.need holds a
#                     shell command that tells whether the prerequisite is there; if it fails
#                     the test is reported as SKIP together with the text of NAME.why.
# tests/fail/NAME.al  must fail to compile; every line of NAME.err must appear in the diagnostics
# tests/check/NAME.al must pass `alc check` (bindings for platforms this machine cannot run)
# tests/unit/NAME.al  is run with `alc test`; stdout must equal NAME.out (exit code from NAME.code)
# Programs run with the repository root as working directory.
cd "$(dirname "$0")/.." || exit 2
ALC=${1:-./build/alc}
FILTER=${2:-}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0; skip=0
for dir in tests/run tests/std tests/sys; do
for src in $dir/*.al; do
  [[ -e "$src" ]] || continue
  name=$(basename "$src" .al)
  [[ -n "$FILTER" && "$name" != *"$FILTER"* ]] && continue
  if [[ -f "$dir/$name.need" ]] && ! bash "$dir/$name.need" >/dev/null 2>&1; then
    why="prerequisite missing"
    [[ -f "$dir/$name.why" ]] && why=$(cat "$dir/$name.why")
    echo "SKIP $name: $why"; skip=$((skip+1)); continue
  fi
  exp_out="$dir/$name.out"
  exp_code=0
  [[ -f "$dir/$name.code" ]] && exp_code=$(cat "$dir/$name.code")
  modes=("" "-O0" "--unchecked")
  [[ -f "$dir/$name.checked" ]] && modes=("" "-O0")
  for mode in "${modes[@]}"; do
    label="$name [${mode:-default}]"
    if ! $ALC build "$src" $mode -o "$TMP/bin" 2>"$TMP/cerr"; then
      echo "FAIL $label: compile error"; head -5 "$TMP/cerr"; fail=$((fail+1)); continue
    fi
    if [[ -f "$dir/$name.in" ]]; then
      timeout 60 "$TMP/bin" <"$dir/$name.in" >"$TMP/out" 2>"$TMP/err"; code=$?
    else
      timeout 60 "$TMP/bin" a1 b2 >"$TMP/out" 2>"$TMP/err" </dev/null; code=$?
    fi
    ok=1
    if ! cmp -s "$TMP/out" "$exp_out"; then
      echo "FAIL $label: stdout differs"; diff "$exp_out" "$TMP/out" | head -10; ok=0
    fi
    if [[ "$code" != "$exp_code" ]]; then
      echo "FAIL $label: exit code $code, expected $exp_code"; head -3 "$TMP/err"; ok=0
    fi
    if [[ -f "$dir/$name.err" ]]; then
      while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        if ! grep -qF -- "$line" "$TMP/err"; then echo "FAIL $label: stderr lacks: $line"; ok=0; fi
      done <"$dir/$name.err"
    fi
    if [[ $ok == 1 ]]; then pass=$((pass+1)); else fail=$((fail+1)); fi
  done
done
done
for src in tests/check/*.al; do
  [[ -e "$src" ]] || continue
  name=$(basename "$src" .al)
  [[ -n "$FILTER" && "$name" != *"$FILTER"* ]] && continue
  if $ALC check "$src" 2>"$TMP/cerr" >/dev/null; then
    pass=$((pass+1))
  else
    echo "FAIL check/$name: does not type-check"; head -5 "$TMP/cerr"; fail=$((fail+1))
  fi
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
for src in tests/unit/*.al; do
  [[ -e "$src" ]] || continue
  name=$(basename "$src" .al)
  [[ -n "$FILTER" && "$name" != *"$FILTER"* ]] && continue
  exp_code=0
  [[ -f "tests/unit/$name.code" ]] && exp_code=$(cat "tests/unit/$name.code")
  $ALC test "$src" -o "$TMP/bin" >"$TMP/out" 2>"$TMP/err"; code=$?
  ok=1
  if ! cmp -s "$TMP/out" "tests/unit/$name.out"; then echo "FAIL unit/$name: stdout differs"; diff "tests/unit/$name.out" "$TMP/out" | head -10; ok=0; fi
  if [[ "$code" != "$exp_code" ]]; then echo "FAIL unit/$name: exit code $code, expected $exp_code"; ok=0; fi
  if [[ $ok == 1 ]]; then pass=$((pass+1)); else fail=$((fail+1)); fi
done
if [[ $skip == 0 ]]; then
  echo "conformance: $pass passed, $fail failed"
else
  echo "conformance: $pass passed, $fail failed, $skip skipped"
fi
[[ $fail == 0 ]]

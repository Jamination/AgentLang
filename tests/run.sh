#!/bin/bash
# Conformance test runner.
# Usage: tests/run.sh [--target windows [--host-wine path/to/alc.exe]] [path/to/alc] [filter]
# tests/run/NAME.al   must compile and print NAME.out (exit code from NAME.code, default 0;
#                     every line of NAME.err must appear in stderr; arguments from NAME.args,
#                     default `a1 b2`)
# tests/std/NAME.al   the same, for the standard library (static, libc-free programs)
# tests/sys/NAME.al   the same, for programs that need something from this machine (a GPU
#                     driver, a sound device, a display, a shared library). NAME.need holds a
#                     shell command that tells whether the prerequisite is there; if it fails
#                     the test is reported as SKIP together with the text of NAME.why.
# tests/fail/NAME.al  must fail to compile; every line of NAME.err must appear in the diagnostics
# tests/check/NAME.al must pass `alc check` (bindings for platforms this machine cannot run)
# tests/unit/NAME.al  is run with `alc test`; stdout must equal NAME.out (exit code from NAME.code)
# tests/driver/NAME.sh is run with bash, the compiler as $1 and an empty scratch directory as
#                     $2; it tests the command line (files, paths, exit codes) and must exit 0
# Programs run with the repository root as working directory.
#
# --target windows builds the programs for Windows and runs them under Wine (in the prefix
# $WINEPREFIX, default tmp/win/prefix-tests, created if missing; no window can open: DISPLAY
# and WAYLAND_DISPLAY are removed; no sound can play: Wine's PulseAudio driver gets a server
# address where none listens and ALSA an empty configuration, so Wine finds no audio device).
# fail/ and check/ use `alc check --target windows`, unit/ runs `alc test` under Wine; driver/
# tests the Linux command line and is not run; the prerequisite checks (NAME.need) are Linux
# ones and are not run either. Tests that cannot run on Windows are listed with the reason in
# tests/windows.skip.
#
# --host-wine alc.exe (with --target windows) tests a compiler built for Windows: alc.exe runs
# under Wine and builds, checks and runs (`alc run` in the default mode, `alc test`) the
# programs there; [path/to/alc] is not given then, only the filter.
cd "$(dirname "$0")/.." || exit 2
usage() { echo "usage: tests/run.sh [--target linux|windows [--host-wine path/to/alc.exe]] [path/to/alc] [filter]"; exit 2; }
WIN=0
HOST_EXE=
while [[ ${1:-} == --target || ${1:-} == --host-wine ]]; do
  if [[ $1 == --target ]]; then
    case ${2:-} in
      windows) WIN=1 ;;
      linux) ;;
      *) usage ;;
    esac
  else
    [[ -n ${2:-} ]] || usage
    HOST_EXE=$(realpath "$2") || exit 2
  fi
  shift 2
done
[[ -n $HOST_EXE && $WIN == 0 ]] && usage
if [[ -n $HOST_EXE ]]; then
  ALC=
  FILTER=${1:-}
else
  ALC=${1:-./build/alc}
  FILTER=${2:-}
fi
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
TARGET=()
RUN=()
BIN=$TMP/bin
declare -A WSKIP
if [[ $WIN == 1 ]]; then
  TARGET=(--target windows)
  BIN=$TMP/bin.exe
  export WINEPREFIX=${WINEPREFIX:-$PWD/tmp/win/prefix-tests}
  export WINEDEBUG=-all WINEDLLOVERRIDES="mscoree=;mshtml="
  unset DISPLAY WAYLAND_DISPLAY
  : >"$TMP/alsa-none.conf"
  export PULSE_SERVER=unix:$TMP/no-sound-server ALSA_CONFIG_PATH=$TMP/alsa-none.conf
  command -v wine >/dev/null || { echo "tests/run.sh: --target windows needs wine"; exit 2; }
  [[ -d $WINEPREFIX ]] || { mkdir -p "$WINEPREFIX" && wineboot -i >/dev/null 2>&1; }
  # one wine server for the whole run (a starting server writes noise to standard error)
  wineserver -p
  wine cmd /c exit >/dev/null 2>&1
  trap 'rm -rf "$TMP"; wineserver -k' EXIT
  RUN=(wine)
  if [[ -n $HOST_EXE ]]; then
    # the compiler under Wine, as a command
    printf '#!/bin/bash\nexec wine %q "$@"\n' "$HOST_EXE" >"$TMP/alc"
    chmod +x "$TMP/alc"
    ALC=$TMP/alc
  fi
  while read -r key why; do
    [[ -z "$key" || "$key" == \#* ]] && continue
    WSKIP[$key]=$why
  done <tests/windows.skip
fi
pass=0; fail=0; skip=0
# true (and reported as SKIP) if dir/name cannot run on Windows
win_skip() {
  [[ $WIN == 1 && -n "${WSKIP[$1]+x}" ]] || return 1
  echo "SKIP $1: ${WSKIP[$1]}"; skip=$((skip+1))
}
for dir in tests/run tests/std tests/sys; do
for src in $dir/*.al; do
  [[ -e "$src" ]] || continue
  name=$(basename "$src" .al)
  [[ -n "$FILTER" && "$name" != *"$FILTER"* ]] && continue
  win_skip "${dir#tests/}/$name" && continue
  if [[ $WIN == 0 && -f "$dir/$name.need" ]] && ! bash "$dir/$name.need" >/dev/null 2>&1; then
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
    if ! $ALC build "${TARGET[@]}" "$src" $mode -o "$BIN" 2>"$TMP/cerr"; then
      echo "FAIL $label: compile error"; head -5 "$TMP/cerr"; fail=$((fail+1)); continue
    fi
    # (with --host-wine the default mode runs the program through `alc run`: arguments, input
    # and exit status pass through the compiler)
    cmd=("${RUN[@]}" "$BIN")
    [[ -n $HOST_EXE && -z $mode ]] && cmd=("$ALC" run "${TARGET[@]}" "$src" -o "$BIN" --)
    if [[ -f "$dir/$name.in" ]]; then
      timeout 60 "${cmd[@]}" <"$dir/$name.in" >"$TMP/out" 2>"$TMP/err"; code=$?
    else
      args=(a1 b2)
      [[ -f "$dir/$name.args" ]] && read -ra args <"$dir/$name.args"
      timeout 60 "${cmd[@]}" "${args[@]}" >"$TMP/out" 2>"$TMP/err" </dev/null; code=$?
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
  win_skip "check/$name" && continue
  if $ALC check "${TARGET[@]}" "$src" 2>"$TMP/cerr" >/dev/null; then
    pass=$((pass+1))
  else
    echo "FAIL check/$name: does not type-check"; head -5 "$TMP/cerr"; fail=$((fail+1))
  fi
done
for src in tests/fail/*.al; do
  [[ -e "$src" ]] || continue
  name=$(basename "$src" .al)
  [[ -n "$FILTER" && "$name" != *"$FILTER"* ]] && continue
  win_skip "fail/$name" && continue
  if $ALC check "${TARGET[@]}" "$src" 2>"$TMP/cerr" >/dev/null; then
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
  win_skip "unit/$name" && continue
  exp_code=0
  [[ -f "tests/unit/$name.code" ]] && exp_code=$(cat "tests/unit/$name.code")
  ALC_WINE=$WIN $ALC test "${TARGET[@]}" "$src" -o "$BIN" >"$TMP/out" 2>"$TMP/err"; code=$?
  ok=1
  if ! cmp -s "$TMP/out" "tests/unit/$name.out"; then echo "FAIL unit/$name: stdout differs"; diff "tests/unit/$name.out" "$TMP/out" | head -10; ok=0; fi
  if [[ "$code" != "$exp_code" ]]; then echo "FAIL unit/$name: exit code $code, expected $exp_code"; ok=0; fi
  if [[ $ok == 1 ]]; then pass=$((pass+1)); else fail=$((fail+1)); fi
done
for src in tests/driver/*.sh; do
  [[ $WIN == 1 ]] && break
  [[ -e "$src" ]] || continue
  name=$(basename "$src" .sh)
  [[ -n "$FILTER" && "$name" != *"$FILTER"* ]] && continue
  mkdir -p "$TMP/driver_$name"
  if bash "$src" "$(realpath "$ALC")" "$TMP/driver_$name" >"$TMP/out" 2>&1; then
    pass=$((pass+1))
  else
    echo "FAIL driver/$name"; head -10 "$TMP/out"; fail=$((fail+1))
  fi
done
if [[ $skip == 0 ]]; then
  echo "conformance: $pass passed, $fail failed"
else
  echo "conformance: $pass passed, $fail failed, $skip skipped"
fi
[[ $fail == 0 ]]

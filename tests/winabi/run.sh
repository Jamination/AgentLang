#!/bin/bash
# Windows calling convention tests: AL programs built with --target windows call into DLLs
# built by the MinGW C compiler and are called back from them, under Wine.
#   tests/winabi/run.sh [path/to/alc]
# abi.c / abi.al are generated into a scratch directory by gen.al (see there); frames.al with
# regs.c checks preserved registers, stack alignment, stack probes, deep recursion and stack
# walks. Each program is built in the three modes of tests/run.sh. Wine runs with no display
# (no window can open) in the prefix $WINEPREFIX (default: tmp/win/prefix-winabi, created on
# first use).
# gui.c starts gui.al built with --gui (the GUI subsystem) with no standard handles, with
# pipes, panicking, and from a console (the launcher runs in a terminal made by `script`, so
# that Wine gives it a working console; the child's lines must appear in that terminal).
cd "$(dirname "$0")/../.." || exit 2
ALC=${1:-./build/alc}
command -v x86_64-w64-mingw32-gcc >/dev/null || { echo "winabi: SKIP: x86_64-w64-mingw32-gcc is not installed"; exit 0; }
command -v wine >/dev/null || { echo "winabi: SKIP: wine is not installed"; exit 0; }
export WINEPREFIX=${WINEPREFIX:-$PWD/tmp/win/prefix-winabi}
wine_env=(env -u DISPLAY -u WAYLAND_DISPLAY WINEDEBUG=-all "WINEDLLOVERRIDES=mscoree=;mshtml=")
if [[ ! -d $WINEPREFIX ]]; then
  mkdir -p "$WINEPREFIX" && "${wine_env[@]}" wineboot -i >/dev/null 2>&1
fi
"${wine_env[@]}" wineserver -p 2>/dev/null
TMP=$(mktemp -d)
trap '"${wine_env[@]}" wineserver -k 2>/dev/null; rm -rf "$TMP"' EXIT
# the generator is a Linux program (built with the default run-time library)
env -u ALC_PRELUDE $ALC build tests/winabi/gen.al -o "$TMP/gen" || exit 1
"$TMP/gen" "$TMP" >/dev/null || exit 1
x86_64-w64-mingw32-gcc -O2 -shared -o "$TMP/abi.dll" "$TMP/abi.c" || exit 1
x86_64-w64-mingw32-gcc -O2 -shared -o "$TMP/regs.dll" tests/winabi/regs.c || exit 1
pass=0; fail=0
for prog in abi frames; do
  for mode in "" -O0 --unchecked; do
    label="$prog [${mode:-default}]"
    src=tests/winabi/$prog.al
    [[ $prog == abi ]] && src=$TMP/abi.al
    if ! $ALC build --target windows "$src" $mode -o "$TMP/$prog.exe" 2>"$TMP/cerr"; then
      echo "FAIL $label: compile error"; head -5 "$TMP/cerr"; fail=$((fail+1)); continue
    fi
    (cd "$TMP" && timeout 120 "${wine_env[@]}" wine "$prog.exe" >out 2>err); code=$?
    if [[ $code == 0 ]] && ! grep -q FAIL "$TMP/out"; then
      pass=$((pass+1))
    else
      echo "FAIL $label: exit code $code"; grep -v '^ok' "$TMP/out" | head -10; head -5 "$TMP/err"; fail=$((fail+1))
    fi
  done
done
# --gui: no handles, pipes, a panic, a console
if ! $ALC build --target windows --gui tests/winabi/gui.al -o "$TMP/gui.exe" 2>"$TMP/cerr" ||
   ! x86_64-w64-mingw32-gcc -O2 -o "$TMP/gui_test.exe" tests/winabi/gui.c; then
  echo "FAIL gui: build"; head -5 "$TMP/cerr"; fail=$((fail+1))
else
  launch="cd $(printf %q "$TMP") && timeout 120 wine gui_test.exe; echo \"status \$?\""
  if command -v script >/dev/null; then
    "${wine_env[@]}" script -qec "$launch" /dev/null </dev/null >"$TMP/gui.out" 2>&1
  else
    "${wine_env[@]}" bash -c "$launch" </dev/null >"$TMP/gui.out" 2>&1
  fi
  # the cases' results in gui_result.txt, the console case's output in the terminal's transcript
  # (without carriage returns and the escape sequences of Wine's console)
  tr -d '\r' <"$TMP/gui.out" | sed $'s/\e\\[[0-9;?]*[A-Za-z]//g' >"$TMP/gui.txt"
  res=$TMP/gui_result.txt
  if grep -q '^status 0$' "$TMP/gui.txt" && [[ $(grep -c '^ok ' "$res" 2>/dev/null) -ge 3 ]] &&
     ! grep -q '^FAIL' "$res" && { grep -q '^skip console' "$res" || grep -q 'out 999' "$TMP/gui.txt"; }; then
    pass=$((pass+1))
    grep -q '^skip console' "$res" && echo "gui: console case skipped (no working console under Wine)"
  else
    echo "FAIL gui"; cat "$res" 2>/dev/null | head -10; grep '^status' "$TMP/gui.txt"; fail=$((fail+1))
  fi
fi
echo "winabi: $pass passed, $fail failed"
[[ $fail == 0 ]]

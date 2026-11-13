#!/bin/bash
# Builds the compiler from its AL sources (src/main.al) with itself.
#
#   ./build.sh            seed compiler -> stage 1 -> stage 2 -> stage 3; stages 2 and 3 must be
#                         byte-identical (the compiler reproduces itself); installs build/alc,
#                         and build/alc.exe: the same compiler for Windows (built by stage 2
#                         while it builds stage 3)
#   ./build.sh --quick    seed compiler -> build/alc only (no self-check, no build/alc.exe)
#   ./build.sh --reseed   after a full build, also replaces the seed with the new compiler
#   ./build.sh --windows-check
#                         after a full build, runs build/alc.exe under Wine (in $WINEPREFIX,
#                         default tmp/win/prefix-tests; no display): it must build itself
#                         byte for byte (build/alc.exe) and the Linux compiler (build/alc)
#
# The seed is bootstrap/alc, a committed build of an earlier version of this same compiler
# (override with ALC_SEED=/path/to/alc). No other tool takes part in building the compiler.
set -u
cd "$(dirname "$0")" || exit 2
SEED=${ALC_SEED:-bootstrap/alc}
mode=
wincheck=0
for a in "$@"; do
  case $a in
    --quick|--reseed) mode=$a ;;
    --windows-check) wincheck=1 ;;
    *) echo "usage: ./build.sh [--quick | --reseed] [--windows-check]"; exit 2 ;;
  esac
done
[[ $mode == --quick && $wincheck == 1 ]] && { echo "build: --windows-check needs a full build"; exit 2; }
mkdir -p build
[[ -x $SEED ]] || { echo "build: no seed compiler at $SEED"; exit 1; }
# the sources name the standard library relative to src/, so build from the repository root
if ! "$SEED" build src/main.al -o build/alc-stage1; then echo "build: the seed compiler failed"; exit 1; fi
if [[ $mode == --quick ]]; then
  mv build/alc-stage1 build/alc
  echo "build: build/alc (quick, not self-checked)"
  exit 0
fi
if ! build/alc-stage1 build src/main.al -o build/alc-stage2; then echo "build: stage 1 failed to compile the compiler"; exit 1; fi
# the Windows compiler, at the same time as stage 3
build/alc-stage2 build --target windows src/main.al -o build/alc.exe.new &
win=$!
if ! build/alc-stage2 build src/main.al -o build/alc-stage3; then echo "build: stage 2 failed to compile the compiler"; wait $win; exit 1; fi
if ! wait $win; then echo "build: stage 2 failed to compile the compiler for Windows"; exit 1; fi
if ! cmp -s build/alc-stage2 build/alc-stage3; then
  echo "build: FAIL: stage 2 and stage 3 differ (the compiler does not reproduce itself)"
  exit 1
fi
cp build/alc-stage2 build/alc.new && mv build/alc.new build/alc
mv build/alc.exe.new build/alc.exe
rm -f build/alc-stage1 build/alc-stage2 build/alc-stage3
echo "build: build/alc ($(wc -c <build/alc) bytes), self-compiled, stages 2 and 3 identical; build/alc.exe ($(wc -c <build/alc.exe) bytes)"
if [[ $mode == --reseed ]]; then
  mkdir -p bootstrap
  cp build/alc bootstrap/alc
  echo "build: bootstrap/alc updated"
fi
if [[ $wincheck == 1 ]]; then
  command -v wine >/dev/null || { echo "build: --windows-check needs wine"; exit 1; }
  export WINEPREFIX=${WINEPREFIX:-$PWD/tmp/win/prefix-tests}
  export WINEDEBUG=-all WINEDLLOVERRIDES="mscoree=;mshtml="
  unset DISPLAY WAYLAND_DISPLAY
  [[ -d $WINEPREFIX ]] || { mkdir -p "$WINEPREFIX" && wineboot -i >/dev/null 2>&1; }
  wineserver -p
  wine cmd /c exit >/dev/null 2>&1
  ok=1
  if ! wine build/alc.exe build --target windows src/main.al -o build/alc-win2.exe || ! cmp -s build/alc.exe build/alc-win2.exe; then
    echo "build: FAIL: build/alc.exe under Wine does not reproduce itself"; ok=0
  fi
  if ! wine build/alc.exe build --target linux src/main.al -o build/alc-win-linux || ! cmp -s build/alc build/alc-win-linux; then
    echo "build: FAIL: build/alc.exe under Wine does not build build/alc"; ok=0
  fi
  wineserver -k
  rm -f build/alc-win2.exe build/alc-win-linux
  [[ $ok == 1 ]] || exit 1
  echo "build: build/alc.exe under Wine builds itself and build/alc byte for byte"
fi

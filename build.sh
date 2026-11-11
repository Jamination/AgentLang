#!/bin/bash
# Builds the compiler from its AL sources (src/main.al) with itself.
#
#   ./build.sh            seed compiler -> stage 1 -> stage 2 -> stage 3; stages 2 and 3 must be
#                         byte-identical (the compiler reproduces itself); installs build/alc
#   ./build.sh --quick    seed compiler -> build/alc only (no self-check)
#   ./build.sh --reseed   after a full build, also replaces the seed with the new compiler
#
# The seed is bootstrap/alc, a committed build of an earlier version of this same compiler
# (override with ALC_SEED=/path/to/alc). No other tool takes part in building the compiler.
set -u
cd "$(dirname "$0")" || exit 2
SEED=${ALC_SEED:-bootstrap/alc}
mode=${1:-}
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
if ! build/alc-stage2 build src/main.al -o build/alc-stage3; then echo "build: stage 2 failed to compile the compiler"; exit 1; fi
if ! cmp -s build/alc-stage2 build/alc-stage3; then
  echo "build: FAIL: stage 2 and stage 3 differ (the compiler does not reproduce itself)"
  exit 1
fi
cp build/alc-stage2 build/alc.new && mv build/alc.new build/alc
rm -f build/alc-stage1 build/alc-stage2 build/alc-stage3
echo "build: build/alc ($(wc -c <build/alc) bytes), self-compiled, stages 2 and 3 identical"
if [[ $mode == --reseed ]]; then
  mkdir -p bootstrap
  cp build/alc bootstrap/alc
  echo "build: bootstrap/alc updated"
fi

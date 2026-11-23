#!/bin/bash
# Wide benchmark harness: AL vs clang -O2 on Windows x86-64.
# usage: bench/wide/harness.sh [-r runs] <dir> [names...]
#   <dir> holds pairs NAME.al / NAME.c that print identical output.
# Columns: clang -O2 time, AL (checks on) time and ratio, AL --unchecked ratio, clang -O2 -fno-vectorize -fno-slp-vectorize ratio-of-AL.
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CLANG="/c/Program Files/Microsoft Visual Studio/2022/Community/VC/Tools/Llvm/x64/bin/clang.exe"
ALC="$ROOT/build/alc.exe"
RUNS=5
while getopts "r:" o; do case $o in r) RUNS=$OPTARG;; esac; done
shift $((OPTIND-1))
DIR="$1"; shift
cd "$DIR" || exit 2
mkdir -p bin
NAMES=${*:-$(ls *.al | sed 's/\.al$//')}
t_min() { local best=""; for _ in $(seq "$RUNS"); do local s e t; s=$(date +%s%N); "$@" >/dev/null 2>&1; e=$(date +%s%N); t=$((e-s)); if [[ -z "$best" || $t -lt $best ]]; then best=$t; fi; done; echo "$best"; }
printf "%-18s %8s %8s %7s %7s %7s  %s\n" name clang_s al_s al/cl unchk/cl al/novec status
for b in $NAMES; do
  "$CLANG" -O2 -o bin/$b.c.exe $b.c 2>bin/$b.c.err || { echo "$b: clang failed: $(head -3 bin/$b.c.err)"; continue; }
  "$CLANG" -O2 -fno-vectorize -fno-slp-vectorize -o bin/$b.nv.exe $b.c 2>/dev/null
  "$ALC" build $b.al -o bin/$b.al.exe >bin/$b.al.err 2>&1 || { echo "$b: alc failed: $(head -3 bin/$b.al.err)"; continue; }
  "$ALC" build $b.al --unchecked -o bin/$b.un.exe >/dev/null 2>&1
  bin/$b.c.exe >bin/$b.c.out 2>/dev/null
  timeout 120 bin/$b.al.exe >bin/$b.al.out 2>bin/$b.al.stderr; code=$?
  status=ok
  [[ $code != 0 ]] && status="EXIT=$code $(head -c 100 bin/$b.al.stderr)"
  cmp -s <(tr -d '\r' <bin/$b.c.out) <(tr -d '\r' <bin/$b.al.out) || status="$status OUTPUT-DIFFERS"
  tc=$(t_min bin/$b.c.exe); ta=$(t_min bin/$b.al.exe); tu=$(t_min bin/$b.un.exe); tn=$(t_min bin/$b.nv.exe)
  awk -v n="$b" -v c="$tc" -v a="$ta" -v u="$tu" -v v="$tn" -v s="$status" 'BEGIN { printf "%-18s %8.3f %8.3f %7.2f %7.2f %7.2f  %s\n", n, c/1e9, a/1e9, a/c, u/c, a/v, s }'
done

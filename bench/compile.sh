#!/usr/bin/env bash
# Compile speed of the compiler on its own sources, best of N runs (default 5):
#   -O0 throughput in lines per second (lines of src/**/*.al, run-time library included)
#   time of the default (optimised) self-compile
# usage: bench/compile.sh [compiler] [runs]
set -euo pipefail
cd "$(dirname "$0")/.."
ALC=${1:-./build/alc}
RUNS=${2:-5}
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

lines=$(cat src/*.al src/*/*.al | wc -l)

best() {
    local b=999999999 s e t
    for ((i = 0; i < RUNS; i++)); do
        s=$(date +%s%N)
        "$ALC" build "$@" src/main.al -o "$OUT/alc" >/dev/null
        e=$(date +%s%N)
        t=$(( (e - s) / 1000 ))
        (( t < b )) && b=$t
    done
    echo "$b"
}

o0=$(best -O0)
o2=$(best)
awk -v l="$lines" -v a="$o0" -v b="$o2" 'BEGIN {
    printf "lines            %d\n", l
    printf "-O0              %.3f s   %.0f lines/s\n", a / 1e6, l / (a / 1e6)
    printf "optimised        %.3f s   %.0f lines/s\n", b / 1e6, l / (b / 1e6)
}'

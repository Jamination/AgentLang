#!/usr/bin/env bash
# Compile speed of the compiler on its own sources, best of N runs (default 5):
#   -O0 throughput in lines per second (lines of src/**/*.al, run-time library included)
#   time of the default (optimised) self-compile
# The compiler compiles on all threads of the machine, so the header's core and thread counts
# belong to the numbers. How a run is judged (quiet check, noise band, history, exit status 3
# and 4): see bench/lib.sh.
# usage: bench/compile.sh [--force] [--no-save] [compiler] [runs]
set -uo pipefail
cd "$(dirname "$0")/.."
args=()
for a in "$@"; do
  case $a in
    --force) BENCH_FORCE=1 ;;
    --no-save) BENCH_SAVE=0 ;;
    *) args+=("$a") ;;
  esac
done
ALC=${args[0]:-./build/alc}
RUNS=${args[1]:-5}
. bench/lib.sh
OUT=$(mktemp -d)
trap 'rm -rf "$OUT" "$BENCH_ROWS"' EXIT

lines=$(cat src/*.al src/*/*.al | wc -l)

best() {
    local b=999999999 s e t
    for ((i = 0; i < RUNS; i++)); do
        s=$(date +%s%N)
        "$ALC" build "$@" src/main.al -o "$OUT/alc" >/dev/null || exit 1
        e=$(date +%s%N)
        t=$(( (e - s) / 1000 ))
        (( t < b )) && b=$t
    done
    echo "$b"
}

bench_header compile "$ALC"
bench_quiet_check before
echo
o0=$(best -O0)
o2=$(best)
awk -v l="$lines" -v a="$o0" -v b="$o2" 'BEGIN {
    printf "lines            %d\n", l
    printf "-O0              %.3f s   %.0f lines/s\n", a / 1e6, l / (a / 1e6)
    printf "optimised        %.3f s   %.0f lines/s\n", b / 1e6, l / (b / 1e6)
}'
echo
bench_row self "O0" "$(awk -v a="$o0" 'BEGIN { printf "%.4f", a / 1e6 }')" "$(awk -v a="$o0" 'BEGIN { printf "%.4f", a / 1e6 }')" "$lines"
bench_row self "O2" "$(awk -v a="$o2" 'BEGIN { printf "%.4f", a / 1e6 }')" "$(awk -v a="$o2" 'BEGIN { printf "%.4f", a / 1e6 }')" "$lines"
bench_finish

#!/bin/bash
# Development helper: build + check + time selected benchmarks (default: all).
# usage: bench/run.sh [-r runs] [-f "alc flags"] [names...]
cd "$(dirname "$0")/.." || exit 2
RUNS=3; FLAGS=""
while getopts "r:f:" o; do case $o in r) RUNS=$OPTARG;; f) FLAGS=$OPTARG;; esac; done
shift $((OPTIND-1))
NAMES=${*:-nbody spectralnorm fannkuch mandelbrot binarytrees sha256 matmul quicksort sieve hashmap}
ALC=./target/release/alc; BIN=bench/bin; mkdir -p $BIN
t_min() { local best=""; for _ in $(seq "$RUNS"); do local s e t; s=$(date +%s%N); "$@" >/dev/null 2>&1; e=$(date +%s%N); t=$((e-s)); if [[ -z "$best" || $t -lt $best ]]; then best=$t; fi; done; echo "$best"; }
logsum=0; n=0
for b in $NAMES; do
  [[ -x $BIN/$b.c.bin && $BIN/$b.c.bin -nt bench/$b.c ]] || clang -O2 -o $BIN/$b.c.bin bench/$b.c -lm || continue
  $ALC build bench/$b.al $FLAGS -o $BIN/$b.al.bin || { echo "$b: alc failed"; continue; }
  $BIN/$b.c.bin >$BIN/$b.c.out 2>/dev/null
  timeout 120 $BIN/$b.al.bin >$BIN/$b.al.out 2>$BIN/$b.al.stderr; code=$?
  status=ok
  [[ $code != 0 ]] && status="EXIT=$code $(head -c 100 $BIN/$b.al.stderr)"
  cmp -s $BIN/$b.c.out $BIN/$b.al.out || status="$status OUTPUT-DIFFERS"
  tc=$(t_min $BIN/$b.c.bin); ta=$(t_min $BIN/$b.al.bin)
  r=$(awk -v a="$ta" -v c="$tc" 'BEGIN { printf "%.3f", a / c }')
  printf "%-14s clang %7.3fs  al %7.3fs  ratio %6s  %s\n" "$b" "$(awk -v t="$tc" 'BEGIN { print t / 1e9 }')" "$(awk -v t="$ta" 'BEGIN { print t / 1e9 }')" "$r" "$status"
  logsum=$(awk -v s="$logsum" -v r="$r" 'BEGIN { print s + log(r) }'); n=$((n+1))
done
[[ $n -gt 0 ]] && awk -v s="$logsum" -v n="$n" 'BEGIN { printf "geomean %.3f over %d\n", exp(s / n), n }'

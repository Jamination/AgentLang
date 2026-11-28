#!/bin/bash
# Run every group of the wide benchmark set serially; prints per-group and overall geomeans.
# usage: bench/wide/run.sh [-r runs] [--force] [--no-save] [groups...]
#        (default groups: vec int str call mem fp)
# How a run is judged (machine, quiet check, noise band, history, exit status 3 and 4): see
# bench/lib.sh. The history gets one row per benchmark (AL / clang -O2).
cd "$(dirname "$0")/../.." || exit 2
RUNS=5
args=()
for a in "$@"; do
  case $a in
    --force) BENCH_FORCE=1 ;;
    --no-save) BENCH_SAVE=0 ;;
    *) args+=("$a") ;;
  esac
done
set -- "${args[@]}"
while getopts "r:" o; do case $o in r) RUNS=$OPTARG;; *) exit 2;; esac; done
shift $((OPTIND-1))
. bench/lib.sh
CLANG=${CLANG:-clang}
bench_header "wide${*:+ $*}" "${ALC:-./build/alc}" "clang: $("$CLANG" --version | head -1) (-O2)"
bench_quiet_check before
echo
for d in ${*:-vec int str call mem fp}; do echo "== $d"; bash bench/wide/harness.sh -r "$RUNS" bench/wide/$d; done | tee bench/wide/last.txt
echo
awk '/^== /{g=$2; next} $1=="name"||$1~/_v$/{next} NF>=7 && $4+0>0 {n[g]++; s[g]+=log($4); v[g]+=log($6); N++; S+=log($4); V+=log($6)}
  END{for(g in n) printf "%-5s n=%d al/cl=%.2f al/novec=%.2f\n", g, n[g], exp(s[g]/n[g]), exp(v[g]/n[g]); printf "ALL   n=%d al/cl=%.2f al/novec=%.2f\n", N, exp(S/N), exp(V/N)}' bench/wide/last.txt
awk -v noise="$BENCH_NOISE" '/^== /||$1=="name"||$1~/_v$/{next} NF>=7 && $4+0>0 { if ($4 > 1 + noise/100) s++; else if ($4 < 1 - noise/100) f++; else t++ }
  END { printf "against clang -O2: %d faster, %d tie (within %s %%), %d slower\n", f, t, noise, s }' bench/wide/last.txt
while read -r name cl al ratio _; do bench_row clang "$name" "$ratio" "$al" "$cl"; done < <(awk '/^== /||$1=="name"||$1~/_v$/{next} NF>=7 && $4+0>0 { print $1, $2, $3, $4 }' bench/wide/last.txt)
echo
bench_finish

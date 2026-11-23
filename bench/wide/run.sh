#!/bin/bash
# Run every group of the wide benchmark set serially; prints per-group and overall geomeans.
# usage: bench/wide/run.sh [-r runs] [groups...]      (default groups: vec int str call mem fp)
cd "$(dirname "$0")/../.." || exit 2
RUNS=5
while getopts "r:" o; do case $o in r) RUNS=$OPTARG;; esac; done
shift $((OPTIND-1))
for d in ${*:-vec int str call mem fp}; do echo "== $d"; bash bench/wide/harness.sh -r "$RUNS" bench/wide/$d; done | tee bench/wide/last.txt
awk '/^== /{g=$2; next} $1=="name"||$1~/_v$/{next} NF>=7 && $4+0>0 {n[g]++; s[g]+=log($4); v[g]+=log($6); N++; S+=log($4); V+=log($6)}
  END{for(g in n) printf "%-5s n=%d al/cl=%.2f al/novec=%.2f\n", g, n[g], exp(s[g]/n[g]), exp(v[g]/n[g]); printf "ALL   n=%d al/cl=%.2f al/novec=%.2f\n", N, exp(S/N), exp(V/N)}' bench/wide/last.txt

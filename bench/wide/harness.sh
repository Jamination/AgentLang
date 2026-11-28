#!/bin/bash
# Wide benchmark harness: AL vs clang -O2 (Linux, or Windows under Git Bash).
# usage: bench/wide/harness.sh [-r runs] <dir> [names...]
#   <dir> holds pairs NAME.al / NAME.c that print identical output.
# Columns: clang -O2 time, AL (checks on) time and ratio, AL --unchecked ratio, clang -O2 -fno-vectorize -fno-slp-vectorize ratio-of-AL.
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
if [[ -z "${CLANG:-}" ]]; then
  if command -v clang >/dev/null 2>&1; then
    CLANG="clang"
  else
    CLANG="/c/Program Files/Microsoft Visual Studio/2022/Community/VC/Tools/Llvm/x64/bin/clang.exe"
  fi
fi
if [[ -z "${ALC:-}" ]]; then
  if [[ -x "$ROOT/build/alc.exe" && "$(uname -s)" != "Linux" ]]; then
    ALC="$ROOT/build/alc.exe"
  else
    ALC="$ROOT/build/alc"
  fi
fi
EXT=""
[[ "$ALC" == *.exe ]] && EXT=".exe"
RUNS=5
while getopts "r:" o; do case $o in r) RUNS=$OPTARG;; esac; done
shift $((OPTIND-1))
DIR="$1"; shift
cd "$DIR" || exit 2
mkdir -p bin
NAMES=${*:-$(ls *.al | sed 's/\.al$//')}
t_one() { local s e; s=$(date +%s%N); "$@" >/dev/null 2>&1; e=$(date +%s%N); echo $((e-s)); }
printf "%-18s %8s %8s %7s %7s %7s  %s\n" name clang_s al_s al/cl unchk/cl al/novec status
failed=0
for b in $NAMES; do
  "$CLANG" -O2 -o bin/$b.c$EXT $b.c -lm 2>bin/$b.c.err || { echo "$b: clang failed: $(head -3 bin/$b.c.err)"; failed=1; continue; }
  "$CLANG" -O2 -fno-vectorize -fno-slp-vectorize -o bin/$b.nv$EXT $b.c -lm 2>/dev/null
  "$ALC" build $b.al -o bin/$b.al$EXT >bin/$b.al.err 2>&1 || { echo "$b: alc failed: $(head -3 bin/$b.al.err)"; failed=1; continue; }
  "$ALC" build $b.al --unchecked -o bin/$b.un$EXT >/dev/null 2>&1
  bin/$b.c$EXT >bin/$b.c.out 2>/dev/null
  timeout 120 bin/$b.al$EXT >bin/$b.al.out 2>bin/$b.al.stderr; code=$?
  status=ok
  [[ $code != 0 ]] && status="EXIT=$code $(head -c 100 bin/$b.al.stderr)"
  cmp -s <(tr -d '\r' <bin/$b.c.out) <(tr -d '\r' <bin/$b.al.out) || status="$status OUTPUT-DIFFERS"
  if [[ "$status" != "ok" ]]; then
    printf "%-18s %8s %8s %7s %7s %7s  %s\n" "$b" "-" "-" "-" "-" "-" "$status"
    failed=1
    continue
  fi
  # the four programs in turn, RUNS times: a disturbance hits all of them alike
  tc=""; ta=""; tu=""; tn=""
  for _ in $(seq "$RUNS"); do
    t=$(t_one bin/$b.c$EXT); [[ -z $tc || $t -lt $tc ]] && tc=$t
    t=$(t_one bin/$b.al$EXT); [[ -z $ta || $t -lt $ta ]] && ta=$t
    t=$(t_one bin/$b.un$EXT); [[ -z $tu || $t -lt $tu ]] && tu=$t
    t=$(t_one bin/$b.nv$EXT); [[ -z $tn || $t -lt $tn ]] && tn=$t
  done
  awk -v n="$b" -v c="$tc" -v a="$ta" -v u="$tu" -v v="$tn" -v s="$status" 'BEGIN { printf "%-18s %8.3f %8.3f %7.2f %7.2f %7.2f  %s\n", n, c/1e9, a/1e9, a/c, u/c, a/v, s }'
done
exit $failed

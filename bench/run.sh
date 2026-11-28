#!/bin/bash
# The ten classic benchmarks: AL against C (clang -O2, gcc -O2), C++ (g++ -O2) and Rust
# (rustc -O). Every program of a row must print the same output; then all are timed.
# usage: bench/run.sh [-r runs] [-f "alc flags"] [--force] [--no-save] [names...]
#   -r runs     runs per program (default 3); the best one counts
#   --force     write a disturbed run to the history anyway (marked as not quiet)
#   --no-save   do not write the history
# A baseline whose compiler is not installed is left out. How a run is judged (machine, quiet
# check, noise band, history, exit status 3 and 4): see bench/lib.sh.
cd "$(dirname "$0")/.." || exit 2
RUNS=3; FLAGS=""
args=()
for a in "$@"; do
  case $a in
    --force) BENCH_FORCE=1 ;;
    --no-save) BENCH_SAVE=0 ;;
    *) args+=("$a") ;;
  esac
done
set -- "${args[@]}"
while getopts "r:f:" o; do case $o in r) RUNS=$OPTARG;; f) FLAGS=$OPTARG;; *) exit 2;; esac; done
shift $((OPTIND-1))
NAMES=${*:-nbody spectralnorm fannkuch mandelbrot binarytrees sha256 matmul quicksort sieve hashmap}
ALC=${ALC:-./build/alc}; BIN=bench/bin; mkdir -p $BIN
. bench/lib.sh

# the baselines: name, source extension, build command (the output path and the source follow)
BASES=(); declare -A EXT CMD VER LIBS
add_base() { command -v "$3" >/dev/null 2>&1 || return; BASES+=("$1"); EXT[$1]=$2; CMD[$1]="${*:3}"; VER[$1]=$("$3" --version | head -1); }
add_base clang c clang -O2 -o; LIBS[clang]=-lm
add_base gcc c gcc -O2 -o; LIBS[gcc]=-lm
add_base g++ cpp g++ -O2 -std=c++20 -o
add_base rust rs rustc -O -o
[[ ${#BASES[@]} -gt 0 ]] || { echo "no baseline compiler found (clang, gcc, g++, rustc)"; exit 2; }
hdr=()
for b in "${BASES[@]}"; do hdr+=("$b: ${VER[$b]} (${CMD[$b]% -o})"); done
bench_header "classic${FLAGS:+ $FLAGS}" "$ALC" "${hdr[@]}"
bench_quiet_check before
echo

# best build time of "$@" in nanoseconds (3 builds), "" if it fails
build_time() {
  local best="" t s e
  for _ in 1 2 3; do
    s=$(date +%s%N); "$@" >/dev/null 2>$BIN/build.err || { echo ""; return; }; e=$(date +%s%N); t=$((e - s))
    [[ -z $best || $t -lt $best ]] && best=$t
  done
  echo "$best"
}

printf "%-13s %8s" name al_s
for b in "${BASES[@]}"; do printf " %8s" "${b}_s"; done
for b in "${BASES[@]}"; do printf " %8s" "al/$b"; done
printf "  %s\n" "vs ${BASES[0]}"
declare -A LOG CNT BUILD
failed=0
for n in $NAMES; do
  # shellcheck disable=SC2086
  t=$(build_time $ALC build bench/$n.al $FLAGS -o $BIN/$n.al.bin)
  [[ -n $t ]] || { echo "$n: alc failed: $(head -3 $BIN/build.err)"; failed=1; continue; }
  BUILD[al]=$(( ${BUILD[al]:-0} + t ))
  timeout 120 $BIN/$n.al.bin >$BIN/$n.al.out 2>$BIN/$n.al.stderr; code=$?
  [[ $code == 0 ]] || { printf "%-13s FAILED  EXIT=%s %s\n" "$n" "$code" "$(head -c 100 $BIN/$n.al.stderr)"; failed=1; continue; }
  have=()
  for b in "${BASES[@]}"; do
    src=bench/$n.${EXT[$b]}
    [[ -f $src ]] || continue
    # shellcheck disable=SC2086
    t=$(build_time ${CMD[$b]} $BIN/$n.$b.bin $src ${LIBS[$b]:-})
    [[ -n $t ]] || { echo "$n: $b failed: $(head -3 $BIN/build.err)"; failed=1; continue; }
    BUILD[$b]=$(( ${BUILD[$b]:-0} + t ))
    $BIN/$n.$b.bin >$BIN/$n.$b.out 2>/dev/null
    cmp -s $BIN/$n.$b.out $BIN/$n.al.out || { printf "%-13s FAILED  the output of %s differs from AL's\n" "$n" "$b"; failed=1; continue; }
    have+=("$b")
  done
  # the programs of the row in turn, RUNS times: a disturbance hits all of them alike
  declare -A best=()
  for _ in $(seq "$RUNS"); do
    for v in al "${have[@]}"; do
      t=$(bench_time $BIN/$n.$v.bin)
      [[ -z ${best[$v]:-} || $t -lt ${best[$v]} ]] && best[$v]=$t
    done
  done
  printf "%-13s %8.3f" "$n" "$(awk -v t="${best[al]}" 'BEGIN { print t / 1e9 }')"
  for b in "${BASES[@]}"; do
    if [[ -n ${best[$b]:-} ]]; then printf " %8.3f" "$(awk -v t="${best[$b]}" 'BEGIN { print t / 1e9 }')"; else printf " %8s" "-"; fi
  done
  first=""
  for b in "${BASES[@]}"; do
    if [[ -z ${best[$b]:-} ]]; then printf " %8s" "-"; continue; fi
    r=$(awk -v a="${best[al]}" -v c="${best[$b]}" 'BEGIN { printf "%.3f", a / c }')
    printf " %8s" "$r"
    [[ $b == "${BASES[0]}" ]] && first=$r
    LOG[$b]=$(awk -v s="${LOG[$b]:-0}" -v r="$r" 'BEGIN { print s + log(r) }'); CNT[$b]=$(( ${CNT[$b]:-0} + 1 ))
    bench_row "$b" "$n" "$r" "$(awk -v t="${best[al]}" 'BEGIN { printf "%.4f", t / 1e9 }')" "$(awk -v t="${best[$b]}" 'BEGIN { printf "%.4f", t / 1e9 }')"
  done
  printf "  %s\n" "$([[ -n $first ]] && bench_verdict "$first")"
  unset best
done
printf "%-13s %8s" geomean ""
for b in "${BASES[@]}"; do printf " %8s" ""; done
for b in "${BASES[@]}"; do
  if [[ ${CNT[$b]:-0} -gt 0 ]]; then printf " %8s" "$(awk -v s="${LOG[$b]}" -v n="${CNT[$b]}" 'BEGIN { printf "%.3f", exp(s / n) }')"; else printf " %8s" "-"; fi
done
echo
echo
echo "time to compile these programs (best of 3 builds each, summed):"
printf "  %-6s %7.3f s\n" alc "$(awk -v t="${BUILD[al]:-0}" 'BEGIN { print t / 1e9 }')"
for b in "${BASES[@]}"; do
  [[ -n ${BUILD[$b]:-} ]] || continue
  printf "  %-6s %7.3f s   %5.1f times alc\n" "$b" "$(awk -v t="${BUILD[$b]}" 'BEGIN { print t / 1e9 }')" "$(awk -v t="${BUILD[$b]}" -v a="${BUILD[al]}" 'BEGIN { print t / a }')"
done
echo
bench_finish; st=$?
[[ $failed == 1 ]] && exit 1
exit $st

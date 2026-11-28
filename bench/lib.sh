# Shared by bench/run.sh, bench/compile.sh and bench/wide: what makes a measurement worth
# keeping. Sourced, not run.
#
#   the machine    every run prints the CPU, its cores and threads, the kernel and the compilers.
#                  Nothing is pinned: every program may use all threads (the compiler compiles
#                  on all of them), so the counts are part of the result.
#   quiet check    the load of the machine is sampled before and after the run, and over the
#                  whole run what other programs used is measured. More than BENCH_QUIET busy
#                  cores (default 0.5) other than the benchmarks themselves means
#                  the run is DISTURBED: it is printed, but not written to the history, and the
#                  script exits with status 4 (--force keeps it, marked as not quiet).
#   noise band     a ratio within BENCH_NOISE percent (default 5) of 1 is a tie, and a change
#                  within it between two runs is no change.
#   history        bench/history.tsv gets one line per benchmark and baseline of every quiet
#                  run. A value more than the noise band worse than in the previous run of the
#                  same suite on the same CPU is a regression: status 3.
#
# Columns of bench/history.tsv (tab-separated; `value` is what is compared, lower is better:
# the time ratio AL / baseline, or seconds for the compile suite):
#   run commit suite cpu cores threads alc baseline runs quiet name value al_s base_s

BENCH_NOISE=${BENCH_NOISE:-5}
BENCH_QUIET=${BENCH_QUIET:-0.5}
BENCH_HISTORY=${BENCH_HISTORY:-bench/history.tsv}
BENCH_FORCE=${BENCH_FORCE:-0}
BENCH_SAVE=${BENCH_SAVE:-1}
BENCH_DISTURBED=0
BENCH_RUN=$(date -u +%Y-%m-%dT%H:%M:%SZ)
BENCH_ROWS=$(mktemp)
trap 'rm -f "$BENCH_ROWS"' EXIT

# CPU model, physical cores, threads, kernel
bench_machine() {
  BENCH_CPU=$(awk -F': ' '/^model name/ { print $2; exit }' /proc/cpuinfo 2>/dev/null)
  [[ -z $BENCH_CPU ]] && BENCH_CPU=$(uname -m)
  BENCH_THREADS=$(nproc 2>/dev/null || echo 1)
  BENCH_CORES=$(lscpu -p=core,socket 2>/dev/null | grep -v '^#' | sort -u | wc -l)
  [[ $BENCH_CORES -gt 0 ]] || BENCH_CORES=$BENCH_THREADS
  BENCH_KERNEL="$(uname -s) $(uname -r)"
  BENCH_COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo unknown)
  [[ -n $(git status --porcelain -- src std 2>/dev/null) ]] && BENCH_COMMIT="$BENCH_COMMIT+"
}

# $1 = suite, $2 = the compiler under test, $3... = "name: version" lines of the baselines
bench_header() {
  bench_machine
  BENCH_SUITE=$1
  BENCH_ALC_VERSION=$("$2" --version 2>/dev/null | head -1)
  shift 2
  echo "machine   $BENCH_CPU, $BENCH_CORES cores, $BENCH_THREADS threads, not pinned (all threads available)"
  echo "system    $BENCH_KERNEL"
  echo "compiler  $BENCH_ALC_VERSION ($BENCH_COMMIT)"
  local b
  for b in "$@"; do echo "baseline  $b"; done
  echo "method    best of $RUNS runs, the programs of a row run in turn; noise band $BENCH_NOISE %"
}

# busy cores of the whole machine over one second
bench_busy() {
  local a b
  a=$(awk '/^cpu / { print $2 + $3 + $4 + $7 + $8 + $9, $5 + $6 }' /proc/stat 2>/dev/null) || { echo 0; return; }
  sleep 1
  b=$(awk '/^cpu / { print $2 + $3 + $4 + $7 + $8 + $9, $5 + $6 }' /proc/stat)
  awk -v a="$a" -v b="$b" -v n="$(nproc)" 'BEGIN { split(a, x, " "); split(b, y, " "); busy = y[1] - x[1]; idle = y[2] - x[2]
    if (busy + idle <= 0) { print 0; exit }
    printf "%.2f", n * busy / (busy + idle) }'
}

# seconds of CPU time the whole machine has used since it started
bench_machine_cpu() {
  awk -v hz="$(getconf CLK_TCK 2>/dev/null || echo 100)" '/^cpu / { printf "%.2f", ($2 + $3 + $4 + $7 + $8 + $9) / hz }' /proc/stat 2>/dev/null || echo 0
}

# Seconds of CPU time the programs started by this script have used, into BENCH_OWN. (`times`
# must run in this shell, not in a `$( )`: a subshell has no children of its own yet.)
bench_own_cpu() {
  times >"$BENCH_ROWS.times"
  BENCH_OWN=$(awk 'NR == 2 { for (i = 1; i <= 2; i++) { split($i, p, /[ms]/); t += p[1] * 60 + p[2] } printf "%.2f", t }' "$BENCH_ROWS.times")
  rm -f "$BENCH_ROWS.times"
}

# During the run: what the rest of the machine used while the benchmarks ran, in cores (the
# CPU time of the whole machine less that of the benchmarks, over the elapsed time)
bench_during() {
  local busy
  bench_own_cpu
  busy=$(awk -v m0="$BENCH_M0" -v m1="$(bench_machine_cpu)" -v o0="$BENCH_O0" -v o1="$BENCH_OWN" -v t0="$BENCH_T0" -v t1="$(date +%s.%N)" \
    'BEGIN { d = t1 - t0; if (d <= 0) { print 0; exit } x = ((m1 - m0) - (o1 - o0)) / d; if (x < 0) x = 0; printf "%.2f", x }')
  if awk -v b="$busy" -v q="$BENCH_QUIET" 'BEGIN { exit !(b > q) }'; then
    BENCH_DISTURBED=1
    echo "load      during the run: $busy cores busy besides the benchmarks: DISTURBED (more than $BENCH_QUIET)"
  else
    echo "load      during the run: $busy cores busy besides the benchmarks: quiet"
  fi
}

# $1 = "before" / "after"
bench_quiet_check() {
  local busy k; busy=$(bench_busy)
  # before the run a busy moment may pass: look again for up to 20 seconds before giving up
  if [[ $1 == before ]]; then
    for k in 1 2 3 4 5 6 7 8 9 10; do
      awk -v b="$busy" -v q="$BENCH_QUIET" 'BEGIN { exit !(b > q) }' || break
      sleep 1; busy=$(bench_busy)
    done
  fi
  if [[ $1 == before ]]; then BENCH_M0=$(bench_machine_cpu); bench_own_cpu; BENCH_O0=$BENCH_OWN; BENCH_T0=$(date +%s.%N); fi
  if awk -v b="$busy" -v q="$BENCH_QUIET" 'BEGIN { exit !(b > q) }'; then
    BENCH_DISTURBED=1
    echo "load      $1 the run: $busy cores busy: DISTURBED (more than $BENCH_QUIET; close other programs)"
  else
    echo "load      $1 the run: $busy cores busy: quiet"
  fi
}

# faster / tie / slower for the ratio $1 (lower is better)
bench_verdict() {
  awk -v r="$1" -v n="$BENCH_NOISE" 'BEGIN { if (r > 1 + n / 100) print "slower"; else if (r < 1 - n / 100) print "faster"; else print "tie" }'
}

# one measurement: $1 = baseline, $2 = name, $3 = value, $4 = al seconds, $5 = baseline seconds
bench_row() {
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$BENCH_RUN" "$BENCH_COMMIT" "$BENCH_SUITE" "$BENCH_CPU" \
    "$BENCH_CORES" "$BENCH_THREADS" "$BENCH_ALC_VERSION" "$1" "$RUNS" "QUIET" "$2" "$3" "$4" "$5" >>"$BENCH_ROWS"
}

# After the run: the quiet check, the comparison with the previous run, the history. Returns
# the exit status of the script: 0, 3 (a regression) or 4 (disturbed).
bench_finish() {
  bench_during
  bench_quiet_check after
  local status=0 quiet=yes
  [[ $BENCH_DISTURBED == 1 ]] && quiet=no
  if [[ -s $BENCH_HISTORY ]]; then
    # the previous run of this suite on this CPU, row by row (the first baseline only: the
    # others are for comparison, not for the compiler's own progress)
    awk -F'\t' -v suite="$BENCH_SUITE" -v cpu="$BENCH_CPU" -v noise="$BENCH_NOISE" '
      FNR == NR { if ($3 == suite && $4 == cpu && $10 == "yes") { if ($1 != last) { last = $1; delete old; delete base }; old[$11] = $12; base[$11] = $8; commit = $2 } next }
      ($11 in old) && base[$11] == $8 { n++; d = ($12 / old[$11] - 1) * 100
        if (d > noise) { bad++; printf "regression  %-16s %s -> %s (%+.1f %%)\n", $11, old[$11], $12, d }
        else if (d < -noise) printf "improved    %-16s %s -> %s (%+.1f %%)\n", $11, old[$11], $12, d }
      END { if (n) printf "history   compared %d rows with the run of %s (%s): %d regression(s)\n", n, last, commit, bad; exit bad > 0 }
    ' "$BENCH_HISTORY" "$BENCH_ROWS" || status=3
  fi
  if [[ $BENCH_DISTURBED == 1 && $BENCH_FORCE != 1 ]]; then
    echo "history   not written: the machine was not quiet (rerun, or --force)"
    return 4
  fi
  if [[ $BENCH_SAVE == 1 && -s $BENCH_ROWS ]]; then
    sed "s/\tQUIET\t/\t$quiet\t/" "$BENCH_ROWS" >>"$BENCH_HISTORY"
    echo "history   $(wc -l <"$BENCH_ROWS") rows added to $BENCH_HISTORY"
  fi
  return $status
}

# nanoseconds of one run of "$@"
bench_time() {
  local s e
  s=$(date +%s%N); "$@" >/dev/null 2>&1; e=$(date +%s%N)
  echo $((e - s))
}

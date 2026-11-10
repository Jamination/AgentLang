#!/bin/bash
# Full verification: build, conformance tests, benchmark correctness and performance vs clang -O2.
# Exit code 0 only if everything passes and the performance bar is met:
#   geometric mean of (AL time / clang -O2 time) <= 1.5 and every ratio <= 2.5
cd "$(dirname "$0")" || exit 2
RUNS=${RUNS:-7}
BENCHES="nbody spectralnorm fannkuch mandelbrot binarytrees sha256 matmul quicksort sieve hashmap"
ALC=./target/release/alc
BIN=bench/bin
fail=0

echo "== build =="
cargo build --release 2>&1 | tail -1
[[ -x $ALC ]] || { echo "FAIL: compiler did not build"; exit 1; }

echo "== no external tools in the compile path =="
# the only process the compiler may spawn is the freshly built program for `alc run` / `alc test`
spawns=$(grep -n "Command::new" src/*.rs src/*/*.rs | grep -v "Command::new(&out_path)")
if [[ -n "$spawns" ]]; then echo "FAIL: compiler spawns external processes:"; echo "$spawns"; fail=1; fi
if grep -nEi '"(cc|gcc|clang|ld|as|llc|lld|nasm)"' src/*.rs src/*/*.rs; then echo "FAIL: external tool referenced"; fail=1; fi
if grep -q '^\[dependencies\]' Cargo.toml && [[ -n "$(sed -n '/^\[dependencies\]/,/^\[/p' Cargo.toml | grep -v '^\[' | grep -v '^\s*$')" ]]; then
  echo "FAIL: Cargo.toml declares external crates"; fail=1
fi

echo "== conformance tests =="
tests/run.sh $ALC || fail=1

echo "== benchmarks =="
mkdir -p $BIN
t_min() { # best wall time of $RUNS runs, in seconds
  local best=""
  for _ in $(seq "$RUNS"); do
    local s e t
    s=$(date +%s%N)
    "$@" >/dev/null 2>&1
    e=$(date +%s%N)
    t=$(( e - s ))
    if [[ -z "$best" || $t -lt $best ]]; then best=$t; fi
  done
  echo "$best"
}
ratios=()
printf "%-14s %10s %10s %8s\n" benchmark "clang -O2" AL ratio
for b in $BENCHES; do
  if ! clang -O2 -o $BIN/$b.c.bin bench/$b.c -lm 2>$BIN/$b.c.err; then echo "FAIL $b: clang failed"; cat $BIN/$b.c.err; fail=1; continue; fi
  if ! $ALC build bench/$b.al -o $BIN/$b.al.bin 2>$BIN/$b.al.err; then echo "FAIL $b: alc failed"; cat $BIN/$b.al.err; fail=1; continue; fi
  # static ELF, no interpreter, no dynamic section
  hdr=$(readelf -hl $BIN/$b.al.bin 2>&1)
  if ! grep -q "Advanced Micro Devices X86-64" <<<"$hdr" || ! grep -q "EXEC (Executable file)" <<<"$hdr"; then echo "FAIL $b: not a static x86-64 executable"; fail=1; fi
  if grep -qE "INTERP|DYNAMIC" <<<"$hdr"; then echo "FAIL $b: binary has PT_INTERP/PT_DYNAMIC"; fail=1; fi
  $BIN/$b.c.bin >$BIN/$b.c.out 2>/dev/null; c_code=$?
  $BIN/$b.al.bin >$BIN/$b.al.out 2>/dev/null; a_code=$?
  if [[ $c_code != 0 || $a_code != 0 ]]; then echo "FAIL $b: exit codes c=$c_code al=$a_code"; fail=1; continue; fi
  if ! cmp -s $BIN/$b.c.out $BIN/$b.al.out; then echo "FAIL $b: outputs differ"; fail=1; continue; fi
  tc=$(t_min $BIN/$b.c.bin)
  ta=$(t_min $BIN/$b.al.bin)
  r=$(awk -v a="$ta" -v c="$tc" 'BEGIN { printf "%.3f", a / c }')
  ratios+=("$r")
  printf "%-14s %9.3fs %9.3fs %8s\n" "$b" "$(awk -v t="$tc" 'BEGIN { print t / 1e9 }')" "$(awk -v t="$ta" 'BEGIN { print t / 1e9 }')" "$r"
  if awk -v r="$r" 'BEGIN { exit !(r > 2.5) }'; then echo "FAIL $b: ratio $r exceeds 2.5"; fail=1; fi
done
if [[ ${#ratios[@]} == 10 ]]; then
  geo=$(printf "%s\n" "${ratios[@]}" | awk '{ s += log($1); n++ } END { printf "%.3f", exp(s / n) }')
  echo "geometric mean ratio: $geo (limit 1.5)"
  if awk -v g="$geo" 'BEGIN { exit !(g > 1.5) }'; then echo "FAIL: geometric mean $geo exceeds 1.5"; fail=1; fi
else
  echo "FAIL: only ${#ratios[@]} of 10 benchmarks produced a ratio"; fail=1
fi

if [[ $fail == 0 ]]; then echo "VERIFY: PASS"; else echo "VERIFY: FAIL"; fi
exit $fail

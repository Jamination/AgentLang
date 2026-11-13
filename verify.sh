#!/bin/bash
# Full verification: the compiler builds itself (and reproduces itself byte for byte),
# conformance tests (language, standard library, system-dependent tests, platform bindings),
# f32 semantics against clang, documentation presence, benchmark correctness and performance
# vs clang -O2.
# Exit code 0 only if everything passes and the performance bar is met:
#   geometric mean of (AL time / clang -O2 time) <= 1.5 and every ratio <= 2.5
# A test whose prerequisite is missing on this machine (GPU driver, sound library, display) is
# reported as SKIP with its reason and does not count as a failure.
cd "$(dirname "$0")" || exit 2
RUNS=${RUNS:-7}
BENCHES="nbody spectralnorm fannkuch mandelbrot binarytrees sha256 matmul quicksort sieve hashmap"
ALC=./build/alc
BIN=bench/bin
fail=0

echo "== build: the compiler compiles itself =="
# seed -> stage 1 -> stage 2 -> stage 3, stages 2 and 3 must be identical
./build.sh || { echo "FAIL: compiler did not build"; exit 1; }
[[ -x $ALC ]] || { echo "FAIL: compiler did not build"; exit 1; }

echo "== the compiler is AL only; no external tools in the compile path =="
others=$(find src -type f ! -name '*.al')
if [[ -n "$others" ]]; then echo "FAIL: non-AL files in src/:"; echo "$others"; fail=1; fi
if ls Cargo.toml >/dev/null 2>&1; then echo "FAIL: Cargo.toml is still present"; fail=1; fi
# the compiler calls no C function, so it is itself a static executable
if readelf -l $ALC 2>&1 | grep -qE "INTERP|DYNAMIC"; then echo "FAIL: the compiler is not a static executable"; fail=1; fi
# (the run-time library and its OS layers, which are compiled into programs, not into the compiler)
if grep -nE '^(priv )?extern ' src/*.al src/*/*.al | grep -vE '^src/prelude(_linux|_windows)?\.al'; then echo "FAIL: the compiler declares C functions"; fail=1; fi
# processes are only started in src/base.al: run_program (for `alc run` / `alc test`, which
# start the program that was just built) and ensure_stack (the compiler restarting itself)
spawns=$(grep -nE 'syscall\((57|58|59|56|322),' src/*.al src/*/*.al | grep -v '^src/base.al' | grep -vE '^src/prelude(_linux|_windows)?\.al')
if [[ -n "$spawns" ]]; then echo "FAIL: compiler sources start processes:"; echo "$spawns"; fail=1; fi
if [[ $(grep -c 'run_program(' src/main.al) != 1 ]]; then echo "FAIL: expected exactly one run_program call in src/main.al"; fail=1; fi
if grep -nEi '"(cc|gcc|clang|ld|as|llc|lld|nasm|rustc|cargo)"' src/*.al src/*/*.al; then echo "FAIL: external tool referenced"; fail=1; fi

echo "== conformance tests (language, standard library, system, bindings) =="
tests/run.sh $ALC | tee tmp_verify_conf.txt
[[ ${PIPESTATUS[0]} == 0 ]] || fail=1
skips=$(grep '^SKIP ' tmp_verify_conf.txt)
rm -f tmp_verify_conf.txt

echo "== f32 semantics against clang -O2 =="
mkdir -p $BIN
for c in tests/c/*.c; do
  name=$(basename "$c" .c)
  if ! clang -O2 -o $BIN/ref_$name "$c" -lm 2>$BIN/ref_$name.err; then echo "FAIL $name: clang failed"; cat $BIN/ref_$name.err; fail=1; continue; fi
  $BIN/ref_$name >$BIN/ref_$name.out
  for mode in "" "-O0" "--unchecked"; do
    if ! $ALC build tests/c/$name.al $mode -o $BIN/al_$name 2>$BIN/al_$name.err; then echo "FAIL $name [$mode]: alc failed"; cat $BIN/al_$name.err; fail=1; continue; fi
    $BIN/al_$name >$BIN/al_$name.out
    if cmp -s $BIN/ref_$name.out $BIN/al_$name.out; then
      echo "ok   $name [${mode:-default}]: $(wc -l <$BIN/ref_$name.out) lines identical to C"
    else
      echo "FAIL $name [${mode:-default}]: output differs from the C reference"; diff $BIN/ref_$name.out $BIN/al_$name.out | head -5; fail=1
    fi
  done
done

echo "== standard library: tests, documentation, static linking =="
# every module has at least one test and a documentation page
for m in math rand time mem input window audio image asset os wayland; do
  n=$(ls tests/std/${m}*.al tests/sys/${m}*.al 2>/dev/null | wc -l)
  [[ $n -gt 0 ]] || { echo "FAIL: no test for module $m"; fail=1; }
  [[ -s docs/std/$m.md ]] || { echo "FAIL: docs/std/$m.md is missing"; fail=1; }
done
ls tests/run/vectors.al tests/run/overload.al tests/c/f32.al >/dev/null 2>&1 || { echo "FAIL: f32 / vector language tests are missing"; fail=1; }
[[ -f tests/sys/vk_triangle.al && -f tests/sys/data/vk_triangle.ref && -s docs/std/vk.md ]] || { echo "FAIL: Vulkan triangle test, reference image or docs missing"; fail=1; }
for m in dx12 metal; do
  ls tests/check/${m}*.al >/dev/null 2>&1 || { echo "FAIL: no check-only sample for $m"; fail=1; }
  [[ -s std/$m.al && -s docs/std/$m.md ]] || { echo "FAIL: bindings or docs for $m missing"; fail=1; }
done
for d in docs/LANGUAGE.md docs/STDLIB.md; do
  [[ -s $d ]] || { echo "FAIL: $d is missing"; fail=1; }
done
grep -q "## f32, vectors, matrices" docs/LANGUAGE.md || { echo "FAIL: the language reference does not cover f32 / vectors"; fail=1; }
# programs that use no system library stay static, libc-free executables
nstatic=0
for src in tests/std/*.al; do
  $ALC build "$src" -o $BIN/static_check 2>/dev/null || { echo "FAIL: $src does not build"; fail=1; continue; }
  if readelf -l $BIN/static_check 2>&1 | grep -qE "INTERP|DYNAMIC"; then echo "FAIL: $src is not a static executable"; fail=1; fi
  nstatic=$((nstatic+1))
done
echo "$nstatic standard-library test programs are static executables"
# the graphics checks, spelled out
if grep -q '^SKIP vk_triangle' <<<"$skips"; then
  echo "Vulkan offscreen triangle: SKIPPED (see below)"
elif $ALC build tests/sys/vk_triangle.al -o $BIN/vk_triangle 2>/dev/null && $BIN/vk_triangle >$BIN/vk_triangle.out 2>&1 && cmp -s $BIN/vk_triangle.out tests/sys/vk_triangle.out; then
  echo "Vulkan offscreen triangle: rendered by the driver, pixels match tests/sys/data/vk_triangle.ref"
else
  echo "FAIL: Vulkan offscreen triangle"; head -5 $BIN/vk_triangle.out; fail=1
fi
for m in dx12 metal; do
  if $ALC check tests/check/${m}_triangle.al 2>$BIN/check_$m.err; then
    echo "$m bindings and sample: pass alc check"
  else
    echo "FAIL: $m sample does not type-check"; head -5 $BIN/check_$m.err; fail=1
  fi
done
if [[ -n "$skips" ]]; then
  echo "skipped (prerequisite missing on this machine):"
  echo "$skips" | sed 's/^/  /'
else
  echo "no test was skipped"
fi

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

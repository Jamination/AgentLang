# `alc run` runs the program with the stack limit and environment alc was started with (alc
# raises its own stack limit and restarts itself with a marker variable)
set -u
ALC=$1; D=$2; cd "$D" || exit 1
printf 'fn main() {\n    _, ok := env_get("ALC_STACK_SET")\n    lim: [2]i64\n    syscall(97, 3, ptr(lim))\n    print(ok, lim[0] >> 10)\n}\n' > e.al
ulimit -s 8192 || exit 1
out=$("$ALC" run e.al) || { echo "FAIL: run"; exit 1; }
[[ "$out" == "false 8192" ]] || { echo "FAIL: got $out"; exit 1; }

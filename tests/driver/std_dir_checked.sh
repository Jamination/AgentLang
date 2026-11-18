# a bundled module read from ALC_STD_DIR (one being written) is type-checked in full by
# `alc build` / `alc run` as by `alc check`, also in functions the program never reaches; the
# built-in modules are compiled only as far as the program reaches into them
set -u
ALC=$1; D=$2; cd "$D" || exit 1
fail() { echo "FAIL: $*"; exit 1; }
mkdir std
printf 'fn unused_helper() -> i64 { y: i32 = 1; return wide(y) }\nfn wide(x: i64) -> i64 { x }\n' > std/net.al
printf 'use std.net\nfn main() { print(1) }\n' > a.al
for cmd in check build run; do
    ALC_STD_DIR=std "$ALC" $cmd a.al >out 2>err; [[ $? == 1 ]] || fail "$cmd: status"
    grep -qF '<std/net.al>:1:53: error: argument `x` of `wide`: expected i64, found i32' err || fail "$cmd: $(cat err)"
done
"$ALC" run a.al >out 2>err || fail "built-in std.net: $(cat err)"
[[ $(cat out) == "1" ]] || fail "built-in std.net: output $(cat out)"
exit 0

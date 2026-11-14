# declarations of bundled modules (read from ALC_STD_DIR): two modules declaring the same name
# is an error, as is a module redeclaring a core library function with the same parameter
# types; a module may declare a value with the name of a core type
set -u
ALC=$1; D=$2; cd "$D" || exit 1
fail() { echo "FAIL: $*"; exit 1; }
mkdir std
printf 'struct Clash { a: i64 }\n' > std/image.al
printf 'struct Clash { b: i64 }\n' > std/asset.al
printf 'use std.image\nuse std.asset\nfn main() {}\n' > a.al
ALC_STD_DIR=std "$ALC" check a.al 2>err; [[ $? == 1 ]] || fail "two modules: status"
grep -qF '<std/asset.al>:1:1: error: `Clash` is already declared at <std/image.al>:1:1' err || fail "two modules: $(cat err)"
printf 'fn pow(x: f64, y: f64) -> f64 { x }\n' > std/image.al
ALC_STD_DIR=std "$ALC" check a.al 2>err; [[ $? == 1 ]] || fail "core function: status"
grep -qF '<std/image.al>:1:1: error: `pow` is already declared with these parameter types at <std/math.al>' err || fail "core function: $(cat err)"
# (as std.dx12's methods named `Map` next to the core's `Map[K, V]`)
printf 'fn Vec(x: i64) -> i64 { x * 2 }\nfn twice(v: Vec[i64]) -> i64 { Vec(v.len) }\n' > std/image.al
printf 'use std.image\nfn main() {\n v := vec_of([]i64{1, 2, 3})\n print(twice(v), Vec(5))\n}\n' > b.al
ALC_STD_DIR=std "$ALC" run b.al >out 2>err || fail "module value with a core type name: $(cat err)"
[[ $(cat out) == "6 10" ]] || fail "module value with a core type name: output $(cat out)"
exit 0

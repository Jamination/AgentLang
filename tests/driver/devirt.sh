# calls through function values whose target is known compile to direct calls (retain, sort_by
# with and without a context, user generics with nested and anonymous functions, values in
# variables and fields); a function value chosen at run time stays an indirect call. Counted in
# the machine code of `--emit-asm` (`callind`), against a program without function values.
set -u
ALC=$1; D=$2; cd "$D" || exit 1
cat > none.al <<'EOF'
fn main() {
    v := vec_of([]i64{3, 1, 2})
    print(v.items())
}
EOF
cat > known.al <<'EOF'
fn is_even(x: i64) -> bool { x % 2 == 0 }
fn below(lim: i64, x: i64) -> bool { x < lim }
fn desc(a: i64, b: i64) -> bool { a > b }
fn by_rank(rank: []i64, a: i64, b: i64) -> bool { rank[a] < rank[b] }
fn sq(x: i64) -> i64 { x * x }
fn apply[T](x: T, f: fn(T) -> T) -> T { f(x) }
fn twice[T](x: T, f: fn(T) -> T) -> T { apply(apply(x, f), f) }
struct Ops { f: fn(i64) -> i64 }
fn main() {
    v := vec_of([]i64{5, 2, 8, 1, 9, 4})
    v.retain(is_even)
    v.retain(fn(x: i64) -> bool { x != 4 })
    v.retain(7, below)
    sort_by(v.items(), desc)
    sort_by(v.items(), fn(a: i64, b: i64) -> bool { a < b })
    rank := []i64{3, 1, 2}
    idx := vec_of([]i64{0, 1, 2})
    sort_by(idx.items(), rank, by_rank)
    sort_by(idx.items(), 2, fn(m: i64, a: i64, b: i64) -> bool { a % m < b % m })
    fn cube(x: i64) -> i64 { x * x * x }
    g := cube
    ops := Ops{f: sq}
    print(v.items(), idx.items(), apply(3, sq), twice(2, cube), apply(4, fn(x: i64) -> i64 { x + 1 }), g(5), ops.f(6))
}
EOF
cat > chosen.al <<'EOF'
fn sq(x: i64) -> i64 { x * x }
fn neg(x: i64) -> i64 { -x }
fn main() {
    f := if len(args()) > 1 { sq } else { neg }
    print(f(7))
}
EOF
count() {
    "$ALC" build "$@" --emit-asm -o out >asm || { echo "FAIL: build $*"; exit 1; }
    grep -c 'callind' asm
}
for t in "" "--target windows"; do
    base=$(count $t none.al)
    known=$(count $t known.al)
    chosen=$(count $t chosen.al)
    [[ $known == "$base" ]] || { echo "FAIL: $t known targets: $known indirect calls, $base without function values"; exit 1; }
    (( chosen > base )) || { echo "FAIL: $t a function value chosen at run time must stay an indirect call"; exit 1; }
done
"$ALC" build known.al -o known || { echo "FAIL: build known"; exit 1; }
./known >out.txt || { echo "FAIL: run known"; exit 1; }
echo '[2] [2, 0, 1] 9 512 5 125 36' >exp
diff exp out.txt || { echo "FAIL: known output"; exit 1; }
exit 0

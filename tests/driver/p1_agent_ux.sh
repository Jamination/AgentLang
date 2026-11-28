# P1 agent-UX features: --help, --json contracts, sigs --std/--pub/--filter/--json,
# test --json/--filter, fuzzy "did you mean?", -W/--deny-warnings, upgraded lint_copy_writes,
# and // alc fmt: off .. // alc fmt: on.
set -u
ALC=$1; D=$2; cd "$D" || exit 1
fail() { echo "FAIL: $1"; exit 1; }

# 1. --help / -h / help / fmt --help exit 0 and print to stdout
for args in "--help" "-h" "help" "build --help" "fmt --help"; do
  "$ALC" $args >out 2>err; [[ $? == 0 ]] || fail "$args: status"
  [[ -s out && ! -s err ]] || fail "$args: output/err"
done

# 2. --version --json
"$ALC" --version --json >out 2>err; [[ $? == 0 ]] || fail "--version --json: status"
grep -q '^{"version":"[0-9]\+\.[0-9]\+\.[0-9]\+","target_os":".*","target_arch":".*"}$' out || fail "--version --json: $(cat out)"

# 3. alc check --json on a clean file outputs []
printf 'fn main() {\n    print(1)\n}\n' > clean.al
"$ALC" check --json clean.al >out 2>err; [[ $? == 0 ]] || fail "clean check: status"
[[ $(cat out) == "[]" && ! -s err ]] || fail "clean check --json: out=$(cat out) err=$(cat err)"

# 4. alc sigs: no __* leaks, --std, --pub, --filter, --json
"$ALC" sigs clean.al --std >out 2>err; [[ $? == 0 ]] || fail "sigs --std: status"
grep -q ' __' out && fail "sigs --std leaked internal __* declarations: $(grep ' __' out | head -n 3)"

printf 'priv fn hidden_fn() {}\n// public doc\nfn public_helper(x: i64) -> i64 { x }\nfn main() {}\n' > sigs_t.al
"$ALC" sigs --pub sigs_t.al >out 2>err; [[ $? == 0 ]] || fail "sigs --pub: status"
grep -q 'hidden_fn' out && fail "sigs --pub showed priv fn"
grep -q 'public_helper' out || fail "sigs --pub missing public_helper"
"$ALC" sigs --filter helper --json sigs_t.al >out 2>err; [[ $? == 0 ]] || fail "sigs --json: status"
grep -q '"kind":"fn","name":"public_helper","priv":false' out || fail "sigs --json: $(cat out)"
grep -q '"doc":"public doc"' out || fail "sigs --json doc: $(cat out)"

# 5. alc test --filter and --json
cat > t_unit.al <<'EOF'
test "alpha_one" {
    assert 1 + 1 == 2
}
test "beta_two" {
    assert 2 + 2 == 4
}
EOF
"$ALC" test --filter alpha --json t_unit.al -o t_unit.bin >out 2>err; [[ $? == 0 ]] || fail "test --json: status $(cat out err)"
grep -q '{"passed":1,"failed":0,"skipped":1,"tests":\[{"name":"alpha_one","ok":true,"ms":' out || fail "test --json: $(cat out)"

# 6. alc fmt --json usage error emits JSON with status 2
"$ALC" fmt --json --badflag clean.al >out 2>err; [[ $? == 2 ]] || fail "fmt --json badflag: status"
grep -q '"message":"unknown option --badflag"' out || fail "fmt --json badflag: $(cat out)"

# 7. Fuzzy "did you mean?" suggestions
cat > typo_mod.al <<'EOF'
use std.imge
fn main() {}
EOF
"$ALC" check typo_mod.al >out 2>err; [[ $? == 1 ]] || fail "typo_mod: status"
grep -q 'did you mean `image`' err || fail "typo_mod hint: $(cat err)"

cat > typos.al <<'EOF'
struct Widget { count: i64, label: str }
fn compute_total(x: i64) -> i64 { x + 1 }
fn main() {
    w := Widget{cuont: 1, label: "a"}
    _ = w.labl
    counter := 10
    _ = cuonter
    cuonter = 20
    _ = compute_totla(counter)
    z: Widgt
    _ = z
}
EOF
"$ALC" check typos.al >out 2>err; [[ $? == 1 ]] || fail "typos: status"
grep -q 'did you mean `count`' err || fail "struct lit field hint: $(cat err)"
grep -q 'did you mean `label`' err || fail "field access hint: $(cat err)"
grep -q 'did you mean `counter`' err || fail "local ident/var hint: $(cat err)"
grep -q 'did you mean `compute_total`' err || fail "fn call hint: $(cat err)"
grep -q 'did you mean `Widget`' err || fail "type hint: $(cat err)"

# 8. -W / --warn and --deny-warnings + --json severity
cat > warns.al <<'EOF'
enum Color { Red, Green, Blue }
fn f(c: Color) -> i64 {
    unused_val := 42
    _ignored := 99
    x := 1
    x = x
    match c {
        Red => print("r")
    }
    return x
    print("never")
}
fn main() {
    print(f(Red))
}
EOF
"$ALC" check warns.al >out 2>err; [[ $? == 0 && ! -s err ]] || fail "without -W should be quiet: $(cat err)"
"$ALC" check -W warns.al >out 2>err; [[ $? == 0 ]] || fail "-W should exit 0: $(cat err)"
grep -q 'warning: unused variable `unused_val`' err || fail "-W unused: $(cat err)"
grep -q '_ignored' err && fail "-W flagged _ignored: $(cat err)"
grep -q 'warning: self-assignment `x = x`' err || fail "-W self-assign: $(cat err)"
grep -q 'warning: non-exhaustive `match` statement' err || fail "-W match: $(cat err)"
grep -q 'warning: unreachable statement' err || fail "-W unreachable: $(cat err)"
"$ALC" check --deny-warnings warns.al >out 2>err; [[ $? == 1 ]] || fail "--deny-warnings should exit 1"
"$ALC" check -W --json warns.al >out 2>err; [[ $? == 0 ]] || fail "-W --json: status"
grep -q '"severity":"warning"' out || fail "-W --json severity: $(cat out)"

# 9. Upgraded lint_copy_writes: nested struct, array, tuple, and no false positive on Ptr/Slice/shadow
cat > copy_bad.al <<'EOF'
struct Inner { b: i64 }
struct Outer { inner: Inner, arr: [2]i64, pair: (i64, i64) }
fn main() {
    o := Outer{}
    c := o.inner
    c.b = 1
    a := o.arr
    a[0] = 2
    p := o.pair
    p.0 = 3
}
EOF
"$ALC" check copy_bad.al >out 2>err; [[ $? == 1 ]] || fail "copy_bad: status"
grep -q '`c` is a copy of `o.inner`' err || fail "copy_bad struct: $(cat err)"
grep -q '`a` is a copy of `o.arr`' err || fail "copy_bad array: $(cat err)"
grep -q '`p` is a copy of `o.pair`' err || fail "copy_bad tuple: $(cat err)"

cat > copy_ok.al <<'EOF'
struct Inner { x: i64 }
struct Holder { p: *Inner, xs: []i64, inner: Inner }
fn main() {
    inn := Inner{x: 1}
    buf := []i64{10, 20}
    h := Holder{p: &inn, xs: buf, inner: inn}
    // writing through shared Ptr or Slice field mutates the original: MUST NOT error
    c1 := h
    c1.p.x = 5
    c2 := h
    c2.xs[0] = 9
    // shadowed inner variable: MUST NOT error
    v := h.inner
    if true {
        v := Inner{x: 0}
        v.x = 2
        print(v.x)
    }
    print(v.x)
}
EOF
"$ALC" check copy_ok.al >out 2>err; [[ $? == 0 ]] || fail "copy_ok false positive: $(cat err)"

exit 0

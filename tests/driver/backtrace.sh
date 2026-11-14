# stack traces of panics: ALC_BACKTRACE=0 turns them off; `alc test` shows the trace of a
# failing test (named `test "name"`); a corrupted stack ends the trace without a second fault
set -u
ALC=$1; D=$2; cd "$D" || exit 1
fail() { echo "FAIL: $*"; exit 1; }
cat > p.al <<'AL'
fn inner(x: i64) -> i64 {
    assert x > 0, "not positive"
    return x
}
fn main() { print(inner(len(args()) - 1)) }
test "inner fails" { assert inner(0) == 0 }
test "inner works" { assert inner(2) == 2 }
AL
"$ALC" build p.al -o p || fail "build"
./p 2>err; [[ $? == 1 ]] || fail "status"
grep -q '^  at p.al:2 in inner$' err || fail "frame inner"
grep -q '^  at p.al:5 in main$' err || fail "frame main"
[[ $(wc -l <err) == 3 ]] || fail "library frames shown: $(cat err)"
ALC_BACKTRACE=0 ./p 2>err; [[ $? == 1 ]] || fail "status without trace"
grep -q 'assertion failed at p.al:2: not positive' err || fail "message without trace"
grep -q '  at ' err && fail "ALC_BACKTRACE=0 still prints frames"
ALC_BACKTRACE=1 ./p 2>err; grep -q '^  at p.al:2 in inner$' err || fail "ALC_BACKTRACE=1"
"$ALC" test p.al -o p.test >out 2>err; [[ $? == 1 ]] || fail "test status"
grep -q '^FAIL inner fails$' out || fail "test result"
grep -q '^  at p.al:2 in inner$' err || fail "test frame inner"
grep -q '^  at p.al:6 in test "inner fails"$' err || fail "test frame of the test block: $(cat err)"
[[ $(grep -c '  at ' err) == 2 ]] || fail "test runner frames shown: $(cat err)"
# a smashed stack: no fault inside the walk
cat > s.al <<'AL'
noinline fn smash(fill: i64) {
    x: [2]i64
    p := ptr(x)
    for i in 0..40 { p[i] = fill + 3 * i }
    panic("smashed")
}
noinline fn level(fill: i64) -> i64 {
    pad: [64]i64
    pad[fill & 63] = 1
    smash(fill)
    return pad[3]
}
fn main() { print(level(cast[i64](smash) + len(args()))) }
AL
for o in -O0 ""; do
  "$ALC" build $o s.al -o s || fail "build s"
  timeout 10 ./s 2>err; [[ $? == 1 ]] || fail "smashed status"
  grep -q 'stopped at a fault' err && fail "the walk faulted: $(cat err)"
  grep -q 'panic at s.al:5: smashed' err || fail "smashed message"
done
exit 0

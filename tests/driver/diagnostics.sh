# no "missing fn main" when main was only lost to a syntax error; one "too deep" error per
# declaration; --json keeps the diagnostics on stdout
set -u
ALC=$1; D=$2; cd "$D" || exit 1
fail() { echo "FAIL: $*"; exit 1; }
printf 'fn main() { x := `abc\n' > a.al
"$ALC" check a.al 2>err; [[ $? == 1 ]] || fail "status"
grep -q "unterminated raw string" err || fail "raw string error"
grep -q "missing `fn main" err && fail "missing main reported after a syntax error"
printf 'fn f() {}\n' > b.al
"$ALC" check b.al 2>err; grep -q "missing \`fn main" err || fail "missing main not reported"
"$ALC" check b.al --json >out 2>err; grep -q '"line":1,"col":1,"message":"missing' out || fail "json"
exit 0

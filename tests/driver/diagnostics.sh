# no "missing fn main" when main was only lost to a syntax error; --json keeps the diagnostics
# on stdout
set -u
ALC=$1; D=$2; cd "$D" || exit 1
fail() { echo "FAIL: $*"; exit 1; }
printf 'fn main() { x := `abc\n' > a.al
"$ALC" check a.al 2>err; [[ $? == 1 ]] || fail "status"
grep -q "unterminated raw string" err || fail "raw string error"
grep -q 'missing `fn main' err && fail "missing main reported after a syntax error"
printf 'fn f() {}\n' > b.al
"$ALC" check b.al 2>err; grep -q "missing \`fn main" err || fail "missing main not reported"
"$ALC" check b.al --json >out 2>err; grep -q '"line":1,"col":1,"message":"missing' out || fail "json"
# every driver error is JSON with --json: unreadable input, command line, output path
"$ALC" check nosuch.al --json >out 2>err; [[ $? == 1 ]] || fail "json missing: status"
grep -q '^\[{"file":"nosuch.al","line":0,"col":0,"message":"cannot read' out || fail "json missing file"
[[ -s err ]] && fail "json missing file: stderr"
"$ALC" frob x.al --json >out 2>err; [[ $? == 2 ]] || fail "json usage: status"
grep -q '"message":"unknown command frob"' out || fail "json usage"
printf 'fn main() {}\n' > m.al
"$ALC" build m.al --json -o /nonexistent/x >out 2>err; [[ $? == 1 ]] || fail "json write: status"
grep -q '"message":"cannot write' out || fail "json write"
"$ALC" build m.al -o --json >out 2>err || fail "-o --json is a path"
[[ -x ./--json ]] || fail "-o --json output"
exit 0

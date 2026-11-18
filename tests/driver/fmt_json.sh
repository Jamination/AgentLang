# `alc fmt --json`: one JSON array on standard output for all files (syntax errors, unreadable
# files, and with --check the first line that would change); nothing when all is well
set -u
ALC=$1; D=$2; cd "$D" || exit 1
fail() { echo "FAIL: $1"; exit 1; }
printf 'fn main() {\n    print(1)\n}\n' > good.al
printf 'fn main() {\n  print(1)\n}\n' > bad.al
printf 'fn main() {\n    print(1\n}\n' > err.al
"$ALC" fmt --check --json good.al >out 2>err; [[ $? == 0 ]] || fail "good: status"
[[ -s out || -s err ]] && fail "good: output $(cat out err)"
"$ALC" fmt --check --json good.al bad.al err.al nosuch.al >out 2>err; [[ $? == 1 ]] || fail "check: status"
[[ -s err ]] && fail "check: stderr $(cat err)"
grep -q '^\[{"file":"bad.al","line":2,"col":1,"message":"not in the canonical layout' out || fail "check: bad.al: $(cat out)"
grep -q '{"file":"err.al","line":3,"col":1,"message":"expected' out || fail "check: err.al: $(cat out)"
grep -q '{"file":"nosuch.al","line":0,"col":0,"message":"cannot read' out || fail "check: nosuch.al: $(cat out)"
[[ $(wc -l <out) == 1 ]] || fail "check: one line: $(cat out)"
cmp -s bad.al <(printf 'fn main() {\n  print(1)\n}\n') || fail "check changed bad.al"
# in place: the file is rewritten, nothing is printed
"$ALC" fmt --json bad.al >out 2>err; [[ $? == 0 && ! -s out ]] || fail "in place: $(cat out err)"
cmp -s bad.al good.al || fail "in place: bad.al not formatted"
"$ALC" fmt --json --stdout good.al >out 2>err; [[ $? == 2 ]] || fail "--json --stdout: status"
exit 0

# -o must never replace a source file of the program (also through a link); a binary input is
# one error, not one per byte
set -u
ALC=$1; D=$2; cd "$D" || exit 1
fail() { echo "FAIL: $*"; exit 1; }
printf 'use "lib.al"\nfn main() -> i64 { lib() }\n' > main.al
printf 'fn lib() -> i64 { 3 }\n' > lib.al
cp main.al main.orig
"$ALC" build main.al -o main.al 2>err; [[ $? == 1 ]] || fail "-o main.al: exit status"
grep -q "is the source file" err || fail "-o main.al: message"; cmp -s main.al main.orig || fail "main.al was replaced"
"$ALC" build main.al -o lib.al 2>err; [[ $? == 1 ]] || fail "-o lib.al: exit status"
ln -s main.al link.al
"$ALC" build main.al -o link.al 2>err; [[ $? == 1 ]] || fail "-o link.al: exit status"
cmp -s main.al main.orig || fail "main.al was replaced through a link"
"$ALC" build main.al -o prog || fail "build"
./prog; [[ $? == 3 ]] || fail "prog status"
"$ALC" check prog 2>err; [[ $? == 1 ]] || fail "binary input: exit status"
grep -q "contains NUL bytes" err || fail "binary input: message"
[[ $(wc -l <err) == 1 ]] || fail "binary input: one line"
"$ALC" build main.al -o /nonexistent/dir/x 2>err; [[ $? == 1 ]] || fail "unwritable: status"
grep -q "cannot write" err || fail "unwritable: message"
"$ALC" build 2>/dev/null; [[ $? == 2 ]] || fail "usage status"
exit 0

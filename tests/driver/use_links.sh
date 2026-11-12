# a file is included once, recognised by its identity: a hard link of an included file is the
# same file; a path through a symbolic link and `..` names the file it really reaches
set -u
ALC=$1; D=$2; cd "$D" || exit 1
fail() { echo "FAIL: $*"; exit 1; }
mkdir -p real/deep top
ln -s ../real/deep top/link
printf 'fn from_real() -> i64 { 1 }\n' > real/x.al
printf 'fn from_top() -> i64 { 2 }\n' > top/x.al
ln real/x.al hard.al
# top/link/../x.al is real/x.al (the kernel resolves the link before ..), not top/x.al
printf 'use "top/link/../x.al"\nuse "top/x.al"\nuse "hard.al"\nuse "./real/../real/x.al"\nfn main() { print(from_real(), from_top()) }\n' > main.al
out=$("$ALC" run main.al) || fail "does not compile: $out"
[[ "$out" == "1 2" ]] || fail "output $out"
exit 0

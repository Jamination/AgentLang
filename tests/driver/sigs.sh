# `alc sigs`: C functions and variables are shown with `extern "lib"`, private ones with `priv`
set -u
ALC=$1; D=$2; cd "$D" || exit 1
printf 'extern "libc.so.6" fn getpid() -> i32\nextern "libc.so.6" environ: **u8\npriv fn f(a: [4]i64) -> i64 { a[0] }\nfn main() {}\n' > s.al
"$ALC" sigs s.al >out || { echo "FAIL: sigs"; exit 1; }
printf 's.al:1: extern "libc.so.6" fn getpid() -> i32\ns.al:2: extern "libc.so.6" environ: **u8\ns.al:3: priv fn f(a: [4]i64) -> i64\ns.al:4: fn main()\n' >exp
diff exp out || { echo "FAIL: sigs output"; exit 1; }
printf 'const N = 4\nfn f(a: [N + 1]i64, b: [(N - 1) * 2]u8, c: [N - (2 - 1)]i64, d: [sizeof[i64]() << 1]u8) {}\nfn main() {}\n' > a.al
"$ALC" sigs a.al | grep -qF 'fn f(a: [N + 1]i64, b: [(N - 1) * 2]u8, c: [N - (2 - 1)]i64, d: [sizeof[i64]() << 1]u8)' || { echo "FAIL: array lengths"; exit 1; }
# the first line of a declaration's leading comment (after a heading), else of the comment after it
printf '// the first line\n// the second line\nfn g() {}\nconst K = 1 // after\n// ---- heading ----\n// doc\nfn h() {}\n\n// a comment that leads nothing\n\nfn main() {}\n' > d.al
"$ALC" sigs d.al >out || { echo "FAIL: sigs d.al"; exit 1; }
printf 'd.al:3: fn g()  // the first line\nd.al:4: const K = ...  // after\nd.al:7: fn h()  // doc\nd.al:11: fn main()\n' >exp
diff exp out || { echo "FAIL: sigs comments"; exit 1; }
exit 0

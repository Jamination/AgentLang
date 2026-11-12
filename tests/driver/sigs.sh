# `alc sigs`: C functions and variables are shown with `extern "lib"`, private ones with `priv`
set -u
ALC=$1; D=$2; cd "$D" || exit 1
printf 'extern "libc.so.6" fn getpid() -> i32\nextern "libc.so.6" environ: **u8\npriv fn f(a: [4]i64) -> i64 { a[0] }\nfn main() {}\n' > s.al
"$ALC" sigs s.al >out || { echo "FAIL: sigs"; exit 1; }
printf 's.al:1: extern "libc.so.6" fn getpid() -> i32\ns.al:2: extern "libc.so.6" environ: **u8\ns.al:3: priv fn f(a: [4]i64) -> i64\ns.al:4: fn main()\n' >exp
diff exp out || { echo "FAIL: sigs output"; exit 1; }

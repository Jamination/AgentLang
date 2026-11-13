# --target: the option, the name and format of a Windows executable, `alc run` without Wine,
# Linux libraries and system calls in a Windows build. (A minimal run-time library through
# ALC_PRELUDE keeps this independent of the real one; nothing is run under Wine here.)
set -u
ALC=$1; D=$2; cd "$D" || exit 1
fail() { echo "FAIL: $*"; exit 1; }
cat > pre.al <<'EOF'
extern "kernel32.dll" fn ExitProcess(code: u32) -> never
fn __rt_init(sp: i64) {}
fn exit(code: i64) -> never { ExitProcess(u32(code)) }
EOF
export ALC_PRELUDE=$PWD/pre.al
printf 'fn main() -> i64 { 3 }\n' > prog.al
"$ALC" build --target windows prog.al || fail "build"
[[ -f prog.exe ]] || fail "default name prog.exe"
[[ $(head -c 2 prog.exe) == MZ ]] || fail "MZ header"
od -A d -t x1 -j 64 -N 6 prog.exe | grep -q "50 45 00 00 64 86" || fail "PE signature and machine x86-64"
env -u ALC_PRELUDE "$ALC" build --target linux prog.al -o lin || fail "--target linux"
[[ $(head -c 4 lin) == $'\x7fELF' ]] || fail "--target linux makes ELF"
env -u ALC_WINE "$ALC" run --target windows prog.al 2>err; [[ $? == 1 ]] || fail "run without Wine: status"
grep -q "cannot run here (ALC_WINE=1" err || fail "run without Wine: message"
[[ -f prog.exe ]] || fail "run builds the executable"
"$ALC" build --target macos prog.al 2>err; [[ $? == 2 ]] || fail "unknown target: status"
grep -q "unknown target macos" err || fail "unknown target: message"
"$ALC" build prog.al --target 2>err; [[ $? == 2 ]] || fail "missing target: status"
printf 'extern "libc.so.6" fn getpid() -> i32\nfn main() -> i64 { i64(getpid()) }\n' > lin.al
"$ALC" build --target windows lin.al 2>err; [[ $? == 1 ]] || fail "Linux library: status"
grep -q "is imported from \`libc.so.6\`, which is not a Windows library" err || fail "Linux library: message"
printf 'extern "kernel32.dll" fn GetTickCount() -> u32\nfn main() -> i64 { i64(GetTickCount()) }\n' > win.al
unset ALC_PRELUDE
"$ALC" build win.al -o win 2>err; [[ $? == 1 ]] || fail "DLL in a Linux build: status"
grep -q "a Windows library: build with --target windows" err || fail "DLL in a Linux build: message"
export ALC_PRELUDE=$PWD/pre.al
printf 'fn main() -> i64 { syscall(39) }\n' > sys.al
"$ALC" build --target windows sys.al 2>err; [[ $? == 1 ]] || fail "syscall: status"
grep -q "Linux system call" err || fail "syscall: message"
exit 0

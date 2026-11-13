# `when`, -D, `if` on constants and `alc check --all-targets` on the command line: code and
# data of a branch that is not taken are not in the executable at any optimisation level
set -u
ALC=$1; D=$2; cd "$D" || exit 1
fail() { echo "FAIL: $*"; exit 1; }
cat > dead.al <<'EOF'
const DEBUG = false
when DEBUG {
    fn dump() { print("MARKER_WHEN_DECL") }
}
fn only_debug() { print("MARKER_ONLY_CALLED_FROM_DEAD_CODE") }
fn main() {
    if DEBUG {
        print("MARKER_IF_THEN")
        only_debug()
    }
    when DEBUG {
        print("MARKER_WHEN_STMT")
        dump()
    }
    if !DEBUG && TARGET_OS == Linux {
        print("live")
    } else {
        print("MARKER_IF_ELSE")
    }
    print("LIVE_STRING")
}
EOF
for mode in -O0 ""; do
  "$ALC" build $mode dead.al -o dead || fail "build $mode"
  [[ $(./dead) == $'live\nLIVE_STRING' ]] || fail "output $mode"
  grep -q LIVE_STRING dead || fail "the live string is missing ($mode)"
  grep -q MARKER_ dead && fail "dead code or data left in the executable ($mode): $(grep -ao 'MARKER_[A-Z_]*' dead | sort -u | tr '\n' ' ')"
  grep -q only_debug dead && fail "a function called only from dead code is in the executable ($mode)"
  # with -D DEBUG the same code is there
  "$ALC" build $mode -D DEBUG dead.al -o dead_d || fail "build -D DEBUG $mode"
  for m in MARKER_WHEN_DECL MARKER_IF_THEN MARKER_ONLY_CALLED_FROM_DEAD_CODE MARKER_WHEN_STMT; do
    grep -q $m dead_d || fail "-D DEBUG: $m missing ($mode)"
  done
done
# ALC_DISABLE=constif,deaddata: the dead branch stays (the comparison for the corpus)
ALC_DISABLE=constif,deaddata "$ALC" build -O0 dead.al -o dead_k || fail "build with ALC_DISABLE"
grep -q MARKER_IF_THEN dead_k || fail "ALC_DISABLE=constif,deaddata removes the branch"
# --all-targets: every target checked; an error of one target names it
cat > plat.al <<'EOF'
when TARGET_OS == Windows {
    fn sep() -> str { 1 }
} else {
    fn sep() -> str { "/" }
}
fn main() { print(sep()) }
EOF
"$ALC" check plat.al 2>err || fail "plat.al: Linux check"
"$ALC" check --all-targets plat.al 2>err; [[ $? == 1 ]] || fail "--all-targets: status"
grep -q 'plat.al:2:25: error: type mismatch: expected str, found i64 (--target windows)' err || fail "--all-targets: $(cat err)"
grep -q 'error(s)' err || fail "--all-targets: count"
"$ALC" check --all-targets --json plat.al >out 2>err; grep -q '"line":2,"col":25,"message":"type mismatch.*(--target windows)"' out || fail "--all-targets --json: $(cat out)"
"$ALC" build --all-targets plat.al 2>err; [[ $? == 2 ]] || fail "--all-targets with build: status"
"$ALC" check --all-targets --target linux plat.al 2>err; [[ $? == 2 ]] || fail "--all-targets with --target: status"
printf 'fn main() {}\n' > ok.al
"$ALC" check --all-targets ok.al || fail "--all-targets of a correct program"
# -D on the command line
"$ALC" check -D 1x ok.al 2>err; [[ $? == 2 ]] || fail "-D 1x: status"
grep -q -- '-D needs the name of a constant' err || fail "-D 1x: message"
"$ALC" check -D A=1 -D A=2 ok.al 2>err; [[ $? == 2 ]] || fail "-D twice: status"
"$ALC" check -D ok.al 2>err; [[ $? == 2 ]] || fail "-D followed by the file: the file is taken as the name"
printf 'const N = 1\nfn main() { print(N) }\n' > n.al
[[ $("$ALC" run -DN=42 n.al) == 42 ]] || fail "-DNAME=VALUE in one word"
# sigs: the declarations of the taken branches only
"$ALC" sigs plat.al >out || fail "sigs"
[[ $(grep -c 'fn sep' out) == 1 ]] && grep -q 'plat.al:4: fn sep() -> str' out || fail "sigs: $(cat out)"
exit 0

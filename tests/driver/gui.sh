# --gui: a Windows executable with the GUI subsystem (2) instead of the console one (3); an
# error for a Linux executable. What a GUI program does at run time (no standard handles,
# attaching to a console, panics) is tested under Wine by tests/winabi/run.sh.
set -u
ALC=$1; D=$2; cd "$D" || exit 1
fail() { echo "FAIL: $*"; exit 1; }
# the 2-byte Subsystem field: 92 bytes after the PE signature, whose offset is at 0x3C
subsystem() {
  local pe
  pe=$(od -A n -t u4 -j 60 -N 4 "$1" | tr -d ' ')
  od -A n -t u2 -j $((pe + 92)) -N 2 "$1" | tr -d ' '
}
printf 'fn main() { print("hello") }\n' > prog.al
"$ALC" build --target windows prog.al -o con.exe || fail "console build"
[[ $(subsystem con.exe) == 3 ]] || fail "console subsystem: $(subsystem con.exe)"
"$ALC" build --target windows --gui prog.al -o gui.exe || fail "--gui build"
[[ $(subsystem gui.exe) == 2 ]] || fail "--gui subsystem: $(subsystem gui.exe)"
cmp -s con.exe gui.exe && fail "--gui changes nothing"
# the rest of the file is the same: only the subsystem field differs
[[ $(cmp -l con.exe gui.exe | wc -l) == 1 ]] || fail "--gui changes more than the subsystem"
"$ALC" build --target linux --gui prog.al -o lin 2>err; [[ $? == 2 ]] || fail "--gui for Linux: status"
grep -q -- "--gui is for Windows executables: add --target windows" err || fail "--gui for Linux: message"
[[ -e lin ]] && fail "--gui for Linux: an executable was written"
exit 0

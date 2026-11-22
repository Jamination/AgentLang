# The Windows executable as a file (nothing runs under Wine here; tests/pe/run.sh does that):
# it is relocatable (ASLR flags, a base above 4 GiB, a base relocation table that lists every
# absolute address: tests/pe/check.py relocates a build for one base and compares it with a
# build for another), and it holds its resources: the manifest always, the icon of --icon and
# the version information of --version-info, with errors for bad input.
set -u
REPO=$(cd "$(dirname "$0")/../.." && pwd)
ALC=$1; D=$2; cd "$D" || exit 1
fail() { echo "FAIL: $*"; exit 1; }
CHECK="python3 $REPO/tests/pe/check.py"
cat > prog.al <<'EOF'
struct Named { name: str, f: fn(i64) -> i64 }
fn twice(x: i64) -> i64 { 2 * x }
fn square(x: i64) -> i64 { x * x }
const TABLE = [2]Named{Named{"twice", twice}, Named{"square", square}}
words := [3]str{"alpha", "beta", "gamma"}
scale := [4]f64{0.5, 1.5, 2.5, 3.5}
total: i64
fn main() {
    for t in TABLE { total += t.f(7); print(t.name, t.f(7)) }
    x: f64 = 0
    for i, w in words { x += scale[i] * f64(len(w)); print(w, scale[i % 4] * 1.25) }
    print(x, total)
}
EOF
# ---- the header ----
"$ALC" build --target windows prog.al -o a.exe || fail "build"
$CHECK headers a.exe > headers || fail "headers: $(cat headers)"
cat > want <<'EOF'
base 0x140000000
characteristics 0x0022
dll-characteristics HIGH_ENTROPY_VA DYNAMIC_BASE NX_COMPAT TERMINAL_SERVER_AWARE
subsystem 3
sections .text .rdata .pdata .idata .data .rsrc .reloc
EOF
diff want <(head -5 headers) || fail "header fields"
grep -qx "relocations [1-9][0-9]*" headers || fail "no relocations: $(tail -1 headers)"
# ---- the relocation table: the same program built for another base ----
for src in prog.al "$REPO/examples/dx12_starter/game.al" "$REPO/examples/starter/game.al" "$REPO/src/main.al"; do
  for mode in "" -O0 --unchecked; do
    [[ $src == */main.al && -n $mode ]] && continue
    "$ALC" build --target windows $mode "$src" -o a.exe || fail "build $src $mode"
    ALC_PE_BASE=7FF6A1230000 "$ALC" build --target windows $mode "$src" -o b.exe || fail "build $src $mode for another base"
    $CHECK reloc a.exe b.exe > out || fail "relocation of $src $mode: $(cat out)"
  done
done
ALC_PE_BASE=140001000 "$ALC" build --target windows prog.al -o c.exe 2>err; [[ $? == 1 ]] || fail "bad ALC_PE_BASE: status"
grep -q "ALC_PE_BASE is not an image base" err || fail "bad ALC_PE_BASE: message"
# ---- resources ----
"$ALC" build --target windows prog.al -o a.exe || fail "build"
$CHECK rsrc a.exe > out || fail "resources of a plain build: $(cat out)"
[[ $(head -1 out) == "manifest 1:" ]] || fail "a plain build has resources other than the manifest"
for want in 'level="asInvoker"' '<supportedOS Id="{8e0f7a12-bfb3-4fe8-b9a5-48fd50a15a9a}"/>' \
    '>PerMonitorV2, system</dpiAwareness>' '>true</dpiAware>' '>true</longPathAware>' '>UTF-8</activeCodePage>'; do
  grep -qF -- "$want" out || fail "manifest lacks $want"
done
# (the manifest is well-formed XML)
sed 1d out | python3 -c 'import sys, xml.dom.minidom; xml.dom.minidom.parseString(sys.stdin.read())' || fail "manifest is not XML"
python3 "$REPO/tests/pe/mkico.py" app.ico || fail "mkico"
"$ALC" build --target windows --gui --icon app.ico --version-info "FileDescription=A test game" \
    --version-info ProductName=Game --version-info "CompanyName=Example Ltd" --version-info FileVersion=1.2.3 \
    --version-info "LegalCopyright=© 2026 Example Ltd" prog.al -o full.exe || fail "build with resources"
$CHECK rsrc full.exe > out || fail "resources: $(cat out)"
cat > want <<'EOF'
icon 1: 1128 bytes, bitmap 16x16 32 bits, crc 979cd72d
icon 2: 4264 bytes, bitmap 32x32 32 bits, crc 1d04585c
icon 3: 9640 bytes, bitmap 48x48 32 bits, crc 909c8edb
icon 4: 262488 bytes, png 256x256, crc ef37e61d
group-icon 1: 4 image(s)
  16x16 32 bits -> icon 1
  32x32 32 bits -> icon 2
  48x48 32 bits -> icon 3
  256x256 32 bits -> icon 4
version 1:
  fixed: file 1.2.3.0 product 1.2.3.0 flags 0x0/0x3f os 0x40004 type 1
  table 040904B0
  FileDescription=A test game
  ProductName=Game
  CompanyName=Example Ltd
  FileVersion=1.2.3
  LegalCopyright=© 2026 Example Ltd
  ProductVersion=1.2.3
  translation: language 0x0409 code page 1200
manifest 1:
EOF
diff want <(head -20 out) || fail "icon and version resources"
# the icons are the images of the file, byte for byte
python3 - <<'EOF' || fail "icon images differ from the file"
import struct, subprocess, sys, zlib
f = open("app.ico", "rb").read()
n = struct.unpack_from("<H", f, 4)[0]
want = []
for k in range(n):
    size, at = struct.unpack_from("<II", f, 6 + 16 * k + 8)
    want.append("%08x" % zlib.crc32(f[at:at + size]))
got = [l.split()[-1] for l in open("out") if l.startswith("icon ")]
sys.exit(0 if got == want else 1)
EOF
# a file that leaves planes and bits per pixel 0: both are taken from the images
python3 "$REPO/tests/pe/mkico.py" zero.ico --zero-depth || fail "mkico"
"$ALC" build --target windows --icon zero.ico prog.al -o zero.exe || fail "build with zero.ico"
$CHECK rsrc zero.exe > out0 || fail "resources (zero depth): $(cat out0)"
diff <(head -9 want) <(head -9 out0) || fail "icon group of a file without depths"
# ProductVersion given: FileVersion does not replace it; four parts
"$ALC" build --target windows --version-info FileVersion=1.2.3.4 --version-info ProductVersion=7 prog.al -o v.exe || fail "build with versions"
$CHECK rsrc v.exe | grep -qx "  fixed: file 1.2.3.4 product 7.0.0.0 flags 0x0/0x3f os 0x40004 type 1" || fail "version numbers"
# with resources the image still relocates
ALC_PE_BASE=7FF6A1230000 "$ALC" build --target windows --gui --icon app.ico --version-info FileVersion=1.2.3 prog.al -o b.exe || fail "build"
"$ALC" build --target windows --gui --icon app.ico --version-info FileVersion=1.2.3 prog.al -o a.exe || fail "build"
$CHECK reloc a.exe b.exe > out || fail "relocation with resources: $(cat out)"
# the output depends on the input only
"$ALC" build --target windows --gui --icon app.ico --version-info FileVersion=1.2.3 prog.al -o a2.exe && cmp -s a.exe a2.exe || fail "two builds differ"
# ---- errors ----
# usage: status 2 and the message; nothing is written
bad_usage() {
  local msg=$1; shift
  rm -f x.exe
  "$ALC" build "$@" prog.al -o x.exe 2>err; [[ $? == 2 ]] || fail "$*: status"
  grep -qF -- "$msg" err || fail "$*: message: $(head -1 err)"
  [[ -e x.exe ]] && fail "$*: an executable was written"
}
bad_usage "--icon is for Windows executables: add --target windows" --target linux --icon app.ico
bad_usage "--version-info is for Windows executables: add --target windows" --target linux --version-info FileVersion=1
bad_usage "--version-info needs NAME=VALUE, not FileVersion" --target windows --version-info FileVersion
bad_usage "--version-info: unknown name Version (one of Comments, CompanyName, FileDescription, FileVersion, InternalName, LegalCopyright, LegalTrademarks, OriginalFilename, PrivateBuild, ProductName, ProductVersion, SpecialBuild)" --target windows --version-info Version=1
bad_usage "--version-info: FileVersion is up to four numbers below 65536 with dots between them (1.2.3), not 1.2-beta" --target windows --version-info FileVersion=1.2-beta
bad_usage "--version-info: FileVersion is up to four numbers" --target windows --version-info FileVersion=1.2.3.4.5
bad_usage "--version-info: ProductVersion is up to four numbers" --target windows --version-info ProductVersion=70000
bad_usage "--version-info: ProductName is given twice" --target windows --version-info ProductName=a --version-info ProductName=b
"$ALC" build --target windows prog.al --icon 2>err; [[ $? == 2 ]] || fail "--icon without a file: status"
grep -q -- "--icon needs an icon file: --icon app.ico" err || fail "--icon without a file: message"
"$ALC" build --target windows prog.al --version-info 2>err; [[ $? == 2 ]] || fail "--version-info without a value: status"
grep -q -- "--version-info needs NAME=VALUE: --version-info FileVersion=1.2.0" err || fail "--version-info without a value: message"
# a bad file: status 1 and the message; nothing is written
bad_icon() {
  rm -f x.exe
  "$ALC" build --target windows --icon "$1" prog.al -o x.exe 2>err; [[ $? == 1 ]] || fail "icon $1: status"
  grep -qF -- "$2" err || fail "icon $1: message: $(head -1 err)"
  [[ -e x.exe ]] && fail "icon $1: an executable was written"
}
bad_icon missing.ico "error: cannot read \`missing.ico\`: "
printf 'fn main() {}\n' > text.ico
bad_icon text.ico "error: \`text.ico\` is not an icon file (.ico)"
: > empty.ico
bad_icon empty.ico "error: \`empty.ico\` is not an icon file (.ico)"
printf '\0\0\2\0\1\0' > cursor.ico
bad_icon cursor.ico "error: \`cursor.ico\` is not an icon file (.ico)"
printf '\0\0\1\0\0\0' > none.ico
bad_icon none.ico "error: \`none.ico\` holds no image"
head -c 40 app.ico > short.ico
bad_icon short.ico "error: \`short.ico\` is cut off"
head -c 5000 app.ico > cut.ico
bad_icon cut.ico "error: \`cut.ico\` is cut off or damaged (image 2 of 4 is not inside the file)"
python3 -c '
f = bytearray(open("app.ico", "rb").read())
f[70] = 41      # the header size of the first bitmap
open("odd.ico", "wb").write(f)'
bad_icon odd.ico "error: \`odd.ico\` holds an image that is neither a bitmap nor a PNG (image 1 of 4)"
"$ALC" build --json --target windows --icon text.ico prog.al -o x.exe > json; [[ $? == 1 ]] || fail "--json: status"
grep -qF '"message":"`text.ico` is not an icon file (.ico)"' json || fail "--json: $(cat json)"
# `alc check` takes the options (and checks them) without building anything
"$ALC" check --target windows --icon app.ico --version-info FileVersion=1 prog.al || fail "check with resources"
"$ALC" check --target windows --icon text.ico prog.al 2>err; [[ $? == 1 ]] || fail "check with a bad icon"
exit 0

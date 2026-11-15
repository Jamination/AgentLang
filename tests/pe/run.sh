#!/bin/bash
# The Windows executable under Wine: relocation and resources as the loader and the system
# see them (the file itself is checked on Linux by tests/driver/pe.sh).
#   tests/pe/run.sh [path/to/alc]
# - res.al asks Windows where its image was loaded and what the manifest, the icon and the
#   version information are; built plain (res_plain.out) and with --icon / --version-info
#   (res_full.out). Wine (from 9.x) places an image with DYNAMIC_BASE at a random address, as
#   Windows does, so the program, and every program of `tests/run.sh --target windows`, runs
#   relocated: its pointers in global data only work if the base relocations are right. A
#   Wine that loads the image at its preferred base fails the first line of the output.
# - every program of examples/ and bench/ that builds for Windows is built for two image bases
#   and compared after relocation (tests/pe/check.py reloc).
# Wine runs with no display in the prefix $WINEPREFIX (default tmp/win/prefix-pe, created on
# first use, with Wine's null display driver).
cd "$(dirname "$0")/../.." || exit 2
ALC=${1:-./build/alc}
command -v wine >/dev/null || { echo "pe: SKIP: wine is not installed"; exit 0; }
command -v python3 >/dev/null || { echo "pe: SKIP: python3 is not installed"; exit 0; }
export WINEPREFIX=${WINEPREFIX:-$PWD/tmp/win/prefix-pe}
export WINEDEBUG=-all WINEDLLOVERRIDES="mscoree=;mshtml="
unset DISPLAY WAYLAND_DISPLAY
[[ -d $WINEPREFIX ]] || { mkdir -p "$WINEPREFIX" && wineboot -i >/dev/null 2>&1; }
wineserver -p
wine reg add 'HKCU\Software\Wine\Drivers' /v Graphics /d null /f >/dev/null 2>&1
wineserver -k
wineserver -p
wine cmd /c exit >/dev/null 2>&1
TMP=$(mktemp -d)
trap 'wineserver -k 2>/dev/null; rm -rf "$TMP"' EXIT
pass=0; fail=0
python3 tests/pe/mkico.py "$TMP/app.ico" || exit 1
full=(--icon "$TMP/app.ico" --version-info "FileDescription=AL resource test" --version-info ProductName=Starter
  --version-info "CompanyName=Example Ltd" --version-info FileVersion=1.2.3 --version-info "LegalCopyright=(c) 2026 Example Ltd")
for kind in plain full; do
  for mode in "" -O0 --unchecked; do
    label="res $kind [${mode:-default}]"
    opts=()
    [[ $kind == full ]] && opts=("${full[@]}")
    if ! $ALC build --target windows $mode "${opts[@]}" tests/pe/res.al -o "$TMP/res.exe" 2>"$TMP/cerr"; then
      echo "FAIL $label: compile error"; head -5 "$TMP/cerr"; fail=$((fail+1)); continue
    fi
    (cd "$TMP" && timeout 120 wine res.exe >out 2>err); code=$?
    if [[ $code == 0 ]] && diff <(tr -d '\r' <"$TMP/out") tests/pe/res_$kind.out >"$TMP/diff"; then
      pass=$((pass+1))
    else
      echo "FAIL $label: exit code $code"; head -10 "$TMP/diff"; head -5 "$TMP/err"; fail=$((fail+1))
    fi
  done
done
# the base differs from run to run (informative: the lines above already need a moved image)
bases=$(for k in 1 2 3; do (cd "$TMP" && wine res.exe --verbose 2>/dev/null | tr -d '\r' | sed -n 's/^base //p'); done | tr '\n' ' ')
echo "pe: res.exe was loaded at: $bases"
# the relocation table of real programs
n=0
for src in examples/*.al examples/*/*.al bench/*.al; do
  grep -q '^fn main' "$src" || continue
  $ALC build --target windows "$src" -o "$TMP/a.exe" >/dev/null 2>&1 || continue
  n=$((n+1))
  if ALC_PE_BASE=7FF6A1230000 $ALC build --target windows "$src" -o "$TMP/b.exe" >/dev/null 2>&1 &&
     python3 tests/pe/check.py reloc "$TMP/a.exe" "$TMP/b.exe" >"$TMP/out"; then
    pass=$((pass+1))
  else
    echo "FAIL reloc $src"; head -3 "$TMP/out"; fail=$((fail+1))
  fi
done
[[ $n -ge 10 ]] || { echo "FAIL: only $n programs of examples/ and bench/ build for Windows"; fail=$((fail+1)); }
echo "pe: $pass passed, $fail failed"
[[ $fail == 0 ]]

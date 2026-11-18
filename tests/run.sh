#!/bin/bash
# Conformance test runner. The runner itself is the AL program tests/run.al (its top describes
# the tests, the options and the targets); this script builds it with build/alc as
# build/altest when that is missing or older than its source (./build.sh builds it too), and
# starts it in the repository root.
# Usage: tests/run.sh [-j N] [-v] [--target linux|windows [--host-wine path/to/alc.exe]] [path/to/alc] [filter]
# One word alone is the filter unless it names a file: tests/run.sh match. The arguments go to
# the runner unchanged.
# On Windows: tests\run.bat.
cd "$(dirname "$0")/.." || exit 2
if [[ ! -x build/altest || tests/run.al -nt build/altest ]]; then
  if ! ./build/alc build tests/run.al -o build/altest.$$ || ! mv build/altest.$$ build/altest; then
    rm -f build/altest.$$
    echo "tests/run.sh: build/alc cannot build the test runner tests/run.al (./build.sh builds both)"
    exit 2
  fi
fi
# What the runner cannot do when it is interrupted (Ctrl+C) is done here: its directory is
# removed, and the Wine server of a --target windows run is stopped, with the Windows programs
# still running (they are in process groups of their own, which Ctrl+C does not reach).
export ALTEST_TMP
ALTEST_TMP=$(mktemp -d) || exit 2
trap 'rm -rf "$ALTEST_TMP"' EXIT
trap '[[ " $* " == *" --target windows "* ]] && WINEPREFIX=${WINEPREFIX:-$PWD/tmp/win/prefix-tests} wineserver -k; exit 130' INT TERM
build/altest "$@"

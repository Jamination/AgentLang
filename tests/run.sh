#!/bin/bash
# Conformance test runner. The runner itself is the AL program tests/run.al (its top describes
# the tests, the options and the targets); this script builds it with build/alc as
# build/altest when that is missing or older than its source (./build.sh builds it too), and
# starts it in the repository root.
# Usage: tests/run.sh [-j N] [-v] [--target linux|windows [--host-wine path/to/alc.exe]] [path/to/alc] [filter]
# On Windows: tests\run.bat.
cd "$(dirname "$0")/.." || exit 2
if [[ ! -x build/altest || tests/run.al -nt build/altest ]]; then
  if ! ./build/alc build tests/run.al -o build/altest.$$ || ! mv build/altest.$$ build/altest; then
    rm -f build/altest.$$
    echo "tests/run.sh: build/alc cannot build the test runner tests/run.al (./build.sh builds both)"
    exit 2
  fi
fi
exec build/altest "$@"

#!/bin/bash
# Tests of editors/emacs/al-mode.el: it byte-compiles without a warning, its indentation leaves
# the sources that alc fmt laid out (src/, std/) as they are, and Eglot talks to `alc lsp`.
# Usage: editors/emacs/test/run.sh [path/to/alc]   (default: build/alc)
set -u
cd "$(dirname "$0")/../../.." || exit 2
root=$PWD
alc=$(realpath "${1:-build/alc}")
tmp=$(mktemp -d) || exit 2
trap 'rm -rf "$tmp"' EXIT
cp editors/emacs/al-mode.el "$tmp/"
if ! emacs -Q --batch --eval '(setq byte-compile-error-on-warn t)' -f batch-byte-compile "$tmp/al-mode.el"; then
  echo "emacs: FAIL: al-mode.el does not byte-compile cleanly"; exit 1
fi
mkdir "$tmp/work"
if ! emacs -Q --batch -L editors/emacs -l editors/emacs/test/sweep.el -- "$root" "$alc" "$tmp/work"; then
  echo "emacs: FAIL"; exit 1
fi
echo "emacs: ok"

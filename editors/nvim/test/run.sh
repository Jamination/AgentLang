#!/bin/bash
# Tests of editors/nvim: the syntax groups, the indentation (it leaves the sources that
# alc fmt laid out, src/ and std/, as they are), `alc lsp` through Neovim's LSP client,
# :AlFmt and :AlCheck. Needs Neovim 0.11 or newer.
# Usage: editors/nvim/test/run.sh [path/to/alc]   (default: build/alc)
set -u
cd "$(dirname "$0")/../../.." || exit 2
alc=$(realpath "${1:-build/alc}")
tmp=$(mktemp -d) || exit 2
trap 'rm -rf "$tmp"' EXIT
if ! nvim --headless -u NONE -i NONE -n -l editors/nvim/test/run.lua "$PWD" "$alc" "$tmp"; then
  echo "nvim: FAIL"; exit 1
fi
echo "nvim: ok"

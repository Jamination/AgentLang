#!/bin/sh
# Runs the syntax tests (run.vim) under each given Vim or Neovim executable
# (default: vim and nvim from PATH). A name containing "nvim" is run as Neovim.
#   editors/vim/test/syntax/run.sh
#   editors/vim/test/syntax/run.sh "/c/Program Files/Vim/vim92/vim.exe" nvim
# Exit status: 0 when every run passed.
dir=$(cd "$(dirname "$0")" && pwd)
script="$dir/run.vim"
if command -v cygpath >/dev/null 2>&1; then
    # a native Windows Vim does not understand /c/... or /tmp/... paths
    script=$(cygpath -m "$script")
fi
[ $# -eq 0 ] && set -- vim nvim
status=0
for exe in "$@"; do
    log=$(mktemp)
    vlog="$log"
    command -v cygpath >/dev/null 2>&1 && vlog=$(cygpath -m "$log")
    echo "== $exe"
    case "$exe" in
        *nvim*) "$exe" --headless -u NONE -i NONE --cmd "let g:al_test_log='$vlog'" -S "$script" ;;
        *) "$exe" -es -N -u NONE -i NONE --cmd "let g:al_test_log='$vlog'" -S "$script" ;;
    esac
    rc=$?
    if [ -s "$log" ]; then cat "$log"; else echo "no results (did $exe start?)"; rc=1; fi
    [ $rc -ne 0 ] && status=1
    rm -f "$log"
done
exit $status

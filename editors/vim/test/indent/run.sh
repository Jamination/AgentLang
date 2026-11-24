#!/usr/bin/env bash
# Tests of editors/vim (indentation, :AlFmt, compiler) in Vim and Neovim.
#
#   editors/vim/test/indent/run.sh [--vim-only | --nvim-only] [--quick]
#
# Environment: VIM_EXE (default: C:\Program Files\Vim\vim92\vim.exe, else vim), NVIM_EXE
# (default: nvim), ALC (default: build/alc.exe or build/alc), AL_VIM_TEST_DIR (a scratch
# directory; default: a new temporary one). Nothing in the repository is written.
#
# 1. sweep   every .al file of src std examples tools bench tests in the canonical layout
#            (`alc fmt --check`), and the tests/fmt/*.fmt results: indentation destroyed,
#            `gg=G`, must be byte for byte the file (prep.vim, sweep.vim)
# 2. typing  a sample typed line by line in Insert mode (typing.vim)
# 3. hostile 1 and 2 on a subset with sw=1 ts=1 cindent smartindent cino=(0 set globally
# 4. fmt     :AlFmt, format on save, :compiler alc, gf / includeexpr (fmt.vim)
# 5. timing  gg=G on the largest file of src/ (timing.vim)
set -u
here=$(cd "$(dirname "$0")" && pwd)
rt=$(cd "$here/../.." && pwd)
root=$(cd "$rt/../.." && pwd)

run_vim=1
run_nvim=1
quick=0
for a in "$@"; do
    case $a in
        --vim-only) run_nvim=0 ;;
        --nvim-only) run_vim=0 ;;
        --quick) quick=1 ;;
        *) echo "usage: $0 [--vim-only | --nvim-only] [--quick]" >&2; exit 2 ;;
    esac
done

VIM_EXE=${VIM_EXE:-}
if [ -z "$VIM_EXE" ]; then
    if [ -x "/c/Program Files/Vim/vim92/vim.exe" ]; then VIM_EXE="/c/Program Files/Vim/vim92/vim.exe"; else VIM_EXE=vim; fi
fi
NVIM_EXE=${NVIM_EXE:-nvim}
ALC=${ALC:-}
if [ -z "$ALC" ]; then
    if [ -x "$root/build/alc.exe" ]; then ALC="$root/build/alc.exe"; else ALC="$root/build/alc"; fi
fi
work=${AL_VIM_TEST_DIR:-$(mktemp -d)}
mkdir -p "$work"

# paths as the editors want them (C:/... on Windows)
native() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else echo "$1"; fi; }
w_rt=$(native "$rt"); w_root=$(native "$root"); w_work=$(native "$work"); w_alc=$(native "$ALC")
setup=(--cmd "let g:rt = '$w_rt'" --cmd "let g:root = '$w_root'" --cmd "let g:work = '$w_work'" --cmd "let g:alc = '$w_alc'")

# (without $SHELL, as when the editors are started from Windows: Git Bash sets it to bash,
# which gives Vim a shell setup where :make cannot see standard error)
vim_run() {   # vim_run <script> [--cmd ...]...
    local script=$1; shift
    env -u SHELL "$VIM_EXE" -es -N -u NONE -i NONE "${setup[@]}" "$@" -S "$(native "$here/$script")" </dev/null
}
nvim_run() {
    local script=$1; shift
    env -u SHELL "$NVIM_EXE" --headless -u NONE -i NONE "${setup[@]}" "$@" -S "$(native "$here/$script")" </dev/null
}

echo "scratch: $work"
echo "alc: $ALC"

# the files in the canonical layout
cd "$root"
find src std examples tools bench tests -name '*.al' -not -path '*/.*' | sort > "$work/all.txt"
for d in src std examples tools bench tests; do "$ALC" fmt --check "$d" 2>&1; done |
    sed -E -n 's#^([^ :]+\.al)(:[0-9]+:[0-9]+:.*)?$#\1#p' | sort -u > "$work/noncanonical.txt"
grep -v -x -F -f "$work/noncanonical.txt" "$work/all.txt" > "$work/canonical.txt"
for f in tests/fmt/*.fmt; do
    if "$ALC" fmt - < "$f" 2>/dev/null | cmp -s - "$f"; then echo "$f" >> "$work/canonical.txt"; fi
done
echo "files: $(wc -l < "$work/all.txt") .al, $(wc -l < "$work/noncanonical.txt") not canonical or not parsing, $(wc -l < "$work/canonical.txt") checked (with tests/fmt/*.fmt)"

rm -f "$work"/*-vim*.txt "$work"/*-nvim*.txt
vim_run prep.vim
cat "$work/prep-log.txt"

# a sample for the typing test and the hostile runs: small and large files of each kind
sample=tests/fmt/canonical.fmt,tests/fmt/comments.fmt,tests/fmt/continuation.fmt,tests/fmt/layout.fmt,tests/fmt/off.fmt,tests/fmt/crlf_bom.fmt,src/fmt.al,src/lexer.al,src/parser.al,src/lower_match.al,std/os.al,std/image.al,examples/starter/game.al,tools/vk_helpers.al,tests/fmt/tree/check.al
if [ $quick = 1 ]; then pick_sweep="every:10"; else pick_sweep=all; fi

editors=()
[ $run_vim = 1 ] && editors+=(vim)
[ $run_nvim = 1 ] && editors+=(nvim)
for ed in "${editors[@]}"; do
    "${ed}_run" sweep.vim --cmd "let g:pick = '$pick_sweep'"
    "${ed}_run" typing.vim --cmd "let g:pick = '$sample'"
    "${ed}_run" sweep.vim --cmd "let g:pick = 'every:7'" --cmd "let g:hostile = 1"
    "${ed}_run" typing.vim --cmd "let g:pick = 'tests/fmt/layout.fmt,tests/fmt/continuation.fmt,src/fmt.al,std/os.al'" --cmd "let g:hostile = 1"
    "${ed}_run" fmt.vim
    "${ed}_run" fmt.vim --cmd "let g:hostile = 1"
    "${ed}_run" timing.vim
done

status=0
echo
for f in "$work"/sweep-*.txt "$work"/typing-*.txt "$work"/fmt-*.txt "$work"/timing-*.txt; do
    [ -f "$f" ] || continue
    head -1 "$f"
    if grep -q '^FAIL' "$f"; then status=1; sed -n '2,40p' "$f"; fi
done
for ed in "${editors[@]}"; do
    for t in sweep typing fmt timing; do
        [ -f "$work/$t-$ed.txt" ] || { echo "MISSING $t-$ed (the script stopped early?)"; status=1; }
    done
done
exit $status

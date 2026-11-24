" Common setup of the indentation tests (run.sh starts the editors with -u NONE and sets
" g:rt (editors/vim), g:root (the repository), g:work (a scratch directory), g:hostile).
set nocompatible
set noswapfile nobackup nowritebackup shortmess+=A
set nomore
let g:hostile = get(g:, 'hostile', 0)
if g:hostile
  " the user's global settings that an ftplugin must override (Vim: _vimrc; Neovim: cindent)
  set shiftwidth=1 tabstop=1 expandtab smarttab cindent smartindent cinoptions=(0 autoindent
  set formatoptions-=t virtualedit=all
  if has('win32')
    set shell=C:\Windows\System32\cmd.exe shellslash
  endif
endif
execute 'set runtimepath^=' . escape(g:rt, ' ,\')
filetype plugin indent on
let g:editor = has('nvim') ? 'nvim' : 'vim'

" writes a result file: <work>/<name>-<editor>[-hostile].txt
function! TestOut(name, lines) abort
  call writefile(a:lines, g:work . '/' . a:name . '-' . g:editor . (g:hostile ? '-hostile' : '') . '.txt')
endfunction

" the manifest of prep.vim: [{id, path, n, verbatim}]
function! TestManifest() abort
  let out = []
  for l in readfile(g:work . '/manifest.txt')
    let [id, path, n, nv] = split(l, "\t")
    call add(out, {'id': id, 'path': path, 'n': str2nr(n), 'nv': str2nr(nv)})
  endfor
  return out
endfunction

" the files of the manifest selected by g:pick: 'all', or every Nth ('every:N'), or a list
" of repository paths separated by ','
function! TestPick(m) abort
  let pick = get(g:, 'pick', 'all')
  if pick ==# 'all'
    return a:m
  elseif pick =~# '^every:'
    let n = str2nr(matchstr(pick, '\d\+'))
    return filter(copy(a:m), 'v:key % n == 0')
  endif
  let want = split(pick, ',')
  return filter(copy(a:m), 'index(want, v:val.path) >= 0')
endfunction

" opens file f (no swap file, nothing written) as an AL buffer, with the plugins of the
" filetype loaded even if nothing detects *.al
function! TestEdit(f) abort
  silent! %bwipeout!
  execute 'silent edit ' . fnameescape(a:f)
  if &filetype !=# 'al'
    setlocal filetype=al
  endif
endfunction

" the options an AL buffer must have whatever the global settings: '' or what is wrong
function! TestOptions() abort
  let bad = []
  for [name, want] in [['shiftwidth', 4], ['softtabstop', 4], ['expandtab', 1], ['cindent', 0],
        \ ['smartindent', 0], ['indentexpr', 'al#indent#expr()'], ['commentstring', '// %s'],
        \ ['comments', '://'], ['suffixesadd', '.al']]
    let have = eval('&l:' . name)
    if have !=# want
      call add(bad, name . '=' . have)
    endif
  endfor
  if &l:formatoptions =~# 't' || &l:formatoptions !~# 'c'
    call add(bad, 'formatoptions=' . &l:formatoptions)
  endif
  return join(bad, ' ')
endfunction

" the first lines where a and b differ (at most 3), for a report
function! TestDiff(got, want) abort
  let out = []
  let n = max([len(a:got), len(a:want)])
  for i in range(n)
    let g = get(a:got, i, '<none>')
    let w = get(a:want, i, '<none>')
    if g !=# w
      call add(out, printf('    line %d: got  |%s|', i + 1, g))
      call add(out, printf('    line %d: want |%s|', i + 1, w))
      if len(out) >= 6
        break
      endif
    endif
  endfor
  return out
endfunction

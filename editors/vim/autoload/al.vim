" Support for AL (AgentLang) buffers: the compiler `alc`, `:AlFmt`, `gf` on `use` lines.

let s:save_cpo = &cpo
set cpo&vim

let s:win = has('win32') || has('win64')

" The `alc` to run: g:al_alc if set, else `alc` on PATH, else the nearest build/alc.exe (or
" build/alc) in a directory above the buffer's file (or the current directory). '' if none.
function! al#alc() abort
  if exists('g:al_alc') && !empty(g:al_alc)
    return expand(g:al_alc)
  endif
  if executable('alc')
    return exepath('alc')
  endif
  let dir = expand('%:p:h')
  if empty(dir)
    let dir = getcwd()
  endif
  for name in s:win ? ['build/alc.exe', 'build/alc'] : ['build/alc', 'build/alc.exe']
    let f = findfile(name, fnameescape(dir) . ';')
    if !empty(f) && (executable(fnamemodify(f, ':p')) || s:win)
      return fnamemodify(f, ':p')
    endif
  endfor
  return ''
endfunction

" a program path as a word of a command for the shell ('shellslash' makes shellescape() use
" single quotes, which cmd.exe does not understand)
function! al#shellword(path) abort
  if s:win && &shell =~? 'cmd'
    return '"' . substitute(a:path, '/', '\', 'g') . '"'
  elseif s:win
    " a POSIX shell on Windows (Git Bash, MSYS): forward slashes, single quotes (whatever
    " 'shellslash' says, and inside the double quotes of 'shellxquote')
    return "'" . substitute(substitute(a:path, '\\', '/', 'g'), "'", "'\\\\''", 'g') . "'"
  endif
  return shellescape(a:path)
endfunction

" Runs alc with the arguments args, the lines `input` on standard input: [output lines (its
" standard error too, or after them), exit status]. Neovim runs it directly; Vim through
" 'shell', standard error into a file of its own (the 'shellredir' of cmd.exe sends it to
" the output, that of a POSIX shell on Windows does not).
function! s:run(alc, args, input) abort
  if has('nvim')
    return [systemlist([a:alc] + a:args, a:input), v:shell_error]
  endif
  let errfile = tempname()
  let cmd = al#shellword(a:alc) . ' ' . join(a:args) . ' 2>' . al#shellword(errfile)
  let out = systemlist(cmd, a:input)
  let status = v:shell_error
  let err = filereadable(errfile) ? readfile(errfile) : []
  call delete(errfile)
  return [status ? out + err : out, status]
endfunction

" The directory of the standard library (`use std.name` is <dir>/name.al): $ALC_STD_DIR,
" g:al_std_dir, a std/ directory above the buffer's file, or the std/ next to alc's build/.
function! al#std_dir() abort
  return substitute(s:std_dir(), '\\', '/', 'g')
endfunction

function! s:std_dir() abort
  if !empty($ALC_STD_DIR) && isdirectory($ALC_STD_DIR)
    return fnamemodify($ALC_STD_DIR, ':p:h')
  endif
  if exists('g:al_std_dir') && isdirectory(expand(g:al_std_dir))
    return fnamemodify(expand(g:al_std_dir), ':p:h')
  endif
  let dir = expand('%:p:h')
  if !empty(dir)
    let f = findfile('std/os.al', fnameescape(dir) . ';')
    if !empty(f)
      return fnamemodify(f, ':p:h')
    endif
  endif
  let alc = al#alc()
  if !empty(alc) && filereadable(fnamemodify(alc, ':p:h:h') . '/std/os.al')
    return fnamemodify(alc, ':p:h:h') . '/std'
  endif
  return ''
endfunction

" 'includeexpr': `std.name` (from `use std.name`) is a file of the standard library; a path
" (from `use "path"`) is relative to the file, which 'path' (".") finds
function! al#includeexpr(fname) abort
  let m = matchlist(a:fname, '^std\.\(\w\+\)$')
  if !empty(m)
    let dir = al#std_dir()
    return empty(dir) ? m[1] . '.al' : dir . '/' . m[1] . '.al'
  endif
  return a:fname
endfunction

" The diagnostics `alc` printed for standard input (`<stdin>:LINE:COL: error: MSG`) as
" location list entries of buffer buf.
function! s:diagnostics(out, buf) abort
  let items = []
  for l in a:out
    let m = matchlist(l, '^<stdin>:\(\d\+\):\(\d\+\): \(error\|warning\): \(.*\)$')
    if !empty(m)
      call add(items, {'bufnr': a:buf, 'lnum': str2nr(m[1]), 'col': str2nr(m[2]),
            \ 'type': m[3] ==# 'error' ? 'E' : 'W', 'text': m[4]})
    elseif l =~# '^error: '
      call add(items, {'bufnr': a:buf, 'text': l, 'type': 'E'})
    endif
  endfor
  return items
endfunction

" Replaces the lines of the current buffer with `new` where they differ (one undo step: all
" the changes are made by one command; the cursor, the view and the jumplist stay).
function! s:replace(new) abort
  let old = getline(1, '$')
  let n = len(old)
  let m = len(a:new)
  " the lines the two have in common at the start and at the end
  let a = 0
  while a < n && a < m && old[a] ==# a:new[a]
    let a += 1
  endwhile
  let z = 0
  while z < n - a && z < m - a && old[n - 1 - z] ==# a:new[m - 1 - z]
    let z += 1
  endwhile
  " old[a : n-1-z] becomes new[a : m-1-z]
  let ko = n - a - z
  let kn = m - a - z
  let common = min([ko, kn])
  let i = 0
  while i < common
    if old[a + i] !=# a:new[a + i]
      call setline(a + i + 1, a:new[a + i])
    endif
    let i += 1
  endwhile
  if kn > ko
    call append(a + ko, a:new[a + ko : a + kn - 1])
  elseif ko > kn
    silent execute 'keepjumps keepmarks ' . (a + kn + 1) . ',' . (a + ko) . 'delete _'
  endif
endfunction

" :AlFmt — the buffer in the canonical layout of `alc fmt` (white space only). The buffer is
" changed only if alc succeeds and the text changes; on a syntax error it is left as it is
" and the diagnostics go to the location list. `quiet`: for format-on-save (no messages when
" nothing changes). Returns 1 if the buffer is in the canonical layout afterwards.
function! al#fmt(...) abort
  let quiet = a:0 > 0 && a:1
  let alc = al#alc()
  if empty(alc)
    echohl ErrorMsg
    echomsg 'AlFmt: alc not found (set g:al_alc, put alc on PATH, or build build/alc.exe)'
    echohl None
    return 0
  endif
  let lines = getline(1, '$')
  if lines == ['']
    return 1
  endif
  let [out, status] = s:run(alc, ['fmt', '-'], lines)
  let buf = bufnr('%')
  if status != 0
    let items = s:diagnostics(out, buf)
    if empty(items)
      let items = [{'bufnr': buf, 'type': 'E', 'text': 'alc fmt failed (status ' . status . '): ' . join(out[-3:], ' ')}]
    endif
    call setloclist(0, [], 'r', {'title': 'alc fmt', 'items': items})
    echohl WarningMsg
    echomsg 'AlFmt: the buffer is not changed: ' . len(items) . ' error(s), see :lopen (first: '
          \ . (has_key(items[0], 'lnum') ? items[0].lnum . ': ' : '') . items[0].text . ')'
    echohl None
    return 0
  endif
  " a successful run prints the text and nothing else
  if out ==# lines
    if !quiet
      echo 'AlFmt: already in the canonical layout'
    endif
    return 1
  endif
  if empty(out)
    echohl ErrorMsg
    echomsg 'AlFmt: alc printed nothing; the buffer is not changed'
    echohl None
    return 0
  endif
  let view = winsaveview()
  call s:replace(out)
  call winrestview(view)
  " an earlier error list of alc fmt is out of date
  if get(getloclist(0, {'title': 0}), 'title', '') ==# 'alc fmt'
    call setloclist(0, [], 'r', {'title': 'alc fmt', 'items': []})
  endif
  return 1
endfunction

" BufWritePre with g:al_fmt_on_save: format, and write anyway if alc finds an error
function! al#fmt_on_save() abort
  if get(b:, 'al_fmt_on_save', get(g:, 'al_fmt_on_save', 0))
    call al#fmt(1)
  endif
endfunction

let &cpo = s:save_cpo
unlet s:save_cpo

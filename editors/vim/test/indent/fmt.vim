" :AlFmt, format on save, :compiler alc, finding alc, 'includeexpr' / gf. Works on copies in
" <work>/fmt/. Result: <work>/fmt-<editor>[-hostile].txt
execute 'source ' . fnameescape(expand('<sfile>:p:h') . '/lib.vim')

let s:dir = g:work . '/fmt-' . g:editor . (g:hostile ? '-hostile' : '')
call mkdir(s:dir, 'p')
let s:out = []
let s:fail = 0
let s:count = 0

function! s:check(ok, what) abort
  let s:count += 1
  if !a:ok
    let s:fail += 1
    call add(s:out, 'FAIL ' . a:what)
  endif
endfunction

" a copy of a file of the repository in s:dir
function! s:copy(path, ...) abort
  let to = s:dir . '/' . (a:0 ? a:1 : fnamemodify(a:path, ':t'))
  call writefile(readfile(g:root . '/' . a:path, 'b'), to, 'b')
  return to
endfunction

" a new undo step starts here (as between two commands typed by the user)
function! s:break_undo() abort
  let &undolevels = &undolevels
endfunction

" alc in a directory with a space in its name, to test the quoting
let s:spaced = s:dir . '/alc dir/' . fnamemodify(g:alc, ':t')
call mkdir(fnamemodify(s:spaced, ':h'), 'p')
call writefile(readfile(g:alc, 'b'), s:spaced, 'b')

for s:alc in [g:alc, s:spaced]
  let g:al_alc = s:alc
  let s:tag = ' [alc ' . (s:alc ==# g:alc ? 'build' : 'in a directory with a space') . ', shell ' . &shell . (exists('+shellslash') && &shellslash ? ' shellslash' : '') . ']'
  try
    " 1. a badly written file becomes layout.fmt, in one undo step, cursor and jumps kept
    call TestEdit(s:copy('tests/fmt/layout.al'))
    let s:orig = getline(1, '$')
    call cursor(30, 5)
    let s:jumps = getjumplist()[0]
    call s:break_undo()
    let s:seq = undotree().seq_cur
    AlFmt
    call s:check(getline(1, '$') ==# readfile(g:root . '/tests/fmt/layout.fmt'), 'AlFmt layout.al gives layout.fmt' . s:tag)
    call s:check(undotree().seq_cur == s:seq + 1, 'AlFmt is one undo step (' . (undotree().seq_cur - s:seq) . ')' . s:tag)
    call s:check(line('.') == 30, 'AlFmt keeps the cursor line (' . line('.') . ')' . s:tag)
    call s:check(getjumplist()[0] == s:jumps, 'AlFmt leaves the jumplist' . s:tag)
    call s:check(empty(getloclist(0)), 'AlFmt: no diagnostics' . s:tag)
    silent undo
    call s:check(getline(1, '$') ==# s:orig, 'one undo restores the text' . s:tag)

    " 2. a syntax error: nothing changes, the diagnostics go to the location list
    call TestEdit(s:copy('tests/fmt/syntax_error.al'))
    let s:orig = getline(1, '$')
    silent! AlFmt
    call s:check(getline(1, '$') ==# s:orig && !&modified, 'AlFmt leaves a file with a syntax error alone' . s:tag)
    let s:ll = getloclist(0)
    call s:check(len(s:ll) == 1 && s:ll[0].lnum == 5 && s:ll[0].col == 1 && s:ll[0].bufnr == bufnr('%')
          \ && s:ll[0].text =~# 'expected `)`', 'AlFmt puts the error in the location list: ' . string(s:ll) . s:tag)

    " 3. already canonical: not modified
    call TestEdit(s:copy('tests/fmt/canonical.fmt', 'canonical.al'))
    call s:break_undo()
    let s:seq = undotree().seq_cur
    silent AlFmt
    call s:check(!&modified && undotree().seq_cur == s:seq, 'AlFmt changes nothing in a canonical file' . s:tag)

    " 4. line ends and byte order mark stay (CRLF, BOM)
    let s:f = s:copy('tests/fmt/crlf_bom.al')
    call TestEdit(s:f)
    AlFmt
    silent write
    call s:check(readfile(s:f, 'b') ==# readfile(g:root . '/tests/fmt/crlf_bom.fmt', 'b'), 'AlFmt + :write of crlf_bom.al gives crlf_bom.fmt' . s:tag)

    " 5. format on save, off by default
    let s:f = s:copy('tests/fmt/continuation.al')
    call TestEdit(s:f)
    call append(0, ['// x'])
    silent write
    call s:check(readfile(s:f, 'b')[1:] ==# readfile(g:root . '/tests/fmt/continuation.al', 'b'), 'no format on save by default' . s:tag)
    let g:al_fmt_on_save = 1
    call TestEdit(s:f)
    silent 1delete _
    silent write
    unlet g:al_fmt_on_save
    call s:check(readfile(s:f, 'b') ==# readfile(g:root . '/tests/fmt/continuation.fmt', 'b'), 'g:al_fmt_on_save = 1 formats on :write' . s:tag)

    " 6. :compiler alc and :make
    let s:f = s:copy('tests/fail/clone_pointer.al')
    call TestEdit(s:f)
    compiler alc
    call s:check(&l:makeprg =~# 'check', 'makeprg: ' . &l:makeprg . s:tag)
    silent make!
    let s:qf = getqflist()
    let s:valid = filter(copy(s:qf), 'v:val.valid')
    call s:check(len(s:valid) == 4 && s:valid[0].lnum == 8 && s:valid[0].col == 15 && s:valid[0].type ==# 'e'
          \ && s:valid[0].bufnr == bufnr('%') && s:valid[3].lnum == 14 && s:valid[3].text =~# '^type mismatch',
          \ ':make with :compiler alc: ' . string(map(copy(s:qf), '[v:val.valid, v:val.lnum, v:val.col, v:val.text[:30]]')) . s:tag)
  catch
    call s:check(0, v:exception . ' at ' . v:throwpoint . s:tag)
  endtry
endfor
unlet g:al_alc

" 7. finding alc next to the file (build/alc.exe above it), unless it is on PATH
try
  call TestEdit(g:root . '/src/fmt.al')
  let s:found = al#alc()
  if executable('alc')
    call s:check(s:found ==# exepath('alc'), 'al#alc() takes alc from PATH: ' . s:found)
  else
    call s:check(substitute(fnamemodify(s:found, ':p'), '\', '/', 'g') ==? substitute(fnamemodify(g:alc, ':p'), '\', '/', 'g'), 'al#alc() finds build/alc.exe: ' . s:found . ' (want ' . g:alc . ')')
  endif

  " 8. gf on `use std.name` and on `use "path"`, [I through the included files
  call cursor(search('^use std\.asset'), 6)
  normal! gf
  call s:check(expand('%:p') =~? 'std[/\\]asset\.al$', 'gf on `use std.asset` opens ' . expand('%:p'))
  let s:f = ''
  for s:g in glob(g:root . '/examples/*/*.al', 0, 1)
    if match(readfile(s:g, '', 40), '^use "[a-z_]*\.al"') >= 0
      let s:f = s:g
      break
    endif
  endfor
  call TestEdit(s:f)
  let s:l = search('^use "[a-z_]*\.al"')
  let s:want = matchstr(getline(s:l), '"\zs[^"]*')
  call cursor(s:l, 7)
  normal! gf
  call s:check(expand('%:t') ==# s:want, 'gf on `use "' . s:want . '"` in ' . s:f . ' opens ' . expand('%:p'))
  call TestEdit(g:root . '/src/fmt.al')
  redir => s:ilist
  silent! ilist /\<fn file_exists\>/
  redir END
  call s:check(s:ilist =~# 'file_exists', '[I / :ilist finds a declaration in a file included through std: ' . s:ilist[:200])
catch
  call s:check(0, v:exception . ' at ' . v:throwpoint)
endtry

call insert(s:out, printf('fmt %s%s: %d checks, %d failed', g:editor, g:hostile ? ' hostile' : '', s:count, s:fail))
call TestOut('fmt', s:out)
qall!

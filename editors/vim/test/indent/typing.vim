" Typing: the lines of a canonical file are typed one after the other into an empty AL
" buffer (`o` and the text without its leading white space, in Insert mode, so that the
" indentation comes from 'indentexpr' and 'indentkeys'), and the buffer must become the file.
" The lines `alc fmt` leaves as written (prep.vim: inside raw strings, after `alc fmt: off`,
" comment lines in the column of a comment after code) are typed as written: CTRL-D first,
" then their white space. This checks 'indentkeys' and that the cache is never stale while
" the buffer changes under it.
" Result: <work>/typing-<editor>[-hostile].txt
execute 'source ' . fnameescape(expand('<sfile>:p:h') . '/lib.vim')

let s:out = []
let s:fail = 0
let s:checked = 0
let s:lines = 0
for s:e in TestPick(TestManifest())
  let s:checked += 1
  let s:lines += s:e.n
  try
    " the canonical lines as a buffer has them
    call TestEdit(g:root . '/' . s:e.path)
    let s:want = getline(1, '$')
    let s:verbatim = {}
    for s:v in readfile(g:work . '/v/' . s:e.id . '.txt')
      let s:verbatim[s:v] = 1
    endfor
    silent! %bwipeout!
    enew!
    setlocal filetype=al
    " (the comment leader would be inserted after `o` on a comment line: not indentation)
    setlocal formatoptions-=o formatoptions-=r textwidth=0
    for s:i in range(len(s:want))
      let s:l = s:want[s:i]
      " (control characters, a tab or the CR of a line end inside a raw string, typed
      " literally)
      let s:keys = has_key(s:verbatim, s:i + 1) ? s:l : substitute(s:l, '^[ \t]*', '', '')
      let s:keys = substitute(s:keys, '[\x01-\x1f]', "\<C-v>&", 'g')
      if has_key(s:verbatim, s:i + 1)
        let s:keys = "0\<C-d>" . s:keys
      endif
      execute 'normal! ' . (s:i == 0 ? 'i' : 'o') . s:keys
    endfor
    let s:got = getline(1, '$')
    if s:got !=# s:want
      let s:fail += 1
      call add(s:out, 'FAIL ' . s:e.path)
      call extend(s:out, TestDiff(s:got, s:want))
    endif
  catch
    let s:fail += 1
    call add(s:out, 'FAIL ' . s:e.path . ': ' . v:exception . ' at ' . v:throwpoint)
  endtry
endfor
call insert(s:out, printf('typing %s%s: %d files (%d lines), %d failed',
      \ g:editor, g:hostile ? ' hostile' : '', s:checked, s:lines, s:fail))
call TestOut('typing', s:out)
qall!

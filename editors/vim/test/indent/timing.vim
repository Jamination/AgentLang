" Timing of `gg=G` on the largest file of src/ (by lines): on its destroyed copy (every line
" changes) and on the canonical file (nothing changes), each in a fresh buffer.
" Result: <work>/timing-<editor>.txt
execute 'source ' . fnameescape(expand('<sfile>:p:h') . '/lib.vim')

let s:big = {'n': 0}
for s:e in TestManifest()
  if s:e.path =~# '^src/' && s:e.n > s:big.n
    let s:big = s:e
  endif
endfor
let s:out = []
if s:big.n == 0
  call add(s:out, 'FAIL timing: no file of src/ in the manifest')
else
  let s:res = []
  for [s:what, s:f] in [['destroyed', g:work . '/d/' . s:big.id . '.al'], ['canonical', g:root . '/' . s:big.path]]
    let s:best = 1.0e9
    let s:all = []
    for s:r in range(3)
      call TestEdit(s:f)
      let s:t = reltime()
      silent normal! gg=G
      let s:dt = reltimefloat(reltime(s:t))
      let s:best = s:dt < s:best ? s:dt : s:best
      call add(s:all, printf('%.2f', s:dt))
      " (nothing is written; the next round reads the file again)
      setlocal nomodified
    endfor
    call add(s:res, printf('%s %.2f s (runs: %s)', s:what, s:best, join(s:all, ' ')))
  endfor
  call add(s:out, printf('timing %s: gg=G on %s (%d lines): %s', g:editor, s:big.path, s:big.n, join(s:res, '; ')))
endif
call TestOut('timing', s:out)
qall!

" Round trip: every destroyed copy of prep.vim, `gg=G`, written out, must be byte for byte the
" canonical file. Also checks the buffer options of every file (whatever the globals are).
" Result: <work>/sweep-<editor>[-hostile].txt
execute 'source ' . fnameescape(expand('<sfile>:p:h') . '/lib.vim')

let s:out = []
let s:fail = 0
let s:checked = 0
let s:lines = 0
let s:time = 0.0
let s:slowest = [0.0, '']
let s:outfile = g:work . '/out-' . g:editor . '.al'
for s:e in TestPick(TestManifest())
  let s:checked += 1
  let s:lines += s:e.n
  try
    call TestEdit(g:work . '/d/' . s:e.id . '.al')
    let s:opt = TestOptions()
    let s:t = reltime()
    silent normal! gg=G
    let s:dt = reltimefloat(reltime(s:t))
    let s:time += s:dt
    if s:dt > s:slowest[0]
      let s:slowest = [s:dt, s:e.path]
    endif
    execute 'silent write! ' . fnameescape(s:outfile)
    let s:got = readfile(s:outfile, 'b')
    let s:want = readfile(g:root . '/' . s:e.path, 'b')
    if s:got !=# s:want || !empty(s:opt)
      let s:fail += 1
      call add(s:out, 'FAIL ' . s:e.path . (empty(s:opt) ? '' : ' (options: ' . s:opt . ')'))
      call extend(s:out, TestDiff(s:got, s:want))
    endif
  catch
    let s:fail += 1
    call add(s:out, 'FAIL ' . s:e.path . ': ' . v:exception . ' at ' . v:throwpoint)
  endtry
endfor
call insert(s:out, printf('sweep %s%s: %d files (%d lines), %d failed; gg=G %.2f s in all, slowest %.2f s (%s)',
      \ g:editor, g:hostile ? ' hostile' : '', s:checked, s:lines, s:fail, s:time, s:slowest[0], s:slowest[1]))
call TestOut('sweep', s:out)
qall!

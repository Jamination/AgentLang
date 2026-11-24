" Builds the inputs of the round-trip test from the files in the canonical layout listed in
" <work>/canonical.txt (paths relative to the repository):
"   <work>/d/<id>.al   the file with the indentation of its lines destroyed
"   <work>/v/<id>.txt  the lines left as they are (see below)
"   <work>/manifest.txt  id, path, number of lines, number of lines left as they are
" The indentation of every non-blank line is replaced by other white space (spaces, tabs or
" none). `alc fmt` is the judge of which lines it lays out: the destroyed copies are
" formatted with it, and every line it does not bring back (the inside of a multi-line raw
" string, the lines from `// alc fmt: off` on, a comment line that continues the comment after
" the code above in its column) gets its original text back; then `alc fmt` of each copy
" gives exactly the canonical file, and so must `gg=G`.
" g:alc: the compiler.

let s:list = readfile(g:work . '/canonical.txt')

" white space to put in front of a line instead of `orig` (the canonical indentation is
" `want` columns): not the same text, and not the same width with 'tabstop' 1 or 8 (else
" Vim's `=` would leave it as it is)
let s:CHOICES = ['', "\t", ' ', '   ', "  \t", repeat(' ', 9), "\t ", repeat(' ', 6)]
function! s:width(ws, ts) abort
  let w = 0
  for c in split(a:ws, '\zs')
    let w = c ==# "\t" ? (w / a:ts + 1) * a:ts : w + 1
  endfor
  return w
endfunction
function! s:other(orig, want, k, comment) abort
  if a:comment
    " a comment line: column 0 or 1, where no comment after code can be
    return a:want == 0 && a:orig ==# '' ? ' ' : ''
  endif
  for j in range(len(s:CHOICES))
    let ws = s:CHOICES[(a:k + j) % len(s:CHOICES)]
    if ws !=# a:orig && s:width(ws, 1) != a:want && s:width(ws, 8) != a:want
      return ws
    endif
  endfor
  return repeat(' ', a:want + 1)
endfunction

function! s:run_alc(dir) abort
  if has('win32') && &shell =~? 'cmd'
    let cmd = '"' . substitute(g:alc, '/', '\\', 'g') . '" fmt "' . substitute(a:dir, '/', '\\', 'g') . '"'
  else
    let cmd = shellescape(substitute(g:alc, '\\', '/', 'g')) . ' fmt ' . shellescape(substitute(a:dir, '\\', '/', 'g'))
  endif
  let out = system(cmd)
  return v:shell_error ? 'status ' . v:shell_error . ': ' . out : out
endfunction

for s:sub in ['d', 'f', 'v']
  call mkdir(g:work . '/' . s:sub, 'p')
endfor

let s:canon = []
let s:dest = []
for s:k in range(len(s:list))
  let s:c = readfile(g:root . '/' . s:list[s:k], 'b')
  let s:d = []
  for s:i in range(len(s:c))
    let s:l = s:c[s:i]
    let s:ws = matchstr(s:l, '^[ \t]*')
    let s:body = strpart(s:l, strlen(s:ws))
    if s:body =~# '^\r\=$' || (s:i == 0 && s:l[0 : 2] ==# "\xef\xbb\xbf")
      " (a byte order mark stays at the start of the file)
      call add(s:d, s:l)
    else
      call add(s:d, s:other(s:ws, strlen(s:ws), s:i, s:body =~# '^//') . s:body)
    endif
  endfor
  call add(s:canon, s:c)
  call add(s:dest, s:d)
endfor

let s:log = []
let s:bad = {}
for s:round in range(5)
  for s:k in range(len(s:list))
    call writefile(s:dest[s:k], printf('%s/f/%04d.al', g:work, s:k), 'b')
  endfor
  let s:out = s:run_alc(g:work . '/f')
  if s:out !~# '^s*$'
    call add(s:log, 'alc fmt: ' . s:out)
  endif
  let s:changed = 0
  let s:bad = {}
  for s:k in range(len(s:list))
    let s:f = readfile(printf('%s/f/%04d.al', g:work, s:k), 'b')
    if s:f ==# s:canon[s:k]
      continue
    endif
    if len(s:f) != len(s:canon[s:k])
      let s:bad[s:k] = 'alc fmt changed the number of lines'
      continue
    endif
    for s:i in range(len(s:f))
      if s:f[s:i] !=# s:canon[s:k][s:i]
        " this line, or if it has its text already (a comment line in the column of the
        " comment after the code above: `alc fmt` compares the columns as written), the
        " nearest line above that has not
        let s:j = s:i
        while s:j >= 0 && s:dest[s:k][s:j] ==# s:canon[s:k][s:j]
          let s:j -= 1
        endwhile
        if s:j >= 0
          let s:dest[s:k][s:j] = s:canon[s:k][s:j]
          let s:changed += 1
        endif
      endif
    endfor
    let s:bad[s:k] = 'alc fmt does not give the canonical file back'
  endfor
  call add(s:log, 'round ' . s:round . ': ' . s:changed . ' lines given back')
  if s:changed == 0
    break
  endif
endfor

let s:manifest = []
for s:k in range(len(s:list))
  if has_key(s:bad, s:k)
    call add(s:log, 'SKIPPED ' . s:list[s:k] . ': ' . s:bad[s:k])
    continue
  endif
  call writefile(s:dest[s:k], printf('%s/d/%04d.al', g:work, s:k), 'b')
  let s:v = []
  for s:i in range(len(s:dest[s:k]))
    if s:dest[s:k][s:i] ==# s:canon[s:k][s:i] && s:canon[s:k][s:i] !~# '^\r\=$'
      call add(s:v, s:i + 1)
    endif
  endfor
  call writefile(s:v, printf('%s/v/%04d.txt', g:work, s:k))
  " (a file read with 'b' has an empty last item when it ends in a line end)
  let s:n = len(s:canon[s:k]) - (get(s:canon[s:k], -1, 'x') ==# '' ? 1 : 0)
  call add(s:manifest, printf("%04d\t%s\t%d\t%d", s:k, s:list[s:k], s:n, len(s:v)))
endfor
call writefile(s:manifest, g:work . '/manifest.txt')
call writefile(s:log, g:work . '/prep-log.txt')
qall!

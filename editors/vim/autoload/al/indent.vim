" Indentation of AL source files, the same as `alc fmt` gives (src/fmt.al, `layout`).
"
" The indentation of a line depends on the tokens of the lines above it: the brackets left
" open, whether the line above ends in an operator (or in a `,` where that continues the
" statement), and which `{` start blocks rather than literals (`Name{...}`). The lines are
" scanned forward with a small lexer (src/lexer.al: strings, chars, raw strings over several
" lines, comments) and the state at the start of every line is cached. The state does not
" depend on the indentation of the lines, only on their tokens, so re-indenting a line never
" invalidates the states below it.
"
" Cache (b:al_indent): the text of the scanned lines, the state at the start of each line and
" a little information per line, as of b:changedtick. On a call it is checked against the
" buffer: if nothing changed it is valid; if the only change is the re-indentation the last
" call returned (what `=` does line after line, and Insert mode after an 'indentkeys' key),
" it is updated in place; otherwise the cached lines are compared with the buffer and
" everything from the first line that differs on is dropped and scanned again.

let s:save_cpo = &cpo
set cpo&vim

" A line is lexed into a string of one byte per token, mostly with substitute() over many
" lines at once, which is much faster than a loop over the bytes in Vim script:
"   I name   f fn   h if / while / for / when   m match   s struct / enum   R return / break /
"   continue   k another keyword   0 a literal (number, string, char, raw string, true, false,
"   nil)   A =>   B ->   E .. ..= ...   P another operator of 2 or 3 bytes   + an operator of
"   one byte   n `in` / `by` (names to the lexer; keywords in the header of a `for`)   and
"   as they are: ( ) [ ] { } , ; : . * &
let s:KWC = {'fn': 'f', 'if': 'h', 'while': 'h', 'for': 'h', 'when': 'h', 'match': 'm',
      \ 'struct': 's', 'enum': 's', 'true': '0', 'false': '0', 'nil': '0',
      \ 'return': 'R', 'break': 'R', 'continue': 'R', 'const': 'k', 'use': 'k', 'else': 'k',
      \ 'loop': 'k', 'assert': 'k', 'defer': 'k', 'inline': 'k', 'noinline': 'k',
      \ 'extern': 'k', 'priv': 'k', 'in': 'n', 'by': 'n'}
" operators of more bytes, the longest first at each position (as the lexer takes them)
let s:MULTI = '<<=\|>>=\|\.\.[=.]\|\.\.\|:=\|->\|==\|=>\|!=\|<<\|<=\|>>\|>=\|&&\|&=\|||\||=\|[-+*/%^]='
let s:PM = {'=>': 'A', '->': 'B', '..': 'E', '..=': 'E', '...': 'E'}
" Brackets opened and closed on one line with no `{` in them: `( ... )` is G, `[ ... ]` is Q.
" Their insides change nothing for the lines below (they cannot hold a `{`, hence no `match`,
" `struct`, `if`), so they are left out.
let s:GROUP = '([^][(){}\n]*)'
let s:QGROUP = '\[[^][(){}\n]*\]'
" tokens that change the brackets or the statement
let s:EVENT = '[][(){},;fhmsAQ]'
" the start of a string, a char, a raw string or a comment
let s:SPECIAL = '["''`]\|//'

let s:OFF = '^// alc fmt: off\%([^0-9A-Za-z_]\|$\)'

" how many lines to scan ahead when lines are asked for one after the other (`=`)
let s:AHEAD = 200

" The state at the start of a line (a List, for speed):
"   0 stk     the open brackets; stk[0] is the top level. A frame: [ch, base, comma_cont,
"             prefix, index_of_name, saved hdrp, saved fnp, saved typ] (frames never change
"             once pushed, so states share them)
"   1 cont    the line above ended a statement that continues   2 cextra  its extra indentation
"   3 hdr     the last `struct`/`enum` ('s') or `match` ('m') seen    4 hdrd  its depth (-1)
"   5 prev    the previous token as the parser sees it: N start of a statement, I name,
"             F name after `.`, O operand, L `]` of `Name[...]`, T `]` of a type prefix `[]`,
"             R return/break/continue, D `.`, K keyword, P other punctuation
"   6 hdrp    a header (`if`, `while`, `for`, `match`, `when`) waits for its `{` here
"   7 fnp     a `fn` waits for its body here       8 typ   a type `[]T` / `[N]T` is being read
"   9 raw     the line starts inside a raw string (it continues a group of lines)
"   10 gd0, 11 gbase, 12 gcb, 13 gextra, 14 ghas: the group of lines being laid out (the
"             depth and base indentation at its start, the base of brackets it closed, its
"             extra indentation, whether it has a token)
"   15 lastcls the last token: c continues the statement, ',' a comma, o anything else
"   16 gstart  the first line of the group
function! s:initial_state() abort
  return [[['', 0, 0, 0, 0, 0, 0, 0]], 0, 0, '', -1, 'N', 0, 0, 0, 0, 0, 0, 0, 0, 0, 'o', 0]
endfunction

" the indentation `alc fmt` gives a line that starts a group, in state st (sc: it starts with
" a closing bracket)
function! s:code_indent(st, sc) abort
  let stk = a:st[0]
  if a:sc
    return len(stk) > 1 ? stk[-1][1] : 0
  endif
  return (len(stk) > 1 ? stk[-1][1] + 4 : 0) + (a:st[1] ? a:st[2] : 0)
endfunction

" The tokens of code (lines joined by "\n", no strings or comments left in them), one byte
" each (see above); the "\n" stay.
function! s:classes(code) abort
  let t = substitute(a:code, '\<\d\%([eE][-+]\d\|\.\d\|\w\)*', ' 0 ', 'g')
  let t = substitute(t, '\h\w*', '\=get(s:KWC, submatch(0), "I")', 'g')
  let t = substitute(t, s:MULTI, '\=" " . get(s:PM, submatch(0), "P") . " "', 'g')
  let t = substitute(t, '[-+/%^|!<>=~@]', '+', 'g')
  let t = substitute(t, '[^IfhmskR0nABEP+.*&:,;()\[\]{}\n]', '', 'g')
  while 1
    let u = substitute(substitute(t, s:GROUP, 'G', 'g'), s:QGROUP, 'Q', 'g')
    if u ==# t
      return t
    endif
    let t = u
  endwhile
endfunction

" A line without its strings, chars, raw strings and comments (each literal a `0`), from the
" state raw (it starts inside a raw string): [code, it ends inside a raw string, it is a
" comment only, the column of a comment after code relative to the line's first non-blank
" (-1: none), the comment is `// alc fmt: off`]
function! s:mask(s, raw) abort
  let s = a:s
  let code = ''
  let i = 0
  let raw = 0
  if a:raw
    let i = stridx(s, '`')
    if i < 0
      return ['', 1, 0, -1, 0]
    endif
    let i += 1
    let code = ' 0 '
  endif
  let conly = 0
  let tcrel = -1
  let off = 0
  while 1
    let j = match(s, s:SPECIAL, i)
    if j < 0
      let code .= strpart(s, i)
      break
    endif
    let code .= strpart(s, i, j - i)
    let q = s[j]
    if q ==# '/'
      if code =~# '[^ \t\r]'
        let tcrel = j - matchend(s, '^[ \t]*')
      else
        let conly = 1
      endif
      let off = strpart(s, j) =~# s:OFF
      break
    endif
    let code .= ' 0 '
    if q ==# '`'
      let i = stridx(s, '`', j + 1)
      if i < 0
        let raw = 1
        break
      endif
      let i += 1
      continue
    endif
    let i = matchend(s, q ==# '"' ? '^"\%([^"\\]\|\\.\)*"' : '^''\%([^''\\]\|\\.\)*''', j)
    if i < 0
      break
    endif
  endwhile
  return [code, raw, conly, tcrel, off]
endfunction

" One line (lnum, text; mk: from s:mask, cls: its tokens) from state a:st: [the state at the
" start of the next line, info]. info: [comment only, column of a comment after code relative
" to the line's first non-blank (-1: none), the line ends a group of several lines, an
" `alc fmt: off` comment is on it, (filled in by s:scan_to)]
function! s:step(st, text, lnum, mk, cls) abort
  let [stk, cont, cextra, hdr, hdrd, prev, hdrp, fnp, typ, raw, gd0, gbase, gcb, gextra, ghas, lastcls, gstart] = a:st
  if raw
    if a:mk[1]
      " still inside the raw string
      return [a:st, [0, -1, 0, 0, 0]]
    endif
  else
    let i = match(a:text, '[^ \t\r]')
    if i < 0
      " a blank line: only the lexer's end of a statement
      if (len(stk) == 1 || stk[-1][0] ==# '{') && stridx('IFOLTR', prev) >= 0
        return [[stk, cont, cextra, hdr, hdrd, 'N', 0, 0, 0, 0, gd0, gbase, gcb, gextra, ghas, lastcls, gstart], [0, -1, 0, 0, 0]]
      endif
      return [a:st, [0, -1, 0, 0, 0]]
    endif
    " a new group of lines
    let gstart = a:lnum
    let sc = stridx(')]}', a:text[i]) >= 0
    let gextra = (cont && !sc) ? cextra : 0
    let gbase = len(stk) == 1 ? 0 : sc ? stk[-1][1] : stk[-1][1] + 4
    let gd0 = len(stk) - 1
    let gcb = gbase
    let ghas = 0
  endif
  let raw = a:mk[1]
  let cls = a:cls
  let n = strlen(cls)
  if n > 0
    let stk = copy(stk)
    let ghas = 1
    let i = 0
    " Events one after the other; the tokens between them (seg) only change the previous
    " token, and end a type or the header of a fn. Each case ends in `continue`: Vim script
    " then skips the cases after it without reading them (comments in the loop cost time too).
    " Q: `[...]` on this line, a type prefix `[]` `[N]` (a type follows) or an index.
    " `{`: a block, or a literal (`Name{`, `Name[T]{`, `[]T{`: the parser decides, this
    " follows its rules); the lines of a block may continue after a `,`, unless it holds the
    " members of a struct or an enum. `fn` in a type (`[]fn()`) does not wait for a body.
    while i < n
      let j = match(cls, s:EVENT, i)
      if j != i
        let seg = strpart(cls, i, (j < 0 ? n : j) - i)
        if seg =~# '[^I.*&BG]'
          let [fnp, typ] = [0, 0]
        endif
        let c = seg[-1:]
        let prev = c ==# 'I' ? ((strlen(seg) > 1 ? seg[-2:-2] ==# '.' : prev ==# 'D') ? 'F' : 'I')
              \ : c ==# '0' || c ==# 'G' ? 'O' : c ==# '.' ? 'D' : c ==# 'R' ? 'R' : c ==# 'k' ? 'K'
              \ : c ==# 'n' ? (hdrp ? 'K' : 'I') : 'P'
        if j < 0
          break
        endif
      endif
      let e = cls[j]
      let i = j + 1
      if e ==# ')' || e ==# ']' || e ==# '}'
        let prev = 'O'
        if len(stk) > 1
          let top = remove(stk, -1)
          let gcb = len(stk) - 1 < gd0 ? top[1] : gcb
          let [hdrp, fnp, typ] = top[5 : 7]
          let prev = e ==# ']' ? (top[3] ? 'T' : top[4] ? 'L' : 'O') : 'O'
          let typ = e ==# '}' ? 0 : (typ || (e ==# ']' && top[3]))
        endif
        continue
      endif
      if e ==# 'Q'
        let [prev, typ] = stridx('IFOL', prev) < 0 ? ['T', 1] : [prev ==# 'I' ? 'L' : 'O', typ]
        continue
      endif
      if e ==# ','
        let [fnp, typ, prev] = [0, 0, 'P']
        continue
      endif
      if e ==# '{'
        let nst = len(stk) - 1
        let sh = hdrd == nst && hdr ==# 's'
        let block = fnp || !typ && (hdrp || sh || prev !=# 'I' && prev !=# 'L')
        if block && hdrd == nst
          let hdrd = -1
        endif
        call add(stk, ['{', nst < gd0 ? gcb : gbase, block && !sh, 0, 0, 0, 0, 0])
        let [hdrp, fnp, typ, prev] = [0, 0, 0, 'P']
        continue
      endif
      if e ==# '('
        call add(stk, ['(', len(stk) - 1 < gd0 ? gcb : gbase, 0, 0, 0, hdrp, fnp, typ])
        let [hdrp, fnp, typ, prev] = [0, 0, 0, 'P']
        continue
      endif
      if e ==# '['
        call add(stk, ['[', len(stk) - 1 < gd0 ? gcb : gbase, 0, stridx('IFOL', prev) < 0, prev ==# 'I', hdrp, fnp, typ])
        let [hdrp, fnp, typ, prev] = [0, 0, 0, 'P']
        continue
      endif
      if e ==# 'f'
        let [fnp, prev] = [!typ, 'K']
        continue
      endif
      if e ==# ';' || e ==# 'A'
        let [hdrp, fnp, typ, prev] = [0, 0, 0, e ==# ';' ? 'N' : 'P']
        continue
      endif
      let [typ, prev] = [0, 'K']
      if e !=# 's'
        let hdrp = 1
      endif
      if e !=# 'h'
        let [hdr, hdrd] = [e, len(stk) - 1]
      endif
    endwhile
    let c = cls[-1:]
    let lastcls = c ==# ',' ? ',' : stridx('IfhmskR0n;:()[]{}GQ', c) >= 0 ? 'o' : 'c'
  endif
  if !raw
    " the end of the group
    if ghas
      let was = cont
      let cont = lastcls ==# 'c' || (lastcls ==# ',' && (len(stk) == 1 || stk[-1][2]))
      if cont
        let cextra = was ? gextra : (len(stk) - 1 > gd0 ? 0 : 4)
      endif
    endif
    " the lexer's end of a statement
    if (len(stk) == 1 || stk[-1][0] ==# '{') && stridx('IFOLTR', prev) >= 0
      let [hdrp, fnp, typ, prev] = [0, 0, 0, 'N']
    endif
  endif
  return [[stk, cont, cextra, hdr, hdrd, prev, hdrp, fnp, typ, raw, gd0, gbase, gcb, gextra, ghas, lastcls, gstart],
        \ [a:mk[2], a:mk[3], a:lnum != gstart, a:mk[4], 0]]
endfunction

function! s:new_cache() abort
  return {'lines': [], 'st': [s:initial_state()], 'info': [], 'off': 0, 'offat': 0,
        \ 'tick': -1, 'nl': -1, 'elnum': 0, 'etext': '', 'rec': [0, ''], 'recok': 0, 'lastl': -1}
endfunction

" drops what was scanned from line k + 1 on (keeps k lines)
function! s:truncate(c, k) abort
  if a:k < len(a:c.lines)
    call remove(a:c.lines, a:k, -1)
    call remove(a:c.info, a:k, -1)
    call remove(a:c.st, a:k + 1, -1)
  endif
  if a:c.offat > a:k
    let a:c.off = 0
    let a:c.offat = 0
  endif
endfunction

" makes the cache agree with the buffer
function! s:validate(c) abort
  let c = a:c
  let tick = b:changedtick
  let c.recok = 0
  if c.elnum > 0 && (tick == c.tick || tick == c.tick + 1) && line('$') == c.nl
        \ && getline(c.elnum) ==# c.etext
    " the only change: the re-indentation the last call returned (`=` changes the lines
    " without changing b:changedtick until it is done; Insert mode adds one)
    if c.elnum <= len(c.lines)
      let c.lines[c.elnum - 1] = c.etext
    endif
    let c.recok = 1
  elseif tick != c.tick
    let m = min([len(c.lines), line('$')])
    let i = 0
    let k = m
    while i < m
      let j = min([i + 256, m])
      let cur = getline(i + 1, j)
      if cur !=# c.lines[i : j - 1]
        let k = i
        while cur[k - i] ==# c.lines[k]
          let k += 1
        endwhile
        break
      endif
      let i = j
    endwhile
    call s:truncate(c, k)
  endif
  let c.tick = tick
  let c.nl = line('$')
  let c.elnum = 0
endfunction

" scans lines until the cache holds `upto` of them
function! s:scan_to(c, upto) abort
  let c = a:c
  let m = len(c.lines)
  if m >= a:upto
    return
  endif
  let texts = getline(m + 1, a:upto)
  " strings and comments first (only the raw strings carry over from line to line)
  let raw = c.st[m][9]
  let masks = []
  for text in texts
    if !raw && match(text, s:SPECIAL) < 0
      call add(masks, [text, 0, 0, -1, 0])
      continue
    endif
    let mk = s:mask(text, raw)
    let raw = mk[1]
    call add(masks, mk)
  endfor
  let classes = split(s:classes(join(map(copy(masks), 'v:val[0]'), "\n")), "\n", 1)
  let st = c.st[m]
  let pinfo = m > 0 ? c.info[m - 1] : [0, -1, 0, 0, 0]
  let lnum = m + 1
  let k = 0
  for text in texts
    let [st, info] = s:step(st, text, lnum, masks[k], classes[k])
    " a comment line: the nearest line above that is not one (for comment_column)
    if info[0]
      let info[4] = pinfo[0] ? pinfo[4] : lnum - 1
    endif
    call add(c.lines, text)
    call add(c.st, st)
    call add(c.info, info)
    if info[3] && c.off == 0
      let c.off = st[16]
      let c.offat = lnum
    endif
    let pinfo = info
    let lnum += 1
    let k += 1
  endfor
endfunction

" the line's text as it was before the last re-indentation, when that is known
function! s:orig_text(c, lnum) abort
  return a:c.recok && a:c.rec[0] == a:lnum ? a:c.rec[1] : getline(a:lnum)
endfunction

" A comment line (lnum, written at column col) that continues the comment after the code of a
" line above, in its column (fmt.al: tc_col / tc_at): the column it gets, or -1. The lines in
" between are comment lines in that column; `alc fmt` compares the columns as written.
function! s:comment_column(c, lnum, col) abort
  let c = a:c
  let p = c.info[a:lnum - 1][4]
  if p < 1 || c.info[p - 1][1] < 0
    return -1
  endif
  let rel = c.info[p - 1][1]
  let t = getline(p)
  let f = matchend(t, '^[ \t]*')
  if p < a:lnum - 1
    " (in their column now: those above lnum have their final indentation already)
    if match(getline(p + 1, a:lnum - 1), '^\%([ \t]\{' . (f + rel) . '}//\)\@!') >= 0
      return -1
    endif
    if matchend(s:orig_text(c, a:lnum - 1), '^[ \t]*') != a:col
      return -1
    endif
  elseif matchend(s:orig_text(c, p), '^[ \t]*') + rel != a:col
    return -1
  endif
  if c.info[p - 1][2]
    " the last line of a raw string over several lines: the comment stays where it is
    return f + rel
  endif
  return s:code_indent(c.st[p - 1], f < strlen(t) && stridx(')]}', t[f]) >= 0) + rel
endfunction

" the indentation of line lnum (-1: leave it as it is)
function! al#indent#get(lnum) abort
  let lnum = a:lnum
  if !exists('b:al_indent')
    let b:al_indent = s:new_cache()
  endif
  let c = b:al_indent
  call s:validate(c)
  let last = line('$')
  if len(c.lines) < lnum
    call s:scan_to(c, c.lastl == lnum - 1 ? min([last, lnum + s:AHEAD]) : lnum)
  endif
  let c.lastl = lnum
  " the rest of the line's group (raw strings over several lines): an `alc fmt: off` there
  " counts for the whole group
  let k = lnum
  while k < last && c.st[k][9]
    let k += 1
    call s:scan_to(c, k)
  endwhile
  if c.off > 0 && lnum >= c.off
    return -1
  endif
  let st = c.st[lnum - 1]
  let text = getline(lnum)
  if st[9]
    " inside a raw string: as written (a new empty line gets no indentation)
    return text =~# '^[ \t\r]*$' ? 0 : -1
  endif
  let fc = matchend(text, '^[ \t]*')
  let ind = s:code_indent(st, fc < strlen(text) && stridx(')]}', text[fc]) >= 0)
  if c.info[lnum - 1][0]
    let tc = s:comment_column(c, lnum, fc)
    if tc >= 0
      let ind = tc
    endif
  endif
  " the change `=` will make: the next call finds the cache still valid
  if &expandtab && ind != indent(lnum) && fc < strlen(text)
    let c.elnum = lnum
    let c.etext = repeat(' ', ind) . strpart(text, fc)
    let c.rec = [lnum, text]
  endif
  return ind
endfunction

function! al#indent#expr() abort
  return al#indent#get(v:lnum)
endfunction

" for tests: forget the cache of the current buffer
function! al#indent#reset() abort
  unlet! b:al_indent
endfunction

let &cpo = s:save_cpo
unlet s:save_cpo

" Tests of editors/vim/syntax/al.vim and editors/vim/ftdetect/al.vim.
"
" Run with run.sh / run.bat next to this file, or by hand from any directory:
"   vim  -es -N -u NONE -i NONE --cmd "let g:al_test_log='out.txt'" -S editors/vim/test/syntax/run.vim
"   nvim --headless -u NONE -i NONE --cmd "let g:al_test_log='out.txt'" -S editors/vim/test/syntax/run.vim
" The results are written to g:al_test_log (default: out.txt in the current
" directory); Vim exits with status 0 when everything passed, 1 otherwise.
"
" 1. Assertions: the syntax group at given tokens of the fixtures here.
" 2. Sweep: every .al file under src/, std/, examples/, tests/fmt/ is lexed by
"    a small port of the quoting rules of src/lexer.al (comments, strings,
"    chars, raw strings); every such token must have its group at its first
"    and last byte, every line that starts outside a raw string must not start
"    inside a string, raw string or comment, and every line inside a raw string
"    must be in alRawString. Each file is checked top-down and then, after a
"    reload, bottom-up (as when jumping to the end of a file), which tests the
"    sync. tests/fail/ is not swept (deliberate errors).
" 3. Timing: the time to highlight the last line of the largest swept file
"    right after opening it.

let s:dir = expand('<sfile>:p:h')
let s:vimdir = fnamemodify(s:dir, ':h:h')
let s:root = fnamemodify(s:vimdir, ':h:h')
let s:log = get(g:, 'al_test_log', 'out.txt')
let s:out = []
let s:fails = 0
let s:passes = 0

exe 'set rtp^=' . fnameescape(s:vimdir)
" no swap files next to the swept sources
set noswapfile nomore shortmess+=F
filetype on
syntax on

function! s:Say(msg) abort
  call add(s:out, a:msg)
endfunction

function! s:Fail(msg) abort
  let s:fails += 1
  if s:fails <= 60
    call s:Say('FAIL ' . a:msg)
  elseif s:fails == 61
    call s:Say('(more failures not shown)')
  endif
endfunction

" the innermost group at (l, c), '' for none
function! s:Group(l, c) abort
  return synIDattr(synID(a:l, a:c, 1), 'name')
endfunction

function! s:Stack(l, c) abort
  return map(synstack(a:l, a:c), 'synIDattr(v:val, "name")')
endfunction

function! s:Open(file) abort
  exe 'silent edit! ' . fnameescape(a:file)
  if &filetype !=# 'al'
    call s:Fail(a:file . ': filetype is "' . &filetype . '", expected "al"')
  elseif get(b:, 'current_syntax', '') !=# 'al'
    call s:Fail(a:file . ': b:current_syntax is "' . get(b:, 'current_syntax', '') . '"')
  endif
endfunction

" ---------- 1. assertions ----------

" [file, text that identifies the line (its first line that contains it), token,
"  occurrence of the token in that line, expected group of every byte of it]
let s:cases = [
  \ ['fixture.al', '// Fixture for', '//', 1, 'alComment'],
  \ ['fixture.al', '// Fixture for', 'Fixture', 1, 'alComment'],
  \ ['fixture.al', 'TODO FIXME', 'TODO', 1, 'alTodo'],
  \ ['fixture.al', 'TODO FIXME', 'FIXME', 1, 'alTodo'],
  \ ['fixture.al', 'TODO FIXME', 'XXX', 1, 'alTodo'],
  \ ['fixture.al', 'TODO FIXME', 'NOTE', 1, 'alTodo'],
  \ ['fixture.al', 'TODO FIXME', 'marked', 1, 'alComment'],
  \ ['fixture.al', 'use "fixture_other', 'use', 1, 'alInclude'],
  \ ['fixture.al', 'use "fixture_other', '"fixture_other.al"', 1, 'alString'],
  \ ['fixture.al', 'use std.math', 'use', 1, 'alInclude'],
  \ ['fixture.al', 'use std.math', 'std.math', 1, 'alModulePath'],
  \ ['fixture.al', 'const LIMIT', 'const', 1, 'alStorageClass'],
  \ ['fixture.al', 'const LIMIT', 'LIMIT', 1, 'alConstName'],
  \ ['fixture.al', 'const LIMIT', '=', 1, 'alOperator'],
  \ ['fixture.al', 'const LIMIT', '1_000', 1, 'alNumber'],
  \ ['fixture.al', 'const MASK', 'u32', 1, 'alBuiltinType'],
  \ ['fixture.al', 'const MASK', '0xFF_00', 1, 'alNumber'],
  \ ['fixture.al', 'priv const BITS', 'priv', 1, 'alStorageClass'],
  \ ['fixture.al', 'priv const BITS', '0b1010_0101', 1, 'alNumber'],
  \ ['fixture.al', 'priv const PERMS', '0o755', 1, 'alNumber'],
  \ ['fixture.al', 'const HALF', '1.5', 1, 'alFloat'],
  \ ['fixture.al', 'const BIG', '1e9', 1, 'alFloat'],
  \ ['fixture.al', 'const SMALL', '2.5e-3', 1, 'alFloat'],
  \ ['fixture.al', 'const UNDER', '1_000.000_5E+10', 1, 'alFloat'],
  \ ['fixture.al', 'const NEWLINE', "'", 1, 'alChar'],
  \ ['fixture.al', 'const NEWLINE', '\n', 1, 'alEscape'],
  \ ['fixture.al', 'const NEWLINE', "'", 2, 'alChar'],
  \ ['fixture.al', 'const QUOTE', "\\'", 1, 'alEscape'],
  \ ['fixture.al', 'const QUOTE', "'", 3, 'alChar'],
  \ ['fixture.al', 'const DQUOTE', "'\"'", 1, 'alChar'],
  \ ['fixture.al', 'const HEX', '\x41', 1, 'alEscape'],
  \ ['fixture.al', 'const LETTER', "'a'", 1, 'alChar'],
  \ ['fixture.al', 'const GREETING', '"tab', 1, 'alString'],
  \ ['fixture.al', 'const GREETING', '\t', 1, 'alEscape'],
  \ ['fixture.al', 'const GREETING', '\n', 1, 'alEscape'],
  \ ['fixture.al', 'const GREETING', '\r', 1, 'alEscape'],
  \ ['fixture.al', 'const GREETING', '\0', 1, 'alEscape'],
  \ ['fixture.al', 'const GREETING', '\\', 1, 'alEscape'],
  \ ['fixture.al', 'const GREETING', '\"', 1, 'alEscape'],
  \ ['fixture.al', 'const GREETING', "\\'", 1, 'alEscape'],
  \ ['fixture.al', 'const GREETING', '\x7f', 1, 'alEscape'],
  \ ['fixture.al', 'const GREETING', ' end"', 1, 'alString'],
  \ ['fixture.al', 'const RAW', '`raw \n "not a string" // not a comment', 1, 'alRawString'],
  \ ['fixture.al', 'second line', "second line 'x' 0x10", 1, 'alRawString'],
  \ ['fixture.al', 'priv struct Point', 'struct', 1, 'alStructure'],
  \ ['fixture.al', 'priv struct Point', 'Point', 1, 'alTypeDecl'],
  \ ['fixture.al', 'priv struct Point', 'x', 1, ''],
  \ ['fixture.al', 'priv struct Point', 'f64', 1, 'alBuiltinType'],
  \ ['fixture.al', 'enum Shape', 'enum', 1, 'alStructure'],
  \ ['fixture.al', 'enum Shape', 'Shape', 1, 'alTypeDecl'],
  \ ['fixture.al', 'enum Shape', 'T', 1, 'alTypeName'],
  \ ['fixture.al', 'enum Shape', 'Circle', 1, 'alTypeName'],
  \ ['fixture.al', 'enum Shape', 'Empty', 1, 'alTypeName'],
  \ ['fixture.al', 'extern "libc', 'extern', 1, 'alStorageClass'],
  \ ['fixture.al', 'extern "libc', '"libc.so.6"', 1, 'alString'],
  \ ['fixture.al', 'extern "libc', 'fn', 1, 'alKeyword'],
  \ ['fixture.al', 'extern "libc', 'getpid', 1, 'alFuncName'],
  \ ['fixture.al', 'extern "libc', '->', 1, 'alOperator'],
  \ ['fixture.al', 'extern "libc', 'i32', 1, 'alBuiltinType'],
  \ ['fixture.al', 'inline fn tiny', 'inline', 1, 'alStorageClass'],
  \ ['fixture.al', 'inline fn tiny', 'tiny', 1, 'alFuncName'],
  \ ['fixture.al', 'inline fn tiny', '1', 1, 'alNumber'],
  \ ['fixture.al', 'noinline fn pick', 'noinline', 1, 'alStorageClass'],
  \ ['fixture.al', 'noinline fn pick', 'pick', 1, 'alFuncName'],
  \ ['fixture.al', 'noinline fn pick', 'T', 1, 'alTypeName'],
  \ ['fixture.al', 'noinline fn pick', 'less', 1, ''],
  \ ['fixture.al', 'noinline fn pick', 'fn', 2, 'alKeyword'],
  \ ['fixture.al', 'noinline fn pick', 'bool', 1, 'alBuiltinType'],
  \ ['fixture.al', 'if less(a, b)', 'if', 1, 'alConditional'],
  \ ['fixture.al', 'if less(a, b)', 'less', 1, 'alFunctionCall'],
  \ ['fixture.al', 'if less(a, b)', 'else', 1, 'alConditional'],
  \ ['fixture.al', 'when TARGET_OS == Windows', 'when', 1, 'alPreCondit'],
  \ ['fixture.al', 'when TARGET_OS == Windows', 'TARGET_OS', 1, 'alConstName'],
  \ ['fixture.al', 'when TARGET_OS == Windows', '==', 1, 'alOperator'],
  \ ['fixture.al', 'when TARGET_OS == Windows', 'Windows', 1, 'alTypeName'],
  \ ['fixture.al', "const SEP = '\\\\'", "'", 1, 'alChar'],
  \ ['fixture.al', "const SEP = '\\\\'", '\\', 1, 'alEscape'],
  \ ['fixture.al', '} else when', 'else', 1, 'alConditional'],
  \ ['fixture.al', '} else when', 'when', 1, 'alPreCondit'],
  \ ['fixture.al', 'return match s', 'return', 1, 'alStatement'],
  \ ['fixture.al', 'return match s', 'match', 1, 'alConditional'],
  \ ['fixture.al', 'Circle(_, r)', 'Circle', 1, 'alTypeName'],
  \ ['fixture.al', 'Circle(_, r)', '_', 1, ''],
  \ ['fixture.al', 'Circle(_, r)', '=>', 1, 'alOperator'],
  \ ['fixture.al', 'Circle(_, r)', '3.0', 1, 'alFloat'],
  \ ['fixture.al', 'Shape.Rect(a, b)', 'Shape', 1, 'alTypeName'],
  \ ['fixture.al', 'Shape.Rect(a, b)', 'Rect', 1, 'alQualified'],
  \ ['fixture.al', 'Shape.Rect(a, b)', 'x', 1, ''],
  \ ['fixture.al', 'Empty => 0.0', '0.0', 1, 'alFloat'],
  \ ['fixture.al', 'fn main()', 'main', 1, 'alFuncName'],
  \ ['fixture.al', 't := (1, (2, 3))', ':=', 1, 'alOperator'],
  \ ['fixture.al', 't := (1, (2, 3))', '2', 1, 'alNumber'],
  \ ['fixture.al', 'u := t.1.0', '1', 1, 'alTupleField'],
  \ ['fixture.al', 'u := t.1.0', '0', 1, 'alTupleField'],
  \ ['fixture.al', 'v := vec[str]()', 'vec', 1, 'alFunctionCall'],
  \ ['fixture.al', 'v := vec[str]()', 'str', 1, 'alBuiltinType'],
  \ ['fixture.al', 'v.push("a")', 'push', 1, 'alFunctionCall'],
  \ ['fixture.al', 'v.push("a")', '"a"', 1, 'alString'],
  \ ['fixture.al', 'n := len(', 'len', 1, 'alBuiltinFunc'],
  \ ['fixture.al', 'n := len(', '..', 1, 'alOperator'],
  \ ['fixture.al', 'n := len(', 'len', 2, ''],
  \ ['fixture.al', 'n := len(', 'sizeof', 1, 'alBuiltinFunc'],
  \ ['fixture.al', 'n := len(', 'Point', 1, 'alTypeName'],
  \ ['fixture.al', 'o: Opt[u8]', 'Opt', 1, 'alTypeName'],
  \ ['fixture.al', 'o: Opt[u8]', 'u8', 1, 'alBuiltinType'],
  \ ['fixture.al', 'o: Opt[u8]', 'Opt', 2, 'alTypeName'],
  \ ['fixture.al', 'o: Opt[u8]', 'None', 1, 'alQualified'],
  \ ['fixture.al', 'p := &Point', 'Point', 1, 'alTypeName'],
  \ ['fixture.al', 'ok := true', 'true', 1, 'alBoolean'],
  \ ['fixture.al', 'ok := true', 'false', 1, 'alBoolean'],
  \ ['fixture.al', 'ok := true', 'nil', 1, 'alConstant'],
  \ ['fixture.al', 'ok := true', '&&', 1, 'alOperator'],
  \ ['fixture.al', 'q := i64(u8(200))', 'i64', 1, 'alBuiltinType'],
  \ ['fixture.al', 'q := i64(u8(200))', 'u8', 1, 'alBuiltinType'],
  \ ['fixture.al', 'q := i64(u8(200))', '200', 1, 'alNumber'],
  \ ['fixture.al', 'rows: for y', 'rows', 1, 'alLabel'],
  \ ['fixture.al', 'rows: for y', 'for', 1, 'alRepeat'],
  \ ['fixture.al', 'rows: for y', 'y', 1, 'alForVars'],
  \ ['fixture.al', 'rows: for y', 'in', 1, 'alForIn'],
  \ ['fixture.al', 'rows: for y', '0', 1, 'alNumber'],
  \ ['fixture.al', 'rows: for y', '10', 1, 'alNumber'],
  \ ['fixture.al', 'for x, w in v', 'x, w', 1, 'alForVars'],
  \ ['fixture.al', 'for x, w in v', 'in', 1, 'alForIn'],
  \ ['fixture.al', 'continue rows', 'continue', 1, 'alStatement'],
  \ ['fixture.al', 'continue rows', 'rows', 1, 'alLabelRef'],
  \ ['fixture.al', 'for i in 9..=0 by -1', 'in', 1, 'alForIn'],
  \ ['fixture.al', 'for i in 9..=0 by -1', '9', 1, 'alNumber'],
  \ ['fixture.al', 'for i in 9..=0 by -1', '..=', 1, 'alOperator'],
  \ ['fixture.al', 'for i in 9..=0 by -1', 'by', 1, 'alForBy'],
  \ ['fixture.al', 'print(i, n, o', 'print', 1, 'alBuiltinFunc'],
  \ ['fixture.al', 'print(i, n, o', 'w_of', 1, 'alFunctionCall'],
  \ ['fixture.al', 'outer: loop', 'outer', 1, 'alLabel'],
  \ ['fixture.al', 'outer: loop', 'loop', 1, 'alRepeat'],
  \ ['fixture.al', 'break outer', 'break', 1, 'alStatement'],
  \ ['fixture.al', 'break outer', 'outer', 1, 'alLabelRef'],
  \ ['fixture.al', 'defer {', 'defer', 1, 'alStatement'],
  \ ['fixture.al', 'assert n > 0', 'assert', 1, 'alStatement'],
  \ ['fixture.al', 'assert n > 0', '"positive"', 1, 'alString'],
  \ ['fixture.al', 'in := 1', 'in', 1, ''],
  \ ['fixture.al', 'by := 2', 'by', 1, ''],
  \ ['fixture.al', 'test := in + by', 'test', 1, ''],
  \ ['fixture.al', 'test := in + by', 'in', 1, ''],
  \ ['fixture.al', 'test := in + by', 'by', 1, ''],
  \ ['fixture.al', 'print(test)', 'test', 1, ''],
  \ ['fixture.al', 'fn w_of', 'w_of', 1, 'alFuncName'],
  \ ['fixture.al', 'test "areas"', 'test', 1, 'alTest'],
  \ ['fixture.al', 'test "areas"', '"areas"', 1, 'alString'],
  \ ['fixture.al', 'assert area(Empty)', 'area', 1, 'alFunctionCall'],
  \ ['fixture.al', 'assert area(Empty)', 'Empty', 1, 'alTypeName'],
  \ ['fixture.al', '// a comment with', '`backquotes`', 1, 'alComment'],
  \ ['fixture.al', '// a comment with', '"quotes"', 1, 'alComment'],
  \ ['fixture.al', '// a comment with', "'q'", 1, 'alComment'],
  \ ['fixture.al', 'x := 1 // trailing', 'x', 1, ''],
  \ ['fixture.al', 'x := 1 // trailing', '// trailing comment', 1, 'alComment'],
  \ ['fixture.al', '// alc fmt: off', '// ', 1, 'alComment'],
  \ ['fixture.al', '// alc fmt: off', 'alc fmt: off', 1, 'alFmtOff'],
  \ ['fixture.al', 'y :=    2', '2', 1, 'alNumber'],
  \ ['fixture.al', 'y :=    2', 'alc fmt: offset', 1, 'alComment'],
  \ ['fixture_contextual.al', 'fn by(n: i64)', 'by', 1, 'alFuncName'],
  \ ['fixture_contextual.al', 'test := 1', 'test', 1, ''],
  \ ['fixture_contextual.al', 'by := 2', 'by', 1, ''],
  \ ['fixture_contextual.al', 'in := []i64', 'in', 1, ''],
  \ ['fixture_contextual.al', 'for i in 9..=0', 'in', 1, 'alForIn'],
  \ ['fixture_contextual.al', 'for i in 9..=0', 'by', 1, 'alForBy'],
  \ ['fixture_contextual.al', 'for i in(in)', 'in', 1, 'alForIn'],
  \ ['fixture_contextual.al', 'for i in(in)', 'in', 2, ''],
  \ ['fixture_contextual.al', 'print(by -1', 'by', 1, ''],
  \ ['fixture_contextual.al', 'print(by -1', 'by', 2, ''],
  \ ['fixture_contextual.al', 'print(by -1', 'by', 3, ''],
  \ ['fixture_contextual.al', 'print(by -1', 'in', 1, ''],
  \ ['fixture_contextual.al', 'for i in 0..10 by(by)', 'by', 1, 'alForBy'],
  \ ['fixture_contextual.al', 'for i in 0..10 by(by)', 'by', 2, ''],
  \ ['fixture_contextual.al', 'test   "t"', 'test', 1, 'alTest'],
  \ ['fixture_contextual.al', 'assert test==1', 'test', 1, ''],
  \ ['fixture_errors.al', 'bad escape', '\q', 1, 'alEscapeError'],
  \ ['fixture_errors.al', 'bad escape', 'bad', 1, 'alString'],
  \ ['fixture_errors.al', 'short hex', '\x', 1, 'alEscapeError'],
  \ ['fixture_errors.al', 'BAD_BIN', '0b102', 1, 'alNumberError'],
  \ ['fixture_errors.al', 'BAD_HEX', '0xG1', 1, 'alNumberError'],
  \ ['fixture_errors.al', 'EMPTY_HEX', '0x', 1, 'alNumberError'],
  \ ['fixture_errors.al', 'UPPER_PREFIX', '0', 1, 'alNumber'],
  \ ['fixture_errors.al', 'UPPER_PREFIX', 'X1F', 1, ''],
  \ ['fixture_errors.al', 'unterminated', 'unterminated', 1, 'alString'],
  \ ['fixture_errors.al', 'after_unterminated', 'after_unterminated', 1, ''],
  \ ['fixture_errors.al', 'after_unterminated', '1', 1, 'alNumber'],
  \ ['fixture_errors.al', 'TWO_BYTES', "'ab'", 1, ''],
  \ ['fixture_errors.al', 'NOT_FLOAT', '1', 1, 'alNumber'],
  \ ['fixture_errors.al', 'NOT_FLOAT', '.', 1, ''],
  \ ['fixture_errors.al', 'open raw', '`open raw', 1, 'alRawString'],
  \ ['fixture_errors.al', 'to the end', 'fn not_code', 1, 'alRawString'],
  \ ]

function! s:CheckCase(c) abort
  let [file, linetext, tok, nth, want] = a:c
  let l = 0
  for i in range(1, line('$'))
    if stridx(getline(i), linetext) >= 0
      let l = i
      break
    endif
  endfor
  if l == 0
    call s:Fail(printf('%s: no line contains %s', file, string(linetext)))
    return
  endif
  let s = getline(l)
  " a token that is a word is found as a whole word if it occurs as one (`in`
  " is not the `in` of `print`), else as plain text (the `0` of `0X1F`)
  let pats = ['\V' . escape(tok, '\')]
  if tok =~# '^\w\+$'
    call insert(pats, '\V\<' . tok . '\>')
  endif
  for pat in pats
    let at = -1
    for k in range(nth)
      let at = match(s, pat, at + 1)
      if at < 0
        break
      endif
    endfor
    if at >= 0
      break
    endif
  endfor
  if at < 0
    call s:Fail(printf('%s:%d: occurrence %d of %s not found', file, l, nth, string(tok)))
    return
  endif
  for k in range(strlen(tok))
    let got = s:Group(l, at + k + 1)
    if got !=# want
      call s:Fail(printf('%s:%d:%d: %s (occurrence %d), byte %d: group "%s", expected "%s" (stack %s)',
        \ file, l, at + k + 1, string(tok), nth, k + 1, got, want, string(s:Stack(l, at + k + 1))))
      return
    endif
  endfor
  let s:passes += 1
endfunction

" once as by default (operators are not highlighted: alOperator is not
" defined), once with g:al_highlight_operators
for s:ops in [0, 1]
  let g:al_highlight_operators = s:ops
  silent! %bwipeout!
  let s:cur = ''
  let s:passes = 0
  let s:case_fails = s:fails
  for s:c in s:cases
    if s:c[0] !=# s:cur
      let s:cur = s:c[0]
      call s:Open(s:dir . '/' . s:cur)
    endif
    let s:c2 = copy(s:c)
    if s:c2[4] ==# 'alOperator' && !s:ops
      let s:c2[4] = ''
    endif
    call s:CheckCase(s:c2)
  endfor
  call s:Say(printf('assertions (g:al_highlight_operators = %d): %d passed, %d failed',
    \ s:ops, s:passes, s:fails - s:case_fails))
endfor
unlet g:al_highlight_operators
silent! %bwipeout!

" ---------- 2. sweep ----------

" The expectations of one file, from the quoting rules of src/lexer.al:
" a list of [line, col, kind]; kind is a group that must be in the syntax
" stack there, or '-' (no string, raw string, char or comment there).
function! s:Lex(lines) abort
  let exp = []
  let in_raw = 0
  let nbad = 0
  let l = 0
  for s in a:lines
    let l += 1
    let n = strlen(s)
    let i = 0
    if in_raw
      let e = stridx(s, '`')
      if n > 0
        call add(exp, [l, 1, 'alRawString'])
      endif
      if e < 0
        continue
      endif
      call add(exp, [l, e + 1, 'alRawString'])
      let in_raw = 0
      let i = e + 1
    else
      let fb = match(s, '\S')
      if fb >= 0 && s[fb] !~# '["''`]' && s[fb : fb + 1] !=# '//'
        call add(exp, [l, fb + 1, '-'])
      endif
    endif
    while 1
      let m = match(s, '//\|["''`]', i)
      if m < 0
        break
      endif
      let c = s[m]
      if c ==# '/'
        call add(exp, [l, m + 1, 'alComment'])
        call add(exp, [l, n, 'alComment'])
        break
      elseif c ==# '`'
        call add(exp, [l, m + 1, 'alRawString'])
        let e = stridx(s, '`', m + 1)
        if e < 0
          let in_raw = 1
          if m + 1 < n
            call add(exp, [l, n, 'alRawString'])
          endif
          break
        endif
        call add(exp, [l, e + 1, 'alRawString'])
        let i = e + 1
      else
        " lex_quoted: to the closing quote or the end of the line; a
        " backslash takes the next byte with it
        let j = m + 1
        while j < n && s[j] !=# c
          let j += s[j] ==# '\' && j + 1 < n ? 2 : 1
        endwhile
        if c ==# '"'
          call add(exp, [l, m + 1, 'alString'])
          call add(exp, [l, j < n ? j + 1 : n, 'alString'])
        else
          let lit = s[m + 1 : j - 1]
          if j < n && (lit =~# '^[ -&(-[\]-~\t]$' || lit =~# '^\\\%([ntr0\\"'']\|x\x\x\)$')
            call add(exp, [l, m + 1, 'alChar'])
            call add(exp, [l, j + 1, 'alChar'])
          else
            " not a valid char literal (an error of the lexer): it must not
            " start anything else
            let nbad += 1
            call add(exp, [l, m + 1, '-'])
          endif
        endif
        let i = j + 1
      endif
    endwhile
  endfor
  " a raw string still open at the end of the file (the lines checked above
  " cover the last line either way)
  if in_raw
    let nbad += 1
  endif
  return [exp, nbad]
endfunction

let s:bad_regions = ['alString', 'alRawString', 'alChar', 'alComment']

" checks the expectations in the given order; returns the number checked
function! s:Check(file, exp) abort
  let n = 0
  for [l, c, kind] in a:exp
    let st = s:Stack(l, c)
    let n += 1
    if kind ==# '-'
      for g in s:bad_regions
        if index(st, g) >= 0
          call s:Fail(printf('%s:%d:%d: inside %s, expected outside of strings and comments (stack %s)',
            \ a:file, l, c, g, string(st)))
          return n
        endif
      endfor
    elseif index(st, kind) < 0
      call s:Fail(printf('%s:%d:%d: expected %s (stack %s)', a:file, l, c, kind, string(st)))
      return n
    endif
  endfor
  return n
endfunction

let s:files = []
for s:d in ['src', 'std', 'examples', 'tests/fmt']
  let s:files += glob(s:root . '/' . s:d . '/**/*.al', 0, 1)
endfor
call sort(s:files)

let s:sweep_fails = s:fails
let s:nchecks = 0
let s:nlines = 0
let s:largest = ['', 0]
for s:f in s:files
  let s:rel = substitute(s:f[strlen(s:root) + 1 :], '\\', '/', 'g')
  let s:lines = readfile(s:f)
  " a byte order mark is not part of the text (lexer_lex)
  if !empty(s:lines)
    let s:lines[0] = substitute(s:lines[0], '^\xef\xbb\xbf', '', '')
  endif
  let s:nlines += len(s:lines)
  if len(s:lines) > s:largest[1]
    let s:largest = [s:f, len(s:lines)]
  endif
  let [s:exp, s:nbad] = s:Lex(s:lines)
  if s:nbad > 0
    call s:Say(printf('note: %s: %d token(s) the lexer rejects (bad char literal or unterminated raw string)', s:rel, s:nbad))
  endif
  call s:Open(s:f)
  " (a CR before the line end may or may not be in the buffer: 'fileformat')
  if substitute(getline(1), '\r$', '', '') !=# substitute(get(s:lines, 0, ''), '\r$', '', '')
    \ || line('$') != max([len(s:lines), 1])
    call s:Fail(s:rel . ': the buffer is not the file as read (encoding?)')
    continue
  endif
  let s:nchecks += s:Check(s:rel, s:exp)
  " again from the bottom up, right after reloading (sync)
  call s:Open(s:f)
  let s:nchecks += s:Check(s:rel . ' (bottom-up)', reverse(copy(s:exp)))
  bwipeout!
endfor
call s:Say(printf('sweep: %d files, %d lines, %d checks, %d failed', len(s:files), s:nlines, s:nchecks, s:fails - s:sweep_fails))

" ---------- 3. timing ----------
if s:largest[1] > 0
  call s:Open(s:largest[0])
  let s:t = reltime()
  call synID(line('$'), 1, 1)
  let s:ms = reltimefloat(reltime(s:t)) * 1000
  call s:Say(printf('timing: %s (%d lines): last line highlighted %.0f ms after opening',
    \ substitute(s:largest[0][strlen(s:root) + 1 :], '\\', '/', 'g'), s:largest[1], s:ms))
  let s:big = s:root . '/src/prelude.al'
  call s:Open(s:big)
  let s:t = reltime()
  call synID(line('$'), 1, 1)
  let s:ms = reltimefloat(reltime(s:t)) * 1000
  call s:Say(printf('timing: src/prelude.al (%d lines): %.0f ms', line('$'), s:ms))
endif

call s:Say(printf('%s: %s, %d failure(s)', has('nvim') ? 'nvim' : 'vim', s:fails ? 'FAILED' : 'ok', s:fails))
call writefile(s:out, s:log)
if s:fails
  cquit!
endif
qall!

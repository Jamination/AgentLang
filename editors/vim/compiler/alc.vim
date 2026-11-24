" Vim compiler file
" Compiler:	alc, the AL (AgentLang) compiler: `:make` type-checks the current file
"
" Diagnostics of alc (src/main.al, print_errors) look like
"	src/x.al:12:5: error: type mismatch: expected i64, found S
"	error: cannot read `x.al`: ...			(no position)
"	3 error(s)

if exists('current_compiler')
  finish
endif
let current_compiler = 'alc'

if exists(':CompilerSet') != 2
  command -nargs=* CompilerSet setlocal <args>
endif

let s:save_cpo = &cpo
set cpo&vim

" alc as al#alc() finds it (g:al_alc, PATH, build/alc.exe above the file); `check %`: the file
" and the files it includes with `use`. cmd.exe needs double quotes (shellescape() gives
" single quotes when 'shellslash' is set).
let s:alc = al#alc()
let s:file = !has('win32') ? '%:S' : &shell =~? 'cmd' ? '"%"' : "'%'"
execute 'CompilerSet makeprg=' . escape((empty(s:alc) ? 'alc' : al#shellword(s:alc)) . ' check ' . s:file, ' \|"')
unlet s:alc s:file

CompilerSet errorformat=
      \%f:%l:%c:\ %trror:\ %m,
      \%f:%l:%c:\ %tarning:\ %m,
      \%-G%\\d%\\+\ error(s),
      \%+Gerror:\ %m

let &cpo = s:save_cpo
unlet s:save_cpo

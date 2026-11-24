" Vim filetype plugin
" Language:	AL (AgentLang), *.al

if exists('b:did_ftplugin')
  finish
endif
let b:did_ftplugin = 1

let s:save_cpo = &cpo
set cpo&vim

" the layout of `alc fmt`: 4 spaces, no tabs; the indentation comes from indent/al.vim
setlocal shiftwidth=4 softtabstop=4 expandtab
setlocal nocindent nosmartindent
" line comments only
setlocal comments=:// commentstring=//\ %s
setlocal formatoptions-=t formatoptions+=croqlj
" `use std.name` and `use "path"`: gf, [i, [I, [d and friends
setlocal suffixesadd=.al
let &l:include = '^\s*use\s\+"\='
setlocal includeexpr=al#includeexpr(v:fname)
" fn, struct, enum, const (after priv, inline, noinline, extern "lib")
let &l:define = '^\s*\%(\%(priv\|inline\|noinline\|extern\%(\s\+"[^"]*"\)\=\)\s\+\)*\%(fn\|struct\|enum\|const\)\>'
let s:std = al#std_dir()
if !empty(s:std)
  " (the directory of the file first, as 'path' starts by default)
  let &l:path = '.,' . escape(s:std, ' ,') . ',' . &g:path
endif
unlet s:std

" :AlFmt — the whole buffer through `alc fmt -`
command! -buffer -bar AlFmt call al#fmt()

augroup al_ftplugin
  autocmd! * <buffer>
  autocmd BufWritePre <buffer> call al#fmt_on_save()
augroup END

let b:undo_ftplugin = 'setlocal shiftwidth< softtabstop< expandtab< cindent< smartindent<'
      \ . ' comments< commentstring< formatoptions< suffixesadd< include< includeexpr<'
      \ . ' define< path<'
      \ . ' | silent! delcommand -buffer AlFmt'
      \ . ' | execute "silent! autocmd! al_ftplugin * <buffer>"'

let &cpo = s:save_cpo
unlet s:save_cpo

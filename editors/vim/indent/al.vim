" Vim indent file
" Language:	AL (AgentLang), *.al
" The indentation `alc fmt` gives (docs/DETAILS.md, "alc fmt"); see autoload/al/indent.vim.

if exists('b:did_indent')
  finish
endif
let b:did_indent = 1

setlocal indentexpr=al#indent#expr()
" re-indent a line that starts with a closing bracket as it is typed, and on CTRL-F
setlocal indentkeys=0},0),0],!^F,o,O
setlocal nocindent nosmartindent nolisp
setlocal autoindent

let b:undo_indent = 'setlocal indentexpr< indentkeys< cindent< smartindent< lisp< autoindent<'
      \ . ' | unlet! b:al_indent'

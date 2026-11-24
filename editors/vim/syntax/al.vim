" Vim syntax file
" Language:	AL (AgentLang), the language of this repository (*.al)
" Sources:	src/lexer.al (tokens, keywords, literals), src/parser.al (contextual
"		keywords `in`, `by`, `test`, labels), docs/LANGUAGE.md and the Grammar
"		section of docs/DETAILS.md, the builtin types of lower_builtin_type
"		(src/lower.al) and the builtin functions of lower_mem_is_builtin
"		(src/lower_mem.al).
"
" Options (set before the file is loaded, e.g. in your vimrc):
"   let g:al_highlight_operators = 1   link alOperator to Operator (default:
"                                      operators are not highlighted)
"   let g:al_no_function_calls = 1     do not highlight calls (alFunctionCall;
"                                      builtin calls stay highlighted)

if exists('b:current_syntax')
  finish
endif

let s:cpo_save = &cpo
set cpo&vim

syn case match
" identifiers are ASCII: [A-Za-z_][A-Za-z0-9_]* (src/lexer.al ident_tab_init)
syn iskeyword 48-57,65-90,97-122,_
syn spell notoplevel

" ---------- names ----------
" Defined first: among items that start at the same column the one defined
" last wins, and every rule below is more specific than these.

" Calls: `f(`, `f[T](`, `x.f(`. A name followed by `(` is a call or a
" conversion; keywords (`if (`) win anyway (a keyword beats any match).
" (Patterns here start with a literal or `\<`, not with a look-behind: a
" pattern that starts with a look-behind is tried at every byte, and was the
" slowest by far.)
syn match alFunctionCall "\<[a-z_]\w*\ze\%(\[\%([^][]\|\[[^][]*\]\)*\]\)\=(" contains=alBuiltinFunc
" The builtin functions (lower_mem_is_builtin): builtins only where they are
" called (`len(s)`, `s.len()`, `sizeof[T]()`); `v.len` is a field.
syn keyword alBuiltinFunc contained len sizeof offsetof variant_count std140_size std430_size
syn keyword alBuiltinFunc contained hlsl_cbuffer_size cast mkslice ptr syscall sqrt fabs fmin fmax
syn keyword alBuiltinFunc contained popcnt ctz clz bswap rotl rotr memcopy memfill embed panic
syn keyword alBuiltinFunc contained fmt hash put print clone mulhi atomic_load atomic_store
syn keyword alBuiltinFunc contained atomic_swap atomic_add atomic_sub atomic_and atomic_or
syn keyword alBuiltinFunc contained atomic_xor atomic_cas atomic_fence

" Capitalised names. In the repository's sources types, type parameters and
" enum variants are CamelCase (`Vec`, `T`, `Some`, `Circle`) and constants
" are ALL_CAPS (`KW_FN`, `TARGET_OS`); the lexer cannot tell a struct `Expr`
" from a variant `Expr(e)` (LANGUAGE.md allows both), so both are Type.
syn match alTypeName "\<\u\%([A-Z0-9_]*\l\w*\)\=\>" nextgroup=alQualifier
syn match alConstName "\<\u[A-Z0-9_]\+\>"
" A capitalised name after `.` is a field or a method (`p.Release()`, the COM
" bindings of std/), unless the part before the dot is a type: `Shape.Circle`,
" `Opt[u8].None` (a qualified variant).
syn match alFunctionCall "\.\zs\u\w*\ze("
syn match alQualifier "\%(\[[^][]*\]\)\=\.\ze\u" contained nextgroup=alQualified contains=alBuiltinType,alTypeName,alConstName,alNumber
syn match alQualified "\u\w*" contained

syn keyword alBuiltinType i8 i16 i32 i64 u8 u16 u32 u64 f32 f64 bool str never
syn keyword alBuiltinType vec2 vec3 vec4 quat mat4

" ---------- keywords (KEYWORDS in src/lexer.al) ----------
syn keyword alConditional if else match
" compile-time choice, like #if
syn keyword alPreCondit when
syn keyword alRepeat while loop
syn keyword alStatement return defer assert
syn keyword alStorageClass priv inline noinline extern const
syn keyword alBoolean true false
syn keyword alConstant nil

" `fn name`, `struct Name`, `enum Name`: the declared name
syn keyword alKeyword fn nextgroup=alFuncName skipwhite
syn match alFuncName "\h\w*" contained
syn keyword alStructure struct enum nextgroup=alTypeDecl skipwhite
syn match alTypeDecl "\h\w*" contained

" `use "file.al"`, `use std.window`
syn keyword alInclude use nextgroup=alModulePath skipwhite
syn match alModulePath "\h\w*\%(\.\h\w*\)*" contained

" `break name`, `continue name` (the label is on the same line)
syn keyword alStatement break continue nextgroup=alLabelRef skipwhite
syn match alLabelRef "\h\w*" contained
" a labelled loop: `name: for`, `name: while`, `name: loop`
syn match alLabel "^\s*\zs\h\w*\ze:\s*\%(for\|while\|loop\)\>"

" Contextual keywords (lexer_contextual): names to the lexer, keywords only in
" their place. `in` right after the loop variables of a `for`:
syn keyword alRepeat for nextgroup=alForVars skipwhite
syn match alForVars "\h\w*\%(\s*,\s*\h\w*\)\=" contained nextgroup=alForIn skipwhite
syn match alForIn "\<in\>" contained
" `by` after the range of a `for` header (`for i in 9..=0 by -1 {`): it follows
" a complete expression, so the text before it ends in an operand, and the
" line has `for` and `..` before it with no `{` in between.
syn match alForBy "\<by\>\%([[:alnum:]_)\]}'\"`]\s*by\)\@24<=\%(\<for\>[^{]*\.\.[^{]*\<by\)\@200<="
" `test "name" { ... }` where a declaration starts (`test := 1` is a variable)
syn match alTest "^\s*\zstest\ze\s*[\"`]"

" ---------- literals ----------
" Integers (lex_number): decimal with `_`, 0x / 0b / 0o (lower case prefix)
" with `_`; a base prefix followed by a bad digit is an error. No suffixes.
syn match alNumber "\<\d[0-9_]*"
syn match alNumberError "\<0[xbo]\w*"
syn match alNumber "\<0\%(x_*\x[0-9A-Fa-f_]*\|b_*[01][01_]*\|o_*\o[0-7_]*\)\>"
" Floats: digits on both sides of the point, an exponent, or both; the
" exponent has no `_`.
syn match alFloat "\<\d[0-9_]*\%(\.\d[0-9_]*\%([eE][+-]\=\d\+\)\=\|[eE][+-]\=\d\+\)"
" after a single `.` a number is a tuple field: `t.0.1` is (t.0).1, not 0.1
syn match alTupleField "\.\%(\.\.\)\@2<!\zs\d\+"

" Escapes (lex_quoted): \n \t \r \0 \\ \" \' \xHH; any other is an error.
syn match alEscapeError "\\." contained
syn match alEscape "\\[ntr0\\\"']" contained
syn match alEscape "\\x\x\x" contained
" Strings and chars end at the closing quote or at the end of the line.
syn region alString start=+"+ skip=+\\\\\|\\"+ end=+"+ end=+$+ contains=alEscape,alEscapeError
" A char literal is one byte: `'a'`, `'\''`, `'\x41'` (not a multi-byte character).
syn match alChar "'\%([ -&(-[\]-~\t]\|\\.\|\\x\x\x\)'" contains=alEscape,alEscapeError
" Raw strings: between backquotes, no escapes, may span lines.
syn region alRawString start=+`+ end=+`+

" ---------- operators ----------
" Not highlighted by default (and then not defined at all: on a typical line
" it is the most frequent match).
if get(g:, 'al_highlight_operators', 0)
  syn match alOperator "[-+*/%=<>!&|^~]\+\|\.\.[.=]\=\|:="
endif

" ---------- comments ----------
" `//` to the end of the line; there are no block comments. A comment that
" starts with `// alc fmt: off` (no letter, digit or `_` right after it) turns
" the formatter off from its line on (src/fmt.al fmt_off).
syn keyword alTodo contained TODO FIXME XXX NOTE
syn match alFmtOff "alc fmt: off\%(\w\)\@!" contained
syn match alComment "//.*" contains=alTodo,@Spell
syn match alComment "// alc fmt: off\%(\w\)\@!.*" contains=alFmtOff,alTodo,@Spell

" ---------- sync ----------
" Only raw strings span lines, and their contents look like code (shaders),
" so a guess from a few lines back can be wrong for a whole screen. Parsing
" from the start is cheap with these rules (and Vim keeps the states it has
" computed): see editors/vim/test/syntax for the timing.
syn sync fromstart

" ---------- links ----------
hi def link alComment      Comment
hi def link alTodo         Todo
hi def link alFmtOff       SpecialComment
hi def link alString       String
hi def link alRawString    String
hi def link alChar         Character
hi def link alEscape       SpecialChar
hi def link alEscapeError  Error
hi def link alNumber       Number
hi def link alNumberError  Error
hi def link alFloat        Float
hi def link alBoolean      Boolean
hi def link alConstant     Constant
hi def link alConditional  Conditional
hi def link alPreCondit    PreCondit
hi def link alRepeat       Repeat
hi def link alForIn        Repeat
hi def link alForBy        Repeat
hi def link alStatement    Statement
hi def link alStorageClass StorageClass
hi def link alStructure    Structure
hi def link alKeyword      Keyword
hi def link alTest         Keyword
hi def link alInclude      Include
hi def link alModulePath   String
hi def link alLabel        Label
hi def link alLabelRef     Label
hi def link alFuncName     Function
hi def link alTypeDecl     Type
hi def link alBuiltinType  Type
hi def link alTypeName     Type
hi def link alQualified    Type
hi def link alConstName    Constant
hi def link alBuiltinFunc  Function
if !get(g:, 'al_no_function_calls', 0)
  hi def link alFunctionCall Function
endif
if get(g:, 'al_highlight_operators', 0)
  hi def link alOperator   Operator
endif

let b:current_syntax = 'al'

let &cpo = s:cpo_save
unlet s:cpo_save

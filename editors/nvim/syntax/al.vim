" Syntax highlighting for AgentLang (AL)
if exists("b:current_syntax")
  finish
endif

syn case match

" Operators
syn match alOperator ":=\|->\|=>\|\.\.=\|\.\.\|&&\|||\|==\|!=\|<=\|>=\|<<\|>>\|[-+*/%&|^!~<>?=]"

" Numbers
syn match alNumber "\<\(0[xX][0-9A-Fa-f_]\+\|0[bB][01_]\+\|0[oO][0-7_]\+\|[0-9][0-9_]*\(\.[0-9_]\+\)\?\([eE][+-]\?[0-9_]\+\)\?\)\>"

" Loop labels
syn match alLabel "@[A-Za-z_][A-Za-z0-9_]*"

" Keywords
syn keyword alKeyword fn struct enum const priv use when extern inline noinline test defer assert
syn keyword alConditional if else match
syn keyword alRepeat for in by while loop break continue
syn keyword alStatement return

" Built-in constants & booleans
syn keyword alBoolean true false
syn keyword alConstant nil Some None TARGET_OS TARGET_ARCH Linux Windows MacOS X86_64 Arm64

" Primitive, math & core generic types
syn keyword alType i8 i16 i32 i64 u8 u16 u32 u64 f32 f64 bool str never
syn keyword alType vec2 vec3 vec4 quat mat4 Opt Vec Map Region

" Built-in & prelude functions
syn keyword alBuiltin print put putf eprint eput flush fmt fmtf fmti hex to_base
syn keyword alBuiltin len sizeof offsetof variant_count std140_size std430_size hlsl_cbuffer_size
syn keyword alBuiltin cast ptr mkslice memcopy memfill copy fill hash clone panic embed exit args env_get
syn keyword alBuiltin alloc new vec vec_of vec_fill map mark release region enter leave reset region_free mem_used
syn keyword alBuiltin sort sort_by min max abs floor ceil swap reverse sqrt fabs fmin fmax
syn keyword alBuiltin popcnt ctz clz bswap rotl rotr mulhi sat_add sat_sub syscall
syn keyword alBuiltin atomic_load atomic_store atomic_swap atomic_add atomic_sub
syn keyword alBuiltin atomic_and atomic_or atomic_xor atomic_cas atomic_fence

" Identifiers: calls and CamelCase types, then the names that declarations introduce
" (where two matches start at the same place, the one defined later wins)
syn match alCamelType "\<[A-Z][A-Za-z0-9_]*\>"
syn match alFuncCall "\<[a-z_][A-Za-z0-9_]*\>\(\s*(\)\@="
syn match alFuncDecl "\(\<fn\s\+\)\@<=[A-Za-z_][A-Za-z0-9_]*"
syn match alTypeDecl "\(\<\(struct\|enum\)\s\+\)\@<=[A-Za-z_][A-Za-z0-9_]*"
syn match alConstDecl "\(\<const\s\+\)\@<=[A-Za-z_][A-Za-z0-9_]*"
syn match alModule "\(\<use\s\+\)\@<=std\.[A-Za-z_][A-Za-z0-9_]*"

" Strings & characters
syn match alEscape contained "\\\(x[0-9A-Fa-f]\{2}\|u{[0-9A-Fa-f]\+}\|[ntr0\\\"']\)"
syn region alString start=+"+ skip=+\\\\\|\\"+ end=+"+ contains=alEscape,@Spell
syn region alRawString start=+`+ end=+`+
syn match alChar "'\(\\\(x[0-9A-Fa-f]\{2}\|[ntr0\\'\"]\)\|[^'\\]\)'"

" Comments & formatter directives
syn keyword alTodo contained TODO FIXME XXX NOTE HACK
syn match alComment "//.*$" contains=alTodo,alFmtDirective,@Spell
syn match alFmtDirective "//\s*alc fmt:\s*\(off\|on\)\>.*"

" Highlight links
hi def link alComment      Comment
hi def link alFmtDirective PreProc
hi def link alTodo         Todo
hi def link alString       String
hi def link alRawString    String
hi def link alChar         Character
hi def link alEscape       SpecialChar
hi def link alNumber       Number
hi def link alLabel        Label
hi def link alKeyword      Keyword
hi def link alConditional  Conditional
hi def link alRepeat       Repeat
hi def link alStatement    Statement
hi def link alBoolean      Boolean
hi def link alConstant     Constant
hi def link alType         Type
hi def link alTypeDecl     Type
hi def link alCamelType    Type
hi def link alConstDecl    Constant
hi def link alModule       Include
hi def link alBuiltin      Special
hi def link alFuncDecl     Function
hi def link alFuncCall     Function
hi def link alOperator     Operator

let b:current_syntax = "al"

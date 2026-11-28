" Compiler plugin for AgentLang (`alc`)
if exists("current_compiler")
  finish
endif
let current_compiler = "alc"

let s:alc = get(g:, "al_alc_command", "alc")
execute "CompilerSet makeprg=" . escape(s:alc . " check -W %:S", ' \|"')
CompilerSet errorformat=%f:%l:%c:\ %trror:\ %m,%f:%l:%c:\ %tarning:\ %m,%-G%.%#

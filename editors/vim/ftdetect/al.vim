" AL (AgentLang) source files.
"
" Vim's filetype.vim and Neovim's filetype.lua both claim *.al for Perl
" autoload files (with :setfiletype). Files in ftdetect/ are sourced after
" those rules, so this autocommand runs after them; ":set filetype" (not
" ":setfiletype") replaces the Perl guess.
autocmd BufNewFile,BufRead *.al set filetype=al

# AL in Vim and Neovim

Editing support for AL (`*.al`), for Vim 9 and Neovim 0.10+ (legacy Vim script, no Lua).

| file | what |
| --- | --- |
| `ftdetect/al.vim` | `*.al` is filetype `al` |
| `syntax/al.vim` | highlighting |
| `indent/al.vim`, `autoload/al/indent.vim` | indentation: exactly what `alc fmt` gives (see below) |
| `ftplugin/al.vim`, `autoload/al.vim` | buffer options, `:AlFmt`, format on save, `gf` on `use` lines |
| `compiler/alc.vim` | `:compiler alc`: `:make` runs `alc check %`, errors in the quickfix list |

## Install

Add this directory to 'runtimepath'; filetype plugins and indentation must be on.

Vim (`_vimrc` / `.vimrc`), before `filetype plugin indent on`:

```vim
set runtimepath^=C:/Users/you/Projects/AgentLang/editors/vim
filetype plugin indent on
```

Neovim with lazy.nvim (a file in `lua/plugins/`):

```lua
return {
  { dir = "C:/Users/you/Projects/AgentLang/editors/vim", name = "al.vim", lazy = false },
}
```

(`lazy = false`: `ftdetect/` must be loaded at startup.) Without a plugin manager:
`vim.opt.runtimepath:prepend("C:/Users/you/Projects/AgentLang/editors/vim")` in `init.lua`.

## Indentation

`=`, `gg=G`, `o`/`O` and typing a closing bracket at the start of a line give the
indentation of `alc fmt` (docs/DETAILS.md, "alc fmt"): 4 spaces per bracket left open by the
lines above (several opened on one line count once), a line starting with `)`, `]`, `}` at the
indentation of the line that opened it, 4 more for a line continuing a statement after an
operator (or after a `,` in a block or a `match`, not in a literal or a struct / enum), comment
lines like code in their place. Lines inside multi-line raw strings and from
`// alc fmt: off` on are left as they are. A comment line that continues the comment after
the code above it in its column stays in that column if it is in it; it is never moved there.

It does not need syntax highlighting. The lines are scanned once and the state at the start
of each line is cached per buffer (checked against `b:changedtick` and the text), so `gg=G`
is linear: 1.5 s (Neovim) to 1.9 s (Vim) for the 4434 lines of `src/prelude.al` on the
development machine (while other jobs were running).

Only white space at the start of lines changes; spaces inside lines, blank lines and trailing
white space are left to `:AlFmt`.

The buffer gets `shiftwidth=4 softtabstop=4 expandtab nocindent nosmartindent` whatever the
global settings are.

## Commands and options

- `:AlFmt` — the whole buffer through `alc fmt -`. The buffer changes only if alc succeeds and
  the text changes; it is one undo step, the cursor, view, marks and jumplist stay. On a syntax
  error the buffer is not touched and the diagnostics go to the location list (`:lopen`).
- `g:al_fmt_on_save = 1` (or `b:al_fmt_on_save`) — `:AlFmt` before every write (off by
  default). A file with a syntax error is written as it is.
- `g:al_alc` — the `alc` to run. Default: `alc` on PATH, else the nearest `build/alc.exe`
  (`build/alc`) in a directory above the file.
- `g:al_std_dir` — the directory of `use std.name` files. Default: `$ALC_STD_DIR`, else a
  `std/` above the file, else the `std/` next to alc's `build/`.
- `gq` is Vim's own formatting (`formatexpr` is not set): it wraps comments at 'textwidth' and
  continues their `//`. Code layout is `:AlFmt`.
- `:compiler alc` then `:make` — `alc check %`; the ftplugin does not set it (so the global
  'makeprg' stays). To always use it: `autocmd FileType al compiler alc`.
- `gf`, `[i`, `[I`, `[d`, `:checkpath` follow `use std.name` and `use "path"`; `commentstring`
  is `// %s` (vim-commentary, `gc`).

## Tests

```sh
editors/vim/test/indent/run.sh             # Vim and Neovim, a few minutes
editors/vim/test/indent/run.sh --quick     # every 10th file in the sweep
editors/vim/test/indent/run.sh --vim-only  # or --nvim-only
```

In Git Bash on Windows (no Python needed). `VIM_EXE`, `NVIM_EXE`, `ALC` override the
programs, `AL_VIM_TEST_DIR` the scratch directory (default: a new temporary directory);
nothing in the repository is written. It checks, in both editors:

1. sweep: every `.al` file of `src std examples tools bench tests` that `alc fmt --check`
   finds canonical, and the `tests/fmt/*.fmt` results, with the indentation of every line
   `alc fmt` lays out destroyed (`alc fmt` itself must restore the copy), then `gg=G`, must
   be byte for byte the file;
2. typing: a sample typed line by line in Insert mode (`o` and the text without indentation);
3. 1 and 2 on a subset with hostile globals (`sw=1 ts=1 cindent smartindent cino=(0`,
   `shell=cmd.exe shellslash`);
4. `:AlFmt` (layout.al to layout.fmt, a syntax error, one undo step, CRLF + BOM, alc in a
   directory with a space), format on save, `:make` with `:compiler alc`, `gf`, `[I`;
5. the time of `gg=G` on the largest file of `src/`.

## Syntax tests

```
editors/vim/test/syntax/run.sh "/c/Program Files/Vim/vim92/vim.exe" nvim
```

(`run.bat` takes the same arguments from cmd or PowerShell; with none, `vim` and `nvim` from
PATH.) It asserts the highlight group of every token of the fixtures in `test/syntax/`, then
sweeps the `.al` files of `src/`, `std/`, `examples/` and `tests/fmt/` for strings, raw strings
and comments that start or end in the wrong place, top-down and bottom-up. About a minute per
editor.

# AgentLang (`al`) for Neovim

Native Neovim (0.10+) support for AgentLang (`.al`) with built-in `alc lsp` integration.

## Features

- Filetype detection (`*.al` → `al`)
- Full syntax highlighting (keywords, primitive/vector/generic types, builtins, raw backtick strings, numeric literals, comments, `// alc fmt: off|on`)
- Indentation that follows `alc fmt`: re-indenting the compiler and standard library sources (83,000 lines) moves 2 lines
- Native LSP integration (`alc lsp` via `vim.lsp.config`/`vim.lsp.enable` on Neovim 0.11+, `vim.lsp.start` fallback on 0.10)
- Commands: `:AlFmt`, `:AlCheck` (populates quickfix via `alc check -W --json`), `:AlTest`, `:AlRun`, `:AlSigs`
- Compiler plugin (`:compiler alc` / `:make`)

## Setup

Add `editors/nvim` to your `runtimepath` (or load via your plugin manager) and call `require("al").setup(...)`:

```lua
vim.opt.rtp:prepend("/path/to/AgentLang/editors/nvim")
require("al").setup({
  alc = "alc",          -- or "/path/to/AgentLang/build/alc"
  lsp = true,
  format_on_save = false,
})
```

`on_attach = function(client, bufnr) ... end` in the same table runs when `alc lsp` attaches to a buffer (key mappings, `vim.lsp.completion.enable`); `format_on_save = true` runs `alc fmt` before each write.

## Tests

```bash
editors/nvim/test/run.sh
```

It checks the syntax groups, re-indents every line of `src/` and `std/` (laid out by `alc fmt`) and checks that nothing moves, and drives `alc lsp` (diagnostics, hover, definition), `:AlFmt` and `:AlCheck` in a headless Neovim (0.11+).

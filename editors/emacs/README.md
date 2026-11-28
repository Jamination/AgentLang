# AgentLang (`al-mode`) for Emacs

Full major mode and LSP (`alc lsp`) integration for Emacs 29+.

## Features

- Syntax highlighting for keywords, primitive/vector/generic types, builtins, raw backtick strings, numeric literals, comments, and `// alc fmt: off|on` directives
- Indentation that follows `alc fmt`: re-indenting the compiler and standard library sources (83,000 lines) moves 2 lines
- Automatic **Eglot** (built-in) and **lsp-mode** registration for `alc lsp`
- `C-c C-f`: format buffer with `alc fmt` (plus optional `al-format-on-save`)
- `C-c C-c` (`al-check`), `C-c C-t` (`al-test`), `C-c C-r` (`al-run`), `C-c C-b` (`al-build`) with clickable `compilation-mode` error navigation
- `imenu` navigation for functions, structs, enums, constants, and tests

## Setup

Add to `~/.emacs` or `~/.config/emacs/init.el`:

```elisp
(add-to-list 'load-path "/path/to/AgentLang/editors/emacs")
(require 'al-mode)
;; Optional: point to a specific alc binary (default: "alc" on PATH)
;; (setq al-alc-command "/path/to/AgentLang/build/alc")
;; Optional: format on save
;; (setq al-format-on-save t)
```

If you use Eglot (`(add-hook 'prog-mode-hook #'eglot-ensure)` or `(add-hook 'al-mode-hook #'eglot-ensure)`), `alc lsp` starts automatically on every `.al` file.

## Tests

```bash
editors/emacs/test/run.sh
```

It byte-compiles `al-mode.el` with warnings as errors, re-indents every line of `src/` and `std/` (laid out by `alc fmt`) and checks that nothing moves, and starts `alc lsp` through Eglot (diagnostics, hover) and runs `al-fmt-buffer`.

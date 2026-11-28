# AgentLang (AL) — Agent Guide

AgentLang (`alc`) is a self-hosted, statically typed, natively compiled programming language designed for AI agents.

## Fast Agent Workflow

Prefer `alc`'s machine-readable CLI commands and built-in LSP/semantic queries over guessing or grepping:

| Task | Command |
|---|---|
| Type-check & lint (JSON) | `alc check --json -W <file.al>` (add `--deny-warnings` to fail on warnings; `--all-targets` to check Linux + Windows) |
| List declarations & docs (JSON) | `alc sigs --json --pub <file.al>` (add `--std` for stdlib, `--filter <pat>` to narrow) |
| Run unit tests (JSON) | `alc test --json <file.al>` (add `--filter <pat>` to run a subset) |
| Build / run | `alc build <file.al> -o <out>` / `alc run <file.al> -- [args]` |
| Format code | `alc fmt <file.al | dir/>` (`--check` to verify without modifying; `// alc fmt: off` .. `// alc fmt: on` for opt-out ranges) |
| One-shot semantic queries (JSON) | `alc query hover <file:line:col>`, `alc query def <file:line:col>`, `alc query refs <file:line:col>`, `alc query complete <file:line:col>`, `alc query symbols <file.al>` |
| Language Server (LSP 3.17) | `alc lsp` (stdio JSON-RPC; registered in `.lsp.json`, `editors/emacs`, and `editors/nvim`) |

Use `./build/alc` when working inside this repository (or `alc` if the current build is on `PATH`).

## Repository Layout & Key Rules

- `src/` — Self-hosted compiler (`src/main.al` entry point). **Only `.al` files** are allowed in `src/`.
- `std/` — Standard library modules (`use std.<name>`). Core modules (`math`, `rand`, `time`, `mem`) are auto-loaded; all `tests/std/*.al` must compile to **static, libc-free** Linux ELF executables.
- `docs/` — Language reference (`docs/LANGUAGE.md`), details (`docs/DETAILS.md`), and stdlib docs (`docs/STDLIB.md`, `docs/std/*.md`).
- `editors/` — Full editor + LSP integrations for Emacs (`editors/emacs/al-mode.el`) and Neovim (`editors/nvim/`).
- `tests/` — Conformance (`tests/run/`), stdlib (`tests/std/`), driver (`tests/driver/`), formatter (`tests/fmt/`), and crash fuzzer (`tests/gen/fuzz_crash.py`).

## Verification Before Finishing Compiler Changes

1. Format touched files: `./build/alc fmt <files...>`
2. Run the 3-stage deterministic bootstrap: `./build.sh` (verifies stage 2 and stage 3 are byte-identical and builds `build/alc.exe`)
3. Note: Stage 1 of `./build.sh` compiles `src/` with `bootstrap/alc`, so `src/` must stay compatible with the seed compiler.
4. Run relevant tests (`./tests/run.sh`, `tests/driver/*.sh`, `./tests/run.sh tree`).

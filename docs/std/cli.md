# std.cli

`use std.cli`. Zero-dependency command-line flag, option, and positional argument parser for
tools and scripts.

Supports `--flag`, `-f`, `--no-flag`, `--opt val`, `--opt=val`, `-o val`, `-oVal`, combined
short flags (`-abc`), `--` end-of-options separator, `-h` / `--help`, and formatted help text.

## API

| Declaration | Description |
|---|---|
| `cli_new(prog: str, desc: str) -> Cli` | Creates a parser for `prog` with summary `desc`. |
| `add_flag(c: *Cli, long: str, short: str, help: str)` | Registers a boolean flag (default `false`; `--no-<long>` resets to `false`). |
| `add_str(c: *Cli, long: str, short: str, default: str, help: str)` | Registers a string option. |
| `add_i64(c: *Cli, long: str, short: str, default: i64, help: str)` | Registers an integer option (parsed with base 0: decimal, `0x`, `0b`, `0o`). |
| `parse(c: *Cli, argv: []str) -> bool` | Parses `argv` (typically `args()[1..]`). Sets `c.help_requested` on `-h`/`--help`; returns `false` with `c.err` on invalid input. |
| `flag(c: *Cli, name: str) -> bool` | Value of a boolean flag. |
| `opt_str(c: *Cli, name: str) -> str` | Value of a string option. |
| `opt_i64(c: *Cli, name: str) -> i64` | Value of an integer option. |
| `pos(c: *Cli) -> []str` | Positional arguments in order. |
| `help_text(c: *Cli) -> str` | Formatted usage and options help text. |
